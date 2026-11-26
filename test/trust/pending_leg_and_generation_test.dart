// A pending leg reads as running, never as stopped (trust labels and the
// source-details sheet), and the ledger's generation advances on every
// session reset (SS-105 review).

import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/trust/inference_source_badge.dart';
import 'package:soussight/trust/trust_labels.dart';

import 'trust_test_helpers.dart';

void main() {
  test('pending legs are explained as still running', () {
    final allowed = leg(Provenance.unknown, transferPermitted: true);
    final local = leg(Provenance.unknown, transferPermitted: false);
    expect(legPending(allowed), isTrue);
    expect(legPending(local), isTrue);
    expect(legExplanation(allowed), startsWith('This is still running.'));
    expect(legExplanation(allowed), isNot(contains('stopped')));
    expect(legExplanation(local), contains('not allowed to leave'));
    // Finished legs keep their outcome wording.
    final failed = leg(
      Provenance.unknown,
      transferPermitted: true,
      error: HybridErrorCode.network,
    );
    expect(legPending(failed), isFalse);
    expect(legLabel(failed), 'May have been sent');
    expect(legExplanation(failed), outcomeExplanation(LegOutcome.maybeSent));
    expect(legPending(leg(Provenance.sdkOnDevice)), isFalse);
  });

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
    expect(find.textContaining('This is still running.'), findsOneWidget);
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
}
