import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/trust/ledger_source.dart';

import 'trust_test_helpers.dart';

void main() {
  test(
    'keeps legs in order, notifies per change and never exposes its list',
    () {
      final source = ListLedgerSource([leg(Provenance.sdkOnDevice)]);
      var notified = 0;
      source.addListener(() => notified++);

      source.add(leg(Provenance.sdkCloud));
      source.addAll([
        leg(Provenance.sdkOnDevice, feature: 'local_watch'),
        leg(Provenance.sdkCloud, feature: 'local_watch'),
      ]);

      expect(notified, 2, reason: 'one notification per add or addAll');
      expect(source.legs.map((l) => (l.provenance, l.feature)), [
        (Provenance.sdkOnDevice, 'pantry_scan'),
        (Provenance.sdkCloud, 'pantry_scan'),
        (Provenance.sdkOnDevice, 'local_watch'),
        (Provenance.sdkCloud, 'local_watch'),
      ]);
      expect(
        () => source.legs.add(leg(Provenance.sdkCloud)),
        throwsUnsupportedError,
        reason: 'the trust UI cannot rewrite history',
      );
    },
  );

  test('the initial legs are copied, not shared', () {
    final initial = [leg(Provenance.sdkOnDevice)];
    final source = ListLedgerSource(initial);
    initial.add(leg(Provenance.sdkCloud));
    expect(source.legs, hasLength(1));
  });
}
