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

  group('HybridReadinessCard (one calm line, SS-089)', () {
    testWidgets('a downloadable model: Details opens the on-device sheet and '
        'readiness is re-read afterwards', (tester) async {
      final inference = _CountingInference(
        textAvailability: const HybridAvailability(
          status: OnDeviceStatus.downloadable,
        ),
      );
      final hybrid = _runtime(inference);
      await _pump(tester, HybridReadinessCard(hybrid: hybrid));
      expect(find.byKey(const ValueKey('readiness-line')), findsOneWidget);
      expect(find.byKey(const ValueKey('readiness-panel')), findsNothing);
      final reads = inference.capabilityReads;

      await tester.tap(find.byKey(const ValueKey('readiness-details')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('on-device-ai-sheet')), findsOneWidget);

      // Closing the sheet lets the line refresh what the plugin reports.
      inference.textAvailability = const HybridAvailability(
        status: OnDeviceStatus.available,
      );
      Navigator.of(
        tester.element(find.byKey(const ValueKey('on-device-ai-sheet'))),
      ).pop();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('on-device-ai-sheet')), findsNothing);
      expect(inference.capabilityReads, greaterThan(reads));
      // Ready now: nothing to say.
      expect(find.byKey(const ValueKey('readiness-line')), findsNothing);
    });

    testWidgets('offline with no local model: one calm line, re-checked '
        'after Details', (tester) async {
      var online = false;
      final inference = FakeHybridInference(
        textAvailability: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
          reason: 'model_not_ready',
        ),
      );
      final hybrid = _runtime(inference, isOnline: () => online);
      await _pump(tester, HybridReadinessCard(hybrid: hybrid));
      expect(find.textContaining("You're offline."), findsOneWidget);

      online = true;
      await tester.tap(find.byKey(const ValueKey('readiness-details')));
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byKey(const ValueKey('on-device-ai-sheet'))),
      ).pop();
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsNothing);
      expect(find.byKey(const ValueKey('readiness-line')), findsOneWidget);
    });

    testWidgets('offline with a ready local model: the plain invitation, '
        'no warning stack', (tester) async {
      final hybrid = _runtime(FakeHybridInference(), isOnline: () => false);
      await _pump(tester, HybridReadinessCard(hybrid: hybrid));
      expect(
        find.text('Type what you have, or pick a recipe below.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('readiness-panel')), findsNothing);
    });
  });
}
