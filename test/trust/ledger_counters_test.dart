import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/trust/ledger_source.dart';
import 'package:soussight/trust/ledger_view.dart';

import 'trust_test_helpers.dart';

List<String> sentences(LedgerCounters c) => [
  c.headline.sentence,
  for (final line in c.details) line.sentence,
];

void main() {
  group('LedgerCounters', () {
    test('no legs: zero photos left the kitchen', () {
      final c = LedgerCounters.of(const []);
      expect(c.headline.sentence, '0 photos left your kitchen this session');
      expect(c.details, isEmpty);
    });

    test('counts only legs reported as sent, never permission alone', () {
      final c = LedgerCounters.of([
        // Allowed to leave, but the SDK ran it here: not sent.
        leg(
          Provenance.sdkOnDevice,
          mode: HybridMode.preferOnDevice,
          transferPermitted: true,
          kinds: {DataKind.image, DataKind.text},
        ),
        leg(
          Provenance.sdkOnDevice,
          feature: 'local_watch',
          kinds: {DataKind.image},
        ),
        leg(
          Provenance.sdkCloud,
          feature: 'pantry_voice',
          kinds: {DataKind.audio},
        ),
      ]);
      expect(c.sent(DataKind.image), 0);
      expect(c.onDevice(DataKind.image), 2);
      expect(c.sent(DataKind.audio), 1);
      expect(sentences(c), [
        '0 photos left your kitchen this session',
        '1 voice clip went to Google cloud',
        '2 photo checks stayed on this device',
      ]);
    });

    test('sdkCloud and cloudAdapter photos are sent', () {
      final c = LedgerCounters.of([
        leg(Provenance.sdkCloud, kinds: {DataKind.image}),
        leg(
          Provenance.cloudAdapter,
          feature: 'local_watch_cloud_check',
          kinds: {DataKind.image},
        ),
      ]);
      expect(c.headline.sentence, '2 photos went to Google cloud this session');
    });

    test('unknown + permitted may have been sent; unknown + not is not', () {
      final c = LedgerCounters.of([
        leg(
          Provenance.unknown,
          transferPermitted: true,
          kinds: {DataKind.image},
          error: HybridErrorCode.network,
        ),
        leg(
          Provenance.unknown,
          feature: 'local_watch',
          transferPermitted: false,
          kinds: {DataKind.image},
          error: HybridErrorCode.timeout,
        ),
      ]);
      expect(c.maybeSent(DataKind.image), 1);
      expect(c.sent(DataKind.image), 0);
      // Never "0 photos left" while one may have.
      expect(
        c.headline.sentence,
        '1 photo may have left your kitchen this session',
      );
    });

    test('simulated legs are not counted anywhere', () {
      final c = LedgerCounters.of([
        leg(
          Provenance.simulated,
          transferPermitted: false,
          kinds: {DataKind.image, DataKind.audio},
        ),
      ]);
      expect(c.sent(DataKind.image), 0);
      expect(c.onDevice(DataKind.image), 0);
      expect(c.headline.count, 0);
      expect(c.details, isEmpty);
    });

    test('a Live connection is a stream, not one photo', () {
      final c = LedgerCounters.of([
        leg(
          Provenance.cloudAdapter,
          feature: 'live',
          kinds: {DataKind.text, DataKind.image, DataKind.audio},
        ),
      ]);
      expect(c.sent(DataKind.image), 0);
      expect(c.liveStreams, 1);
      expect(
        c.headline.sentence,
        '1 Live coach connection streamed your camera and microphone to '
        'Google cloud this session',
      );
      expect(c.headline.sentence, isNot(contains('0 photos')));
    });

    test('photos lead; Live, maybe and other kinds follow', () {
      final c = LedgerCounters.of([
        leg(Provenance.sdkCloud, kinds: {DataKind.image}),
        leg(
          Provenance.unknown,
          transferPermitted: true,
          kinds: {DataKind.image},
        ),
        leg(
          Provenance.cloudAdapter,
          feature: 'live',
          kinds: {DataKind.image, DataKind.audio},
        ),
        leg(
          Provenance.cloudAdapter,
          feature: 'nearby',
          kinds: {DataKind.location},
        ),
        leg(Provenance.sdkCloud, feature: 'coach_lite'),
        leg(Provenance.sdkCloud, feature: 'coach_lite'),
      ]);
      expect(sentences(c), [
        '1 photo went to Google cloud this session',
        '1 Live coach connection streamed camera and microphone',
        '1 more photo may have been sent',
        '1 location share went to Google cloud',
        '2 text requests went to Google cloud',
      ]);
    });
  });

  testWidgets('the headline updates as legs arrive', (tester) async {
    final ledger = ListLedgerSource();
    await pumpPhone(tester, LedgerView(ledger: ledger));
    expect(find.text('0'), findsOneWidget);
    expect(find.text('photos left your kitchen this session'), findsOneWidget);
    expect(
      find.bySemanticsLabel('0 photos left your kitchen this session'),
      findsOneWidget,
    );

    ledger.add(leg(Provenance.sdkCloud, kinds: {DataKind.image}));
    await tester.pumpAndSettle();
    expect(
      find.text('photo went to Google cloud this session'),
      findsOneWidget,
    );
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion: the count changes without a transition', (
    tester,
  ) async {
    final ledger = ListLedgerSource();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: LedgerView(ledger: ledger)),
        ),
      ),
    );
    ledger.add(leg(Provenance.sdkCloud, kinds: {DataKind.image}));
    await tester.pump();
    // The old count is gone on the very next frame.
    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });
}
