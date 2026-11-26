import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/trust/inference_source_badge.dart';
import 'package:soussight/trust/route_reason_text.dart';
import 'package:soussight/trust/trust_labels.dart';

import 'trust_test_helpers.dart';

void main() {
  test('each leg gets a label from its provenance and permission', () {
    expect(
      legLabel(leg(Provenance.sdkOnDevice), localModel: 'Gemini Nano'),
      'On this device · Gemini Nano',
    );
    expect(legLabel(leg(Provenance.sdkOnDevice)), 'On this device');
    expect(legLabel(leg(Provenance.sdkCloud)), 'Cloud · Gemini');
    expect(legLabel(leg(Provenance.cloudAdapter)), 'Cloud');
    expect(legLabel(leg(Provenance.simulated)), 'Simulated');
    expect(
      legLabel(leg(Provenance.unknown, transferPermitted: true)),
      'May have been sent',
    );
    expect(
      legLabel(leg(Provenance.unknown, transferPermitted: false)),
      "Didn't finish · nothing left this device",
    );
  });

  // Regression (Codex review of #180): a failed onlyOnDevice leg is
  // provenance `unknown` with transferPermitted=false. It must not be shown
  // as a possible upload or as "allowed to leave".
  testWidgets('a failed local-only leg never says it may have been sent', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      InferenceSourceBadge(
        legs: [
          leg(
            Provenance.unknown,
            feature: 'local_watch',
            mode: HybridMode.onlyOnDevice,
            transferPermitted: false,
            kinds: {DataKind.image},
            error: HybridErrorCode.timeout,
          ),
        ],
      ),
    );
    expect(
      find.text("Didn't finish · nothing left this device (took too long)"),
      findsOneWidget,
    );
    expect(find.textContaining('May have been sent'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('inference-leg-0')));
    await tester.pumpAndSettle();
    expect(
      find.text(outcomeExplanation(LegOutcome.notFinishedLocal)),
      findsOneWidget,
    );
    expect(
      find.text('Used: photo. Not allowed to leave this device.'),
      findsOneWidget,
    );
    expect(find.textContaining('allowed to leave, then'), findsNothing);
    expect(find.textContaining('May have been sent'), findsNothing);
  });

  testWidgets('a two-leg result shows both legs, not one merged badge', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      InferenceSourceBadge(
        localModelFamily: 'Gemini Nano',
        reason: RouteReason.audioNeedsCloud,
        legs: [
          leg(
            Provenance.sdkCloud,
            feature: 'pantry_voice',
            kinds: {DataKind.audio},
          ),
          leg(Provenance.sdkOnDevice, kinds: {DataKind.text, DataKind.image}),
        ],
      ),
    );

    expect(find.text('Cloud · Gemini'), findsOneWidget);
    expect(find.text('On this device · Gemini Nano'), findsOneWidget);
    expect(find.byKey(const ValueKey('inference-leg-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('inference-leg-1')), findsOneWidget);

    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('inference-source-badge')),
    );
    expect(
      semantics.label,
      'Where this ran: Cloud · Gemini; On this device · Gemini Nano. '
      'Tap for details.',
    );

    await tester.tap(find.byKey(const ValueKey('inference-leg-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('inference-details')), findsOneWidget);
    expect(find.text('Where this answer came from'), findsOneWidget);
    expect(
      find.text(routeReasonText[RouteReason.audioNeedsCloud]!),
      findsOneWidget,
    );
    expect(find.text('Step 1 of 2 · Pantry voice note'), findsOneWidget);
    expect(find.text('Step 2 of 2 · Pantry scan'), findsOneWidget);
    expect(
      find.text('Used: voice clip. Allowed to leave this device: voice clip.'),
      findsOneWidget,
    );
    expect(
      find.text('Used: photo and text. Not allowed to leave this device.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an observed model label wins over the family', (tester) async {
    await pumpPhone(
      tester,
      InferenceSourceBadge(
        localModelFamily: 'Gemini Nano',
        legs: [leg(Provenance.sdkOnDevice, modelLabel: 'gemini-nano-4')],
      ),
    );
    expect(find.text('On this device · gemini-nano-4'), findsOneWidget);
  });

  testWidgets('a failed permitted send says it may have been sent', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      InferenceSourceBadge(
        legs: [
          leg(Provenance.sdkOnDevice, error: HybridErrorCode.timeout),
          leg(Provenance.unknown, error: HybridErrorCode.network),
          leg(Provenance.simulated, transferPermitted: false),
        ],
      ),
    );
    expect(find.text('On this device (took too long)'), findsOneWidget);
    expect(
      find.text('May have been sent (connection problem)'),
      findsOneWidget,
    );
    expect(find.text('Simulated'), findsOneWidget);
  });

  testWidgets('no legs renders nothing', (tester) async {
    await pumpPhone(tester, const InferenceSourceBadge(legs: []));
    expect(find.byKey(const ValueKey('inference-source-badge')), findsNothing);
  });

  testWidgets('multi-leg chips show which data each leg carried', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      InferenceSourceBadge(
        legs: [
          leg(
            Provenance.sdkCloud,
            feature: 'pantry_voice',
            kinds: {DataKind.audio},
          ),
          leg(Provenance.sdkOnDevice, kinds: {DataKind.image}),
        ],
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('inference-leg-0')),
        matching: find.byIcon(Icons.mic_none),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('inference-leg-1')),
        matching: find.byIcon(Icons.photo_camera_outlined),
      ),
      findsOneWidget,
    );
    // On-device and cloud differ by icon, not colour alone.
    expect(find.byIcon(Icons.memory), findsOneWidget);
    expect(find.byIcon(Icons.cloud), findsOneWidget);
  });

  testWidgets('a single leg shows no data-kind glyphs', (tester) async {
    await pumpPhone(
      tester,
      InferenceSourceBadge(legs: [leg(Provenance.sdkOnDevice)]),
    );
    expect(find.byIcon(Icons.notes), findsNothing);
  });

  testWidgets('a result arrives with a short fade, settled after it', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      InferenceSourceBadge(legs: [leg(Provenance.sdkOnDevice)]),
    );
    final arrival = find.byType(TweenAnimationBuilder<double>);
    expect(arrival, findsOneWidget);
    await tester.pumpAndSettle();
    final opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.byKey(const ValueKey('inference-source-badge')),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 1);
  });

  testWidgets('reduced motion: no arrival animation at all', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: InferenceSourceBadge(legs: [leg(Provenance.sdkCloud)]),
          ),
        ),
      ),
    );
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(find.text('Cloud · Gemini'), findsOneWidget);
  });
}
