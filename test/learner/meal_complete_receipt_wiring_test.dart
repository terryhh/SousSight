// SS-105 wiring: the cooking screen hands the hybrid runtime's ledger to the
// meal-complete panel, so tonight's privacy receipt prints from those legs,
// with the coordinator's timer count. Fakes only: no model, camera or
// network.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) async =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

InferenceLeg _leg(String id, Provenance provenance, Set<DataKind> kinds) =>
    InferenceLeg(
      requestId: id,
      feature: 'local_watch',
      mode: HybridMode.onlyOnDevice,
      kinds: kinds,
      transferPermitted: false,
      provenance: provenance,
    );

void main() {
  Future<CookingCoordinator> cookToTheEnd(
    WidgetTester tester, {
    HybridRuntime? hybrid,
  }) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(fakeServices))!;
    final cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: null,
      media: DemoLiveMedia(),
      onSessionReady: hybrid?.bindCookingSession,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(
          services: services,
          isDemo: false,
          hybrid: hybrid,
          createCoordinator: () => cook,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await cook.startTimer('pb-rest', 'Let it rest', 60);
      // Re-starting the same running timer is not a second timer.
      await cook.startTimer('pb-rest', 'Let it rest', 60);
      while (!cook.complete) {
        await cook.advanceStep();
      }
    });
    await tester.pumpAndSettle();
    expect(cook.complete, isTrue);
    return cook;
  }

  testWidgets('the meal-complete panel prints the runtime ledger receipt', (
    tester,
  ) async {
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: CloudRoutes.parse(''),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    final cook = await cookToTheEnd(tester, hybrid: hybrid);
    expect(cook.timersStarted, 1);
    hybrid.ledger
      ..record(_leg('w1', Provenance.sdkOnDevice, {DataKind.image}))
      ..record(_leg('w2', Provenance.sdkOnDevice, {DataKind.image}))
      ..record(_leg('p1', Provenance.simulated, {DataKind.text}));
    await tester.pumpAndSettle();

    final receipt = find.byKey(const ValueKey('privacy-receipt'));
    expect(receipt, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('meal-complete')),
        matching: receipt,
      ),
      findsOneWidget,
    );
    String count(String key) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(Text),
              )
              .last,
        )
        .data!;
    expect(count('receipt-on-device'), '2');
    expect(count('receipt-practice'), '1');
    expect(count('receipt-camera'), '2');
    expect(count('receipt-timers'), '1');
    expect(find.text('Timers started'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a hybrid runtime there is no receipt', (tester) async {
    final cook = await cookToTheEnd(tester);
    expect(cook.timersStarted, 1);
    expect(find.byKey(const ValueKey('meal-complete')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacy-receipt')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('timersStarted counts new timers only', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final cook = CookingCoordinator(
      services: await fakeServices(),
      research: FakeCookingResearchClient(),
      transportFactory: DemoLiveTransport.new,
      media: DemoLiveMedia(),
      isDemo: true,
    );
    addTearDown(cook.dispose);
    await cook.initialize();
    expect(cook.timersStarted, 0);
    await cook.startTimer('a', 'First', 30);
    await cook.startTimer('a', 'First', 30);
    expect(cook.timersStarted, 1);
    await cook.startTimer('b', 'Second', 45);
    expect(cook.timersStarted, 2);
  });
}
