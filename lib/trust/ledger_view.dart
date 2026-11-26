// The session ledger sheet (DESIGN.md §5, card SS-070).
//
// Separates what SousSight *allowed* to leave the device from what the SDK or
// our own client *reported* as sent. Lists data kinds only, never content.

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import 'ledger_source.dart';
import 'trust_labels.dart';

/// What the session keeps, and what the Live coach is told. Static, because
/// it describes the app, not one request. Keep in step with
/// `FirestoreSessionRepository`, `CookingSession.toMap` and
/// `CookingCoordinator.cookingContext`.
const sessionStorageNote =
    'Your cooking session is saved to Firestore so you can pick it up again: '
    'the recipe, ingredient checks, substitutions, step progress, your timer, '
    'the facts you confirm (including allergy answers) and the delivery status '
    'of any dinner-ready message. Camera frames and voice clips are not saved '
    'there.';

const liveCoachNote =
    'When the Live coach is on, it is told the recipe, the facts you confirmed '
    "and the recipe's allergy context, and it hears and sees what you share "
    'while it is connected.';

Future<void> showLedgerSheet(
  BuildContext context, {
  required LedgerSource ledger,
  String? localModelFamily,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 720),
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.85,
    minChildSize: 0.4,
    maxChildSize: 0.95,
    builder: (context, controller) => LedgerView(
      ledger: ledger,
      localModelFamily: localModelFamily,
      controller: controller,
    ),
  ),
);

/// One grouped row: same feature, kinds and outcome, with a count.
class LedgerRow {
  const LedgerRow({
    required this.feature,
    required this.kinds,
    required this.outcome,
    required this.count,
  });
  final String feature;
  final Set<DataKind> kinds;
  final LegOutcome outcome;
  final int count;
}

/// The ledger split into the groups the sheet shows. Pure; tested directly.
class LedgerSummary {
  LedgerSummary._(
    this.total,
    this.allowedToLeave,
    this.reportedSent,
    this.maybeSent,
    this.stayedLocal,
    this.notFinishedLocal,
    this.simulated,
  );

  factory LedgerSummary.of(List<InferenceLeg> legs) {
    List<LedgerRow> group(Iterable<InferenceLeg> subset) {
      final rows = <String, LedgerRow>{};
      for (final leg in subset) {
        final kinds = {
          for (final k in DataKind.values)
            if (leg.kinds.contains(k)) k,
        };
        final key =
            '${leg.feature}|${kinds.map((k) => k.name).join(',')}|${legOutcome(leg).name}';
        final prior = rows[key];
        rows[key] = LedgerRow(
          feature: leg.feature,
          kinds: kinds,
          outcome: legOutcome(leg),
          count: (prior?.count ?? 0) + 1,
        );
      }
      return rows.values.toList();
    }

    return LedgerSummary._(
      legs.length,
      group(legs.where((l) => l.transferPermitted)),
      group(legs.where((l) => reportedAsSent(legOutcome(l)))),
      group(legs.where((l) => legOutcome(l) == LegOutcome.maybeSent)),
      group(legs.where((l) => legOutcome(l) == LegOutcome.onDevice)),
      group(legs.where((l) => legOutcome(l) == LegOutcome.notFinishedLocal)),
      group(legs.where((l) => legOutcome(l) == LegOutcome.simulated)),
    );
  }

  final int total;
  final List<LedgerRow> allowedToLeave;
  final List<LedgerRow> reportedSent;
  final List<LedgerRow> maybeSent;
  final List<LedgerRow> stayedLocal;

  /// Failed or blocked attempts that were never allowed to leave.
  final List<LedgerRow> notFinishedLocal;
  final List<LedgerRow> simulated;
}

class LedgerView extends StatelessWidget {
  const LedgerView({
    super.key,
    required this.ledger,
    this.localModelFamily,
    this.controller,
  });

