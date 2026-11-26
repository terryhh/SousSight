import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/trust/trust_labels.dart';

void main() {
  test('every outcome has a label, explanation, icon and colours', () {
    final icons = <Object>{};
    for (final outcome in LegOutcome.values) {
      expect(outcomeLabel(outcome), isNotEmpty);
      expect(outcomeExplanation(outcome), isNotEmpty);
      icons.add(outcomeIcon(outcome));
      expect(outcomeColors(outcome).foreground, isNotNull);
    }
    // Cloud outcomes share an icon; every other outcome has its own.
    expect(icons, hasLength(LegOutcome.values.length - 1));
    expect(
      outcomeExplanation(LegOutcome.simulated),
      contains('nothing was sent'),
    );
  });

  test('only SDK or client reports count as sent', () {
    expect(reportedAsSent(LegOutcome.cloudSdk), isTrue);
    expect(reportedAsSent(LegOutcome.cloudAdapter), isTrue);
    for (final o in [
      LegOutcome.onDevice,
      LegOutcome.maybeSent,
      LegOutcome.notFinishedLocal,
      LegOutcome.simulated,
    ]) {
      expect(reportedAsSent(o), isFalse, reason: o.name);
    }
  });

  test('data kinds read in a fixed order', () {
    expect(orderedDataKinds(DataKind.values.toSet()), [
      DataKind.image,
      DataKind.audio,
      DataKind.location,
      DataKind.text,
    ]);
    expect(dataKindsPhrase({}), 'no data');
    expect(dataKindsPhrase({DataKind.location}), 'location');
    expect(
      dataKindsPhrase({DataKind.text, DataKind.image, DataKind.audio}),
      'photo, voice clip and text',
    );
  });

  test('unknown features get a readable fallback label', () {
    expect(featureLabel('coach_lite'), 'Typed question');
    expect(featureLabel('local_watch_cloud_check'), 'Photo check online');
    expect(featureLabel('spice_rack'), 'Spice rack');
    expect(featureLabel('_'), 'Feature');
  });

  test('every error code has a short phrase', () {
    final labels = {for (final e in HybridErrorCode.values) errorLabel(e)};
    expect(labels, hasLength(HybridErrorCode.values.length));
    expect(labels.every((l) => l.isNotEmpty), isTrue);
  });
}
