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
    test('no legs: zero photos recorded as sent', () {
      final c = LedgerCounters.of(const []);
      expect(
        c.headline.sentence,
        '0 photos recorded as sent online since you opened SousSight',
      );
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
        '0 photos recorded as sent online since you opened SousSight',
        '1 voice clip sent online to Google\'s AI',
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
      expect(
        c.headline.sentence,
        '2 photos sent online to Google\'s AI since you opened SousSight',
      );
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
        '1 photo may have been sent online since you opened SousSight',
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
        'Google\'s AI since you opened SousSight',
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
        '1 photo sent online to Google\'s AI since you opened SousSight',
        '1 Live coach connection streamed camera and microphone',
        '1 more photo may have been sent',
        '1 location share sent online to Google\'s AI',
        '2 text requests sent online to Google\'s AI',
      ]);
    });
  });

  testWidgets('the headline updates as legs arrive', (tester) async {
    final ledger = ListLedgerSource();
    await pumpPhone(tester, LedgerView(ledger: ledger));
    expect(find.text('0'), findsOneWidget);
    expect(
      find.text('photos recorded as sent online since you opened SousSight'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        '0 photos recorded as sent online since you opened SousSight',
      ),
      findsOneWidget,
    );

    ledger.add(leg(Provenance.sdkCloud, kinds: {DataKind.image}));
    await tester.pumpAndSettle();
    expect(
      find.text('photo sent online to Google\'s AI since you opened SousSight'),
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

  group('Live maybe-streams', () {
    InferenceLeg failedLive() => leg(
      Provenance.unknown,
      feature: 'live',
      transferPermitted: true,
      kinds: {DataKind.image, DataKind.audio},
      error: HybridErrorCode.network,
    );

    test('alone, a failed Live connection leads, and is not repeated', () {
      final c = LedgerCounters.of([failedLive()]);
      expect(c.liveMaybe, 1);
      expect(sentences(c), [
        '1 Live coach connection may have streamed your camera since you opened SousSight',
      ]);
    });

    test('behind a sent photo it is its own line', () {
      final c = LedgerCounters.of([
        leg(Provenance.sdkCloud, kinds: {DataKind.image}),
        failedLive(),
        failedLive(),
      ]);
      expect(sentences(c), [
        '1 photo sent online to Google\'s AI since you opened SousSight',
        '2 Live coach connections may have streamed',
      ]);
    });

    test('other kinds that may have been sent get a line each', () {
      final c = LedgerCounters.of([
        leg(
          Provenance.unknown,
          feature: 'pantry_voice',
          transferPermitted: true,
          kinds: {DataKind.audio},
        ),
      ]);
      expect(sentences(c), [
        '0 photos recorded as sent online since you opened SousSight',
        '1 voice clip may have been sent',
      ]);
    });
  });

  testWidgets('showLedgerSheet opens the sheet with simulated legs listed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ledger = ListLedgerSource([
      leg(Provenance.simulated, transferPermitted: false),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showLedgerSheet(context, ledger: ledger),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ledger-headline')), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ledger-simulated')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byKey(const ValueKey('ledger-simulated')), findsOneWidget);
  });
}