  final LedgerSource ledger;
  final String? localModelFamily;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ledger,
    builder: (context, _) => _build(context, LedgerSummary.of(ledger.legs)),
  );

  Widget _build(BuildContext context, LedgerSummary summary) {
    final theme = Theme.of(context);
    Widget heading(String text, {Key? key}) => Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 6),
      child: Semantics(
        header: true,
        child: Text(
          text,
          key: key,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
    Widget note(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: theme.textTheme.bodySmall),
    );
    Widget rows(List<LedgerRow> rows, String empty, String section) =>
        rows.isEmpty
        ? Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(empty, key: ValueKey('ledger-$section-empty')),
          )
        : Column(
            key: ValueKey('ledger-$section'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final row in rows)
                _LedgerRowTile(row: row, localModelFamily: localModelFamily),
            ],
          );

    final sentCount = summary.reportedSent.fold(0, (n, r) => n + r.count);
    final localCount = summary.stayedLocal.fold(0, (n, r) => n + r.count);

    return ListView(
      key: const ValueKey('ledger-view'),
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Semantics(
          header: true,
          child: Text(
            'What left this device',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: true,
          child: Text(
            summary.total == 0
                ? 'No AI requests yet this session.'
                : '${summary.total} AI ${summary.total == 1 ? 'request' : 'requests'} '
                      'this session: $localCount stayed on this device, '
                      '$sentCount reported as sent.',
            key: const ValueKey('ledger-summary'),
          ),
        ),
        heading('Allowed to leave'),
        note(
          'SousSight allowed these to go to the cloud. Being allowed is not '
          'proof that anything was sent.',
        ),
        rows(
          summary.allowedToLeave,
          'Nothing was allowed to leave.',
          'allowed',
        ),
        heading('Reported as sent'),
        note(
          'The Firebase AI Logic SDK or our own client said these went out.',
        ),
        rows(summary.reportedSent, 'Nothing was reported as sent.', 'sent'),
        if (summary.maybeSent.isNotEmpty) ...[
          heading('May have been sent'),
          note(
            'These were allowed to leave and then stopped with an error, so '
            "we can't tell whether they went out.",
          ),
          rows(summary.maybeSent, '', 'maybe'),
        ],
        heading('Stayed on this device'),
        rows(summary.stayedLocal, 'Nothing ran on this device yet.', 'local'),
        if (summary.notFinishedLocal.isNotEmpty) ...[
          heading("Didn't finish"),
          note(
            "These stopped before giving an answer. They weren't allowed to "
            'leave, so nothing left this device.',
          ),
          rows(summary.notFinishedLocal, '', 'not-finished'),
        ],
        if (summary.simulated.isNotEmpty) ...[
          heading('Simulated'),
          note('Rehearsal only. No model ran and nothing was sent.'),
          rows(summary.simulated, '', 'simulated'),
        ],
        heading('What this session keeps'),
        const Text(sessionStorageNote, key: ValueKey('ledger-storage-note')),
        const SizedBox(height: 8),
        const Text(liveCoachNote, key: ValueKey('ledger-live-note')),
        const SizedBox(height: 12),
        note(
          'This list covers this session only, shows kinds of data and never '
          'their content, and is cleared when you close SousSight.',
        ),
      ],
    );
  }
}

class _LedgerRowTile extends StatelessWidget {
  const _LedgerRowTile({required this.row, this.localModelFamily});

  final LedgerRow row;
  final String? localModelFamily;

  @override
  Widget build(BuildContext context) {
    final colors = outcomeColors(row.outcome);
    final where = outcomeLabel(row.outcome, localModel: localModelFamily);
    final times = row.count == 1 ? '' : ' · ${row.count} times';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        label:
            '${featureLabel(row.feature)}: ${dataKindsPhrase(row.kinds)}. $where$times.',
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(
                  outcomeIcon(row.outcome),
                  size: 20,
                  color: colors.foreground,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        featureLabel(row.feature),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text('${dataKindsPhrase(row.kinds)} · $where$times'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
