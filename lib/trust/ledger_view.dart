// The session ledger sheet (DESIGN.md §5, card SS-070).
//
// Separates what SousSight *allowed* to leave the device from what the SDK or
// our own client *reported* as sent. Lists data kinds only, never content.

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import 'ledger_source.dart';
import 'trust_labels.dart';
import 'trust_motion.dart';

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

/// One line of the ledger's headline counter: "0 photos left your kitchen
/// this session". [count] is shown large; [phrase] follows it.
class LedgerCount {
  const LedgerCount(this.count, this.phrase, this.tone);
  final int count;
  final String phrase;

  /// Which outcome's colours the line uses.
  final LegOutcome tone;

  String get sentence => '$count $phrase';
}

/// The headline counters for the ledger sheet. Computed only from the legs:
/// a data kind counts as sent when a leg carrying it was reported as sent
/// (`sdkCloud` or `cloudAdapter`), and as "may have been sent" when a leg
/// carrying it was allowed to leave and then ended `unknown`. Settings,
/// intent and consent never move these numbers. Pure; tested directly.
class LedgerCounters {
  LedgerCounters._(
    this._sent,
    this._maybe,
    this._local,
    this.liveStreams,
    this.liveMaybe,
  );

  factory LedgerCounters.of(List<InferenceLeg> legs) {
    final sent = <DataKind, int>{};
    final maybe = <DataKind, int>{};
    final local = <DataKind, int>{};
    var liveStreams = 0, liveMaybe = 0;
    for (final leg in legs) {
      final outcome = legOutcome(leg);
      // A Live connection streams camera and microphone for as long as it is
      // on, so it is counted as a connection, never as "1 photo".
      if (streamingFeatures.contains(leg.feature)) {
        if (reportedAsSent(outcome)) liveStreams++;
        if (outcome == LegOutcome.maybeSent) liveMaybe++;
        continue;
      }
      final bucket = reportedAsSent(outcome)
          ? sent
          : outcome == LegOutcome.maybeSent
          ? maybe
          : outcome == LegOutcome.onDevice
          ? local
          : null;
      if (bucket == null) continue;
      for (final kind in leg.kinds) {
        bucket[kind] = (bucket[kind] ?? 0) + 1;
      }
    }
    return LedgerCounters._(sent, maybe, local, liveStreams, liveMaybe);
  }

  /// Features whose one leg covers a continuous stream (Live connect and
  /// each resume), not a single payload.
  static const streamingFeatures = {'live'};

  /// Live coach connections reported as made (camera and microphone stream
  /// while it is on).
  final int liveStreams;

  /// Live connections that were allowed and then failed.
  final int liveMaybe;

  final Map<DataKind, int> _sent;
  final Map<DataKind, int> _maybe;
  final Map<DataKind, int> _local;

  /// Legs carrying [kind] that were reported as sent to the cloud.
  int sent(DataKind kind) => _sent[kind] ?? 0;

  /// Legs carrying [kind] that were allowed to leave and then failed, so we
  /// cannot tell whether they went out.
  int maybeSent(DataKind kind) => _maybe[kind] ?? 0;

  /// Legs carrying [kind] that the SDK reported ran on this device.
  int onDevice(DataKind kind) => _local[kind] ?? 0;

  static String noun(DataKind kind, int count) {
    final one = count == 1;
    return switch (kind) {
      DataKind.image => one ? 'photo' : 'photos',
      DataKind.audio => one ? 'voice clip' : 'voice clips',
      DataKind.location => one ? 'location share' : 'location shares',
      DataKind.text => one ? 'text request' : 'text requests',
    };
  }

  /// The big line, always about photos: the camera is what a cook worries
  /// about most. Never claims "0" while a photo may have been sent.
  LedgerCount get headline {
    final photos = sent(DataKind.image);
    final maybe = maybeSent(DataKind.image);
    if (photos > 0) {
      return LedgerCount(
        photos,
        '${noun(DataKind.image, photos)} went to Google cloud this session',
        LegOutcome.cloudSdk,
      );
    }
    if (liveStreams > 0) {
      return LedgerCount(
        liveStreams,
        '${_liveNoun(liveStreams)} streamed your camera and microphone to '
        'Google cloud this session',
        LegOutcome.cloudSdk,
      );
    }
    if (maybe > 0 || liveMaybe > 0) {
      final n = maybe > 0 ? maybe : liveMaybe;
      return LedgerCount(
        n,
        maybe > 0
            ? '${noun(DataKind.image, n)} may have left your kitchen this '
                  'session'
            : '${_liveNoun(n)} may have streamed your camera this session',
        LegOutcome.maybeSent,
      );
    }
    return LedgerCount(
      0,
      'photos left your kitchen this session',
      LegOutcome.onDevice,
    );
  }

