// The hybrid header buttons and the first-run readiness card, over a real
// HybridRuntime and FakeHybridInference. Fakes only: no model, network or
// device is used.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_controls.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/trust/app_readiness.dart';

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

class _CountingInference extends FakeHybridInference {
  _CountingInference({super.textAvailability});
  int capabilityReads = 0;

  @override
  Future<HybridCapabilities> capabilities() {
    capabilityReads++;
    return super.capabilities();
  }
}

HybridRuntime _runtime(
  HybridInference inference, {
  bool Function()? isOnline,
}) => HybridRuntime.create(
  inference: inference,
  cloudRoutes: const CloudRoutes({}),
  cloudFallback: _NoCloud(),
  isOnline: isOnline ?? () => true,
  cloudModel: 'test-model',
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(500, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

/// The panel's button for an action (its title can repeat the label).
Finder _action(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

void main() {
  group('HybridHeaderButtons', () {
    testWidgets('"On-device AI" opens the on-device sheet', (tester) async {
      final hybrid = _runtime(FakeHybridInference());
      await _pump(tester, HybridHeaderButtons(hybrid: hybrid));

      expect(find.byKey(const ValueKey('open-label-check')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('open-on-device-ai')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('on-device-ai-sheet')), findsOneWidget);
    });

    testWidgets('"What was sent" reads the capabilities, then opens the '
        'ledger sheet', (tester) async {
      final inference = _CountingInference();
      final hybrid = _runtime(inference);
      await _pump(tester, HybridHeaderButtons(hybrid: hybrid));
      final before = inference.capabilityReads;

      await tester.tap(find.byKey(const ValueKey('open-ledger')));
      await tester.pumpAndSettle();

      expect(inference.capabilityReads, before + 1);
      expect(find.byKey(const ValueKey('ledger-view')), findsOneWidget);
    });

    testWidgets('"Check a label" appears only with a callback and opens the '
        'label check for the session', (tester) async {
      final hybrid = _runtime(FakeHybridInference());
      late BuildContext context;
      await _pump(
        tester,
        Builder(
          builder: (c) {
            context = c;
            return HybridHeaderButtons(
              hybrid: hybrid,
              onLabel: () => openLabelCheck(context, hybrid, sessionId: 's1'),
            );
          },
        ),
      );

      await tester.tap(find.byKey(const ValueKey('open-label-check')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('label-check-sheet')), findsOneWidget);
      // Without takePhoto only the typed path is offered.
      expect(find.byKey(const ValueKey('label-take-photo')), findsNothing);
    });
  });

  group('HybridReadinessCard', () {
    testWidgets('a downloadable model offers set-up: the action opens the '
        'on-device sheet and re-reads readiness afterwards', (tester) async {
      final inference = _CountingInference(
        textAvailability: const HybridAvailability(
          status: OnDeviceStatus.downloadable,
        ),
      );
      final hybrid = _runtime(inference);
      await _pump(tester, HybridReadinessCard(hybrid: hybrid));
      expect(find.byKey(const ValueKey('readiness-panel')), findsOneWidget);
      final reads = inference.capabilityReads;

      await tester.tap(_action(ReadinessAction.openOnDeviceSetup.label));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('on-device-ai-sheet')), findsOneWidget);

      // Closing the sheet lets the card refresh what the plugin reports.
      inference.textAvailability = const HybridAvailability(
        status: OnDeviceStatus.available,
      );
      Navigator.of(
        tester.element(find.byKey(const ValueKey('on-device-ai-sheet'))),
      ).pop();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('on-device-ai-sheet')), findsNothing);
      // openOnDeviceAi does not read capabilities itself; the refresh does.
      expect(inference.capabilityReads, greaterThan(reads));
      expect(find.text(ReadinessAction.openOnDeviceSetup.label), findsNothing);
    });

    testWidgets('offline with no local model: "Try again" re-checks the '
        'connection and clears the card once back online', (tester) async {
      var online = false;
      final inference = FakeHybridInference(
        textAvailability: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
          reason: 'model_not_ready',
        ),
      );
      final hybrid = _runtime(inference, isOnline: () => online);
      await _pump(tester, HybridReadinessCard(hybrid: hybrid));
      expect(find.textContaining("You're offline"), findsWidgets);

      // Still offline: the retry keeps saying so.
      await tester.tap(_action(ReadinessAction.checkConnection.label));
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsWidgets);

      online = true;
      await tester.tap(_action(ReadinessAction.checkConnection.label));
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsNothing);
    });

    testWidgets('offline with a ready local model: "Keep cooking" dismisses '
        'the card', (tester) async {
      final hybrid = _runtime(FakeHybridInference(), isOnline: () => false);
      await _pump(tester, HybridReadinessCard(hybrid: hybrid));
      expect(
        find.textContaining('On-device help keeps working'),
        findsOneWidget,
      );

      await tester.tap(_action(ReadinessAction.keepCooking.label));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('readiness-panel')), findsNothing);
    });
  });
}
