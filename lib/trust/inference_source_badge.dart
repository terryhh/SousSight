// Per-leg provenance badges for a result shown to the cook (SS-070).
//
// A result built from several legs (for example a local photo leg and a cloud
// voice leg) shows one chip per leg, never one merged badge (DESIGN.md §5).

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import 'route_reason_text.dart';
import 'trust_labels.dart';
import 'trust_motion.dart';
import '../app/centered_scroll.dart';

class InferenceSourceBadge extends StatelessWidget {
  const InferenceSourceBadge({
    super.key,
    required this.legs,
    this.localModelFamily,
    this.reason,
  });

  /// Every attempt behind this result, in order.
  final List<InferenceLeg> legs;

  /// `HybridCapabilities.local?.modelFamily`, e.g. 'Gemini Nano'. Shown on
  /// on-device chips when the leg carries no observed model label.
  final String? localModelFamily;

  /// Why the result went where it did, if the dispatcher said.
  final RouteReason? reason;

  String _label(InferenceLeg leg) {
    final base = legLabel(leg);
    final error = leg.error;
    return error == null ? base : '$base (${errorLabel(error)})';
  }

  @override
  Widget build(BuildContext context) {
    if (legs.isEmpty) return const SizedBox.shrink();
    final labels = [for (final leg in legs) _label(leg)];
    void open() => showInferenceDetails(
      context,
      legs: legs,
      localModelFamily: localModelFamily,
      reason: reason,
    );
    // A new result (different legs) replays the arrival transition.
    final signature = [
      for (final leg in legs)
        '${leg.requestId}:${leg.provenance.name}:${leg.error?.name}',
    ].join('|');
    return ArrivalTransition(
      signature: signature,
      child: Semantics(
        button: true,
        excludeSemantics: true,
        label: 'Where this ran: ${labels.join('; ')}. Tap for details.',
        onTap: open,
        child: Wrap(
          key: const ValueKey('inference-source-badge'),
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < legs.length; i++)
              _LegChip(
                key: ValueKey('inference-leg-$i'),
                outcome: legOutcome(legs[i]),
                label: labels[i],
                // With several legs, show which data each one carried.
                kinds: legs.length > 1 ? legs[i].kinds : const {},
                onTap: open,
              ),
          ],
        ),
      ),
    );
  }
}

/// A small glyph for each data kind, in the trust surface's order.
IconData dataKindIcon(DataKind kind) => switch (kind) {
  DataKind.image => Icons.photo_camera_outlined,
  DataKind.audio => Icons.mic_none,
  DataKind.location => Icons.place_outlined,
  DataKind.text => Icons.notes,
};

class _LegChip extends StatelessWidget {
  const _LegChip({
    super.key,
    required this.outcome,
    required this.label,
    required this.kinds,
    required this.onTap,
  });

  final LegOutcome outcome;
  final String label;
  final Set<DataKind> kinds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = outcomeColors(outcome);
    final onDevice = outcome == LegOutcome.onDevice;
    return Material(
      color: colors.background,
      shape: StadiumBorder(
        side: BorderSide(color: colors.border, width: onDevice ? 1.4 : 1),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The outcome icon sits in a solid disc so on-device and
                // cloud read apart at a glance, not by colour alone.
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.border,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      outcomeIcon(outcome),
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                for (final kind in orderedDataKinds(kinds)) ...[
                  Icon(dataKindIcon(kind), size: 15, color: colors.foreground),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: colors.foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: colors.foreground.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the per-leg details for one result.
Future<void> showInferenceDetails(
  BuildContext context, {
  required List<InferenceLeg> legs,
  String? localModelFamily,
  RouteReason? reason,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  constraints: fullWidthSheet,
  builder: (context) => InferenceDetails(
    legs: legs,
    localModelFamily: localModelFamily,
    reason: reason,
  ),
);

/// What each leg sent and where it ran. Data kinds only, never content.
class InferenceDetails extends StatelessWidget {
  const InferenceDetails({
    super.key,
    required this.legs,
    this.localModelFamily,
    this.reason,
  });

  final List<InferenceLeg> legs;
  final String? localModelFamily;
  final RouteReason? reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CenteredListView(
      key: const ValueKey('inference-details'),
      shrinkWrap: true,
      bottom: 28,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Where this answer came from',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (reason case final reason?) ...[
          const SizedBox(height: 8),
          Text(routeReasonSentence(reason)),
        ],
        const SizedBox(height: 12),
        for (var i = 0; i < legs.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _LegDetail(
              index: i,
              count: legs.length,
              leg: legs[i],
              localModelFamily: localModelFamily,
            ),
          ),
        Text(
          'Only the kinds of data are listed here, never what was in them. '
          "The camera can't confirm doneness, temperature or allergens.",
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _LegDetail extends StatelessWidget {
  const _LegDetail({
    required this.index,
    required this.count,
    required this.leg,
    this.localModelFamily,
  });

  final int index;
  final int count;
  final InferenceLeg leg;
  final String? localModelFamily;

  @override
  Widget build(BuildContext context) {
    final outcome = legOutcome(leg);
    final colors = outcomeColors(outcome);
    final where = legLabel(leg);
    final model = legModelName(leg, localModel: localModelFamily);
    final kinds = dataKindsPhrase(leg.kinds);
    final permission = leg.transferPermitted
        ? 'Allowed to leave this device: $kinds.'
        : 'Not allowed to leave this device.';
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(outcomeIcon(outcome), color: colors.foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count > 1
                          ? 'Step ${index + 1} of $count · ${featureLabel(leg.feature)}'
                          : featureLabel(leg.feature),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      where,
                      style: TextStyle(
                        color: colors.foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(outcomeExplanation(outcome)),
                    if (model != null) Text('Model: $model'),
                    Text('Used: $kinds. $permission'),
                    if (leg.error case final error?)
                      Text("This attempt didn't finish: ${errorLabel(error)}."),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