  static String _liveNoun(int n) =>
      n == 1 ? 'Live coach connection' : 'Live coach connections';

  /// Smaller lines under the headline, most significant first: other kinds
  /// that were sent or may have been, extra photos that may have been, then
  /// what stayed on this device.
  List<LedgerCount> get details {
    final lines = <LedgerCount>[];
    final photosLead = sent(DataKind.image) > 0;
    if (photosLead && liveStreams > 0) {
      lines.add(
        LedgerCount(
          liveStreams,
          '${_liveNoun(liveStreams)} streamed camera and microphone',
          LegOutcome.cloudSdk,
        ),
      );
    }
    // The headline already shows Live maybe-streams only when nothing else
    // was sent or may have been.
    final headlineShowsLiveMaybe =
        sent(DataKind.image) == 0 &&
        liveStreams == 0 &&
        maybeSent(DataKind.image) == 0;
    if (liveMaybe > 0 && !headlineShowsLiveMaybe) {
      lines.add(
        LedgerCount(
          liveMaybe,
          '${_liveNoun(liveMaybe)} may have streamed',
          LegOutcome.maybeSent,
        ),
      );
    }
    if ((photosLead || liveStreams > 0) && maybeSent(DataKind.image) > 0) {
      final n = maybeSent(DataKind.image);
      lines.add(
        LedgerCount(
          n,
          '${photosLead ? 'more ' : ''}${noun(DataKind.image, n)} may have '
          'been sent',
          LegOutcome.maybeSent,
        ),
      );
    }
    for (final kind in const [
      DataKind.audio,
      DataKind.location,
      DataKind.text,
    ]) {
      final n = sent(kind);
      if (n > 0) {
        lines.add(
          LedgerCount(
            n,
            '${noun(kind, n)} went to Google cloud',
            LegOutcome.cloudSdk,
          ),
        );
      }
      final m = maybeSent(kind);
      if (m > 0) {
        lines.add(
          LedgerCount(
            m,
            '${noun(kind, m)} may have been sent',
            LegOutcome.maybeSent,
          ),
        );
      }
    }
    final localPhotos = onDevice(DataKind.image);
    if (localPhotos > 0) {
      lines.add(
        LedgerCount(
          localPhotos,
          localPhotos == 1
              ? 'photo check stayed on this device'
              : 'photo checks stayed on this device',
          LegOutcome.onDevice,
        ),
      );
    }
    return lines;
  }
}

/// The headline counter card at the top of the ledger sheet.
class LedgerHeadline extends StatelessWidget {
  const LedgerHeadline({super.key, required this.counters});

  final LedgerCounters counters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headline = counters.headline;
    final details = counters.details;
    final colors = outcomeColors(headline.tone);
    final duration = motionDuration(context, const Duration(milliseconds: 260));
    return Semantics(
      container: true,
      liveRegion: true,
      label: [
        headline.sentence,
        for (final line in details) line.sentence,
      ].join('. '),
      excludeSemantics: true,
      child: DecoratedBox(
        key: const ValueKey('ledger-headline'),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: colors.border.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  AnimatedSwitcher(
                    duration: duration,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween(begin: 0.85, end: 1.0).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Text(
                      '${headline.count}',
                      key: ValueKey('ledger-count-${headline.count}'),
                      style: theme.textTheme.displayMedium?.copyWith(
                        color: colors.foreground,
                        fontWeight: FontWeight.w800,
                        height: 1,
                        letterSpacing: -1.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      headline.phrase,
                      key: const ValueKey('ledger-headline-phrase'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.foreground,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final line in details)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(
                          outcomeIcon(line.tone),
                          size: 16,
                          color: outcomeColors(line.tone).foreground,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            line.sentence,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
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
        const SizedBox(height: 14),
        LedgerHeadline(counters: LedgerCounters.of(ledger.legs)),
        const SizedBox(height: 12),
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
