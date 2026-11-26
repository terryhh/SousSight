// A pending leg is never described as stopped (trust labels and the
// source-details sheet), and the ledger's generation advances on every
// session reset (SS-105 review).

import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/trust/inference_source_badge.dart';
import 'package:soussight/trust/ledger_source.dart';
import 'package:soussight/trust/ledger_view.dart';
import 'package:soussight/trust/trust_labels.dart';

import 'trust_test_helpers.dart';

void main() {
  test('the maybe-sent explanation never says a request stopped', () {
    final text = outcomeExplanation(LegOutcome.maybeSent);
    expect(text, contains('may still be running'));
    expect(text, isNot(contains('stopped with an error')));
    // A pending leg and a failed one share the outcome, so the wording must
    // be true for both.
    final pending = leg(Provenance.unknown, transferPermitted: true);
    final failed = leg(
      Provenance.unknown,
      transferPermitted: true,
      error: HybridErrorCode.network,
    );
    expect(legOutcome(pending), LegOutcome.maybeSent);
    expect(legOutcome(failed), LegOutcome.maybeSent);
  });

  test(
    'a local-only leg, pending or stopped, never reads "didn\'t finish"',
    () {
      final pending = leg(Provenance.unknown, transferPermitted: false);
      final stopped = leg(
        Provenance.unknown,
        transferPermitted: false,
        error: HybridErrorCode.timeout,
      );
      for (final l in [pending, stopped]) {
        expect(legOutcome(l), LegOutcome.notFinishedLocal);
        expect(legLabel(l), 'Running or stopped · nothing left this device');
      }
      final text = outcomeExplanation(LegOutcome.notFinishedLocal);
      expect(text, startsWith('This is still running, or it stopped'));
      expect(text, isNot(contains("didn't finish")));
    },
  );

  testWidgets('the source-details sheet says a pending request is running', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final ledger = InferenceLedger(sessionId: 's');
    ledger.begin(leg(Provenance.sdkCloud, transferPermitted: true));
    final pending = ledger.legs.single;
    expect(pending.provenance, Provenance.unknown);
    unawaited(showInferenceDetails(context, legs: [pending]));
    await tester.pumpAndSettle();
    expect(find.textContaining('may still be running'), findsOneWidget);
    expect(find.textContaining('stopped with an error'), findsNothing);
  });

  test(
    'the ledger generation advances on every reset, even to the same ID',
    () {
      final ledger = InferenceLedger(sessionId: 'A');
      expect(ledger.generation, 0);
      ledger.startSession('B');
      expect(ledger.generation, 1);
      ledger.startSession('A');
      expect(ledger.generation, 2);
      expect(ledger.sessionId, 'A');
      ledger.startSession('A');
      expect(ledger.generation, 3);
    },
  );

  test('a pre-send refusal is "not finished locally", never "may have been '
      'sent"', () {
    final refused = leg(
      Provenance.unknown,
      transferPermitted: true,
      error: HybridErrorCode.rejectedBeforeSend,
    );
    expect(legOutcome(refused), LegOutcome.notFinishedLocal);
    expect(
      errorLabel(HybridErrorCode.rejectedBeforeSend),
      'refused before sending',
    );
    final web = leg(
      Provenance.unknown,
      transferPermitted: true,
      error: HybridErrorCode.unsupportedInput,
    );
    expect(legOutcome(web), LegOutcome.maybeSent);
  });

  testWidgets('the ledger sheet never says a maybe-sent leg stopped', (
    tester,
  ) async {
    final ledger = ListLedgerSource([
      leg(Provenance.unknown, transferPermitted: true),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LedgerView(ledger: ledger)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('may still be running'), findsWidgets);
    expect(find.textContaining('then stopped with an error'), findsNothing);
  });
}
