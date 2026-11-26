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

    // Regression (Codex review of #180): failed local-only attempts are not
    // possible uploads.
    test('a failed local-only leg is not counted as possibly sent', () {
      final summary = LedgerSummary.of([
        leg(
          Provenance.unknown,
          feature: 'local_watch',
          mode: HybridMode.onlyOnDevice,
          transferPermitted: false,
          kinds: {DataKind.image},
          error: HybridErrorCode.timeout,
        ),
        leg(
          Provenance.unknown,
          feature: 'coach_lite',
          mode: HybridMode.preferOnDevice,
          transferPermitted: true,
          error: HybridErrorCode.network,
        ),
      ]);
      expect([for (final r in summary.maybeSent) r.feature], ['coach_lite']);
      expect(
        [for (final r in summary.notFinishedLocal) r.feature],
        ['local_watch'],
      );
      expect(
        [for (final r in summary.allowedToLeave) r.feature],
        ['coach_lite'],
      );
      expect(summary.reportedSent, isEmpty);
      expect(summary.stayedLocal, isEmpty);
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

    expect(find.text('What we sent'), findsOneWidget);
    expect(
      find.text(
        '2 requests this session: 1 answered on this device, '
        '1 sent online.',
      ),
      findsOneWidget,
    );

    // The headline counts from legs: the photo stayed, the voice clip went.
    expect(find.text('photos left your kitchen this session'), findsOneWidget);
    expect(
      find.text('1 voice clip sent online to Google\'s AI'),
      findsOneWidget,
    );

    final allowed = find.byKey(const ValueKey('ledger-allowed'));
    final sent = find.byKey(const ValueKey('ledger-sent'));
    final local = find.byKey(const ValueKey('ledger-local'));
    // The photo was allowed to leave, but only the voice clip was sent.
    expect(
      find.descendant(
        of: allowed,
        matching: find.text('photo and text · On this device'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sent,
        matching: find.text("voice clip · Sent online to Google's AI"),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sent, matching: find.textContaining('photo')),
      findsNothing,
    );
    await tester.scrollUntilVisible(local, 200);
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
    // SS-089: no product names in the plain note; they live under Details.
    expect(sessionStorageNote, isNot(contains('Firestore')));
    expect(sessionStorageDetails, contains('Firestore'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ledger-details')),
      200,
    );
    expect(find.text(sessionStorageDetails), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ledger-details')));
    await tester.pumpAndSettle();
    expect(find.text(sessionStorageDetails), findsOneWidget);
    expect(liveCoachNote, contains('facts you confirmed'));
    expect(liveCoachNote, contains('allergy context'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sheet lists a failed local-only leg under Didn\'t finish', (
    tester,
  ) async {
    final ledger = ListLedgerSource([
      leg(
        Provenance.unknown,
        feature: 'local_watch',
        mode: HybridMode.onlyOnDevice,
        transferPermitted: false,
        kinds: {DataKind.image},
        error: HybridErrorCode.timeout,
      ),
    ]);
    await pumpPhone(tester, LedgerView(ledger: ledger));
    expect(find.text('May have been sent'), findsNothing);
    expect(find.byKey(const ValueKey('ledger-maybe')), findsNothing);
    expect(find.byKey(const ValueKey('ledger-allowed-empty')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ledger-not-finished')),
      200,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ledger-not-finished')),
        matching: find.text("photo · Didn't finish · nothing left this device"),
      ),
      findsOneWidget,
    );
  });

  testWidgets('updates when the ledger records a leg', (tester) async {
    final ledger = ListLedgerSource();
    await pumpPhone(tester, LedgerView(ledger: ledger));
    // SS-089: never "no requests" — a blocked attempt is not listed, and
    // the empty line says so instead of implying nothing was tried.
    expect(
      find.textContaining('Nothing has been sent online this session'),
      findsOneWidget,
    );
    expect(find.textContaining("couldn't start isn't listed"), findsOneWidget);
    expect(find.byKey(const ValueKey('ledger-sent-empty')), findsOneWidget);

    ledger.add(
      leg(
        Provenance.unknown,
        feature: 'coach_lite',
        error: HybridErrorCode.timeout,
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('Nothing has been sent online this session'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('ledger-sent-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('ledger-maybe')), findsOneWidget);
    expect(find.text('May have been sent'), findsOneWidget);
  });
}
