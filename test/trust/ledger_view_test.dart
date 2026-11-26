import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/trust/ledger_source.dart';
import 'package:soussight/trust/ledger_view.dart';

import 'trust_test_helpers.dart';

void main() {
  group('LedgerSummary', () {
    test('separates allowed to leave from reported as sent', () {
      final summary = LedgerSummary.of([
        // preferOnDevice: allowed to leave, but the SDK ran it locally.
        leg(
          Provenance.sdkOnDevice,
          mode: HybridMode.preferOnDevice,
          transferPermitted: true,
          kinds: {DataKind.text, DataKind.image},
        ),
        leg(
          Provenance.sdkOnDevice,
          feature: 'local_watch',
          kinds: {DataKind.image},
        ),
        leg(Provenance.sdkCloud, feature: 'coach_lite'),
        leg(
          Provenance.cloudAdapter,
          feature: 'nearby',
          kinds: {DataKind.location},
        ),
        leg(
          Provenance.unknown,
          feature: 'coach_lite',
          error: HybridErrorCode.network,
        ),
        leg(Provenance.simulated, transferPermitted: false),
      ]);

      expect(summary.total, 6);
      expect(
        [for (final r in summary.allowedToLeave) r.feature],
        ['pantry_scan', 'coach_lite', 'nearby', 'coach_lite'],
      );
      expect(
        [for (final r in summary.reportedSent) r.feature],
        ['coach_lite', 'nearby'],
      );
      expect([for (final r in summary.maybeSent) r.feature], ['coach_lite']);
      expect(
        [for (final r in summary.stayedLocal) r.feature],
        ['pantry_scan', 'local_watch'],
      );
      expect(summary.simulated, hasLength(1));
    });

    test('groups repeats of the same feature, kinds and route', () {
      final summary = LedgerSummary.of([
        for (var i = 0; i < 3; i++)
          leg(
            Provenance.sdkOnDevice,
            feature: 'local_watch',
            kinds: {DataKind.image},
          ),
      ]);
      expect(summary.stayedLocal.single.count, 3);
    });
  });

  testWidgets('sheet shows the sections, kinds only, and the storage note', (
    tester,
  ) async {
    final ledger = ListLedgerSource([
      leg(
        Provenance.sdkOnDevice,
        mode: HybridMode.preferOnDevice,
        transferPermitted: true,
        kinds: {DataKind.text, DataKind.image},
      ),
      leg(
        Provenance.sdkCloud,
        feature: 'pantry_voice',
        kinds: {DataKind.audio},
      ),
    ]);
    await pumpPhone(
      tester,
      LedgerView(ledger: ledger, localModelFamily: 'Gemini Nano'),
    );

    expect(
      find.text(
        '2 AI requests this session: 1 stayed on this device, '
        '1 reported as sent.',
      ),
      findsOneWidget,
    );

    final allowed = find.byKey(const ValueKey('ledger-allowed'));
    final sent = find.byKey(const ValueKey('ledger-sent'));
    final local = find.byKey(const ValueKey('ledger-local'));
    // The photo was allowed to leave, but only the voice clip was sent.
    expect(
      find.descendant(
        of: allowed,
        matching: find.text('photo and text · On this device · Gemini Nano'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sent,
        matching: find.text('voice clip · Cloud · Gemini'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sent, matching: find.textContaining('photo')),
      findsNothing,
    );
    expect(
      find.descendant(of: local, matching: find.text('Pantry scan')),
      findsOneWidget,
    );
    expect(find.text('May have been sent'), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ledger-live-note')),
      200,
    );
    expect(find.text(sessionStorageNote), findsOneWidget);
    expect(find.text(liveCoachNote), findsOneWidget);
    expect(sessionStorageNote, contains('Firestore'));
    expect(liveCoachNote, contains('facts you confirmed'));
    expect(liveCoachNote, contains('allergy context'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('updates when the ledger records a leg', (tester) async {
    final ledger = ListLedgerSource();
    await pumpPhone(tester, LedgerView(ledger: ledger));
    expect(find.text('No AI requests yet this session.'), findsOneWidget);
    expect(find.byKey(const ValueKey('ledger-sent-empty')), findsOneWidget);

    ledger.add(
      leg(
        Provenance.unknown,
        feature: 'coach_lite',
        error: HybridErrorCode.timeout,
      ),
    );
    await tester.pump();

    expect(find.text('No AI requests yet this session.'), findsNothing);
    expect(find.byKey(const ValueKey('ledger-sent-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('ledger-maybe')), findsOneWidget);
    expect(find.text('May have been sent'), findsOneWidget);
  });
}
