import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/trust/inference_source_badge.dart';
import 'package:soussight/trust/route_reason_text.dart';
import 'package:soussight/trust/trust_labels.dart';

import 'trust_test_helpers.dart';

void main() {
  test('every provenance has its own label', () {
    expect(
      provenanceLabel(Provenance.sdkOnDevice, localModel: 'Gemini Nano'),
      'On this device · Gemini Nano',
    );
    expect(provenanceLabel(Provenance.sdkOnDevice), 'On this device');
    expect(provenanceLabel(Provenance.sdkCloud), 'Cloud · Gemini');
    expect(provenanceLabel(Provenance.cloudAdapter), 'Cloud');
    expect(provenanceLabel(Provenance.simulated), 'Simulated');
    expect(provenanceLabel(Provenance.unknown), 'May have been sent');
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
}
