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
    void Function()? beforeNextFrame,
    void Function()? whileCooking,
  }) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(fakeServices))!;
    late final CookingCoordinator cook;
    cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: null,
      media: DemoLiveMedia(),
      onSessionReady: hybrid == null
          ? null
          : bindMealSession(hybrid, () => cook),
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
      whileCooking?.call();
      // Re-starting the same running timer is not a second timer.
      await cook.startTimer('pb-rest', 'Let it rest', 60);
      while (!cook.complete) {
        await cook.advanceStep();
      }
      // Runs right after the completion event, before any frame.
      beforeNextFrame?.call();
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
    expect(find.text('Timers started this visit'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // A new ledger session (another cook) retires tonight's receipt.
    hybrid.ledger.startSession('next-cook');
    await tester.pump();
    expect(receipt, findsNothing);
    // The next meal sends a photo, then the window widens past the layout
    // breakpoint (Column to Row), which remounts the meal-complete panel.
    // The retired receipt must not come back with the next meal's numbers.
    hybrid.ledger.record(
      const InferenceLeg(
        requestId: 'next-meal-photo',
        feature: 'label_check',
        mode: HybridMode.onlyInCloud,
        kinds: {DataKind.image},
        transferPermitted: true,
        provenance: Provenance.cloudAdapter,
      ),
    );
    tester.view.physicalSize = const Size(1280, 2400);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('meal-complete')), findsOneWidget);
    expect(receipt, findsNothing);
    tester.view.physicalSize = const Size(412, 2400);
    await tester.pumpAndSettle();
    expect(receipt, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a ledger reset during the meal means no receipt at the end', (
    tester,
  ) async {
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: CloudRoutes.parse(''),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    await cookToTheEnd(
      tester,
      hybrid: hybrid,
      // After the meal's session is bound, the ledger moves on mid-meal.
      whileCooking: () => hybrid.ledger.startSession('somewhere-else'),
    );
    expect(find.byKey(const ValueKey('meal-complete')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacy-receipt')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the receipt binds at meal start, not at the first build', (
    tester,
  ) async {
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: CloudRoutes.parse(''),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    await cookToTheEnd(
      tester,
      hybrid: hybrid,
      // Meal B starts and sends a photo before the panel's first frame.
      beforeNextFrame: () {
        hybrid.ledger.startSession('meal-b');
        hybrid.ledger.record(
          const InferenceLeg(
            requestId: 'meal-b-photo',
            feature: 'label_check',
            mode: HybridMode.onlyInCloud,
            kinds: {DataKind.image},
            transferPermitted: true,
            provenance: Provenance.cloudAdapter,
          ),
        );
      },
    );
    expect(find.byKey(const ValueKey('meal-complete')), findsOneWidget);
    // Bound to meal A's generation at completion: B's photo never prints.
    expect(find.byKey(const ValueKey('privacy-receipt')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Start new cook: a ledger switch after the replacement binds '
      'but before its screen subscribes means no receipt', (tester) async {
    for (final probe in [false, true]) {
      await _newCookRun(tester, probe: probe);
    }
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

Future<void> _newCookRun(WidgetTester tester, {required bool probe}) async {
  {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: CloudRoutes.parse(''),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    final services = (await tester.runAsync(fakeServices))!;
    final cooks = <CookingCoordinator>[];
    CookingCoordinator create() {
      late final CookingCoordinator cook;
      final bind = bindMealSession(hybrid, () => cook);
      cook = CookingCoordinator(
        services: services,
        research: FakeCookingResearchClient(),
        transportFactory: null,
        media: DemoLiveMedia(),
        onSessionReady: (id) {
          bind(id);
          if (probe && cooks.length > 1) {
            // The probe: right after the replacement binds, and before its
            // screen exists, the runtime switches away and back to the same
            // meal ID, and a cloud photo lands.
            hybrid.ledger
              ..startSession('elsewhere')
              ..startSession(id);
            hybrid.ledger.record(
              const InferenceLeg(
                requestId: 'later-photo',
                feature: 'label_check',
                mode: HybridMode.onlyInCloud,
                kinds: {DataKind.image},
                transferPermitted: true,
                provenance: Provenance.cloudAdapter,
              ),
            );
          }
        },
      );
      cooks.add(cook);
      return cook;
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(
          services: services,
          isDemo: false,
          hybrid: hybrid,
          createCoordinator: create,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('new-cook'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start new cook'));
    await tester.pumpAndSettle();
    expect(cooks, hasLength(2));
    final replacement = cooks.last;
    await tester.runAsync(() async {
      while (!replacement.complete) {
        await replacement.advanceStep();
      }
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('meal-complete')), findsOneWidget);
    // Control: without the switch, the replacement meal prints its receipt.
    expect(
      find.byKey(const ValueKey('privacy-receipt')),
      probe ? findsNothing : findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  }
}
