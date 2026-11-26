// Per-leg provenance badges for a result shown to the cook (SS-070).
//
// A result built from several legs (for example a local photo leg and a cloud
// voice leg) shows one chip per leg, never one merged badge (DESIGN.md §5).

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import 'route_reason_text.dart';
import 'trust_labels.dart';

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
    final base = provenanceLabel(
      leg.provenance,
      localModel: leg.modelLabel ?? localModelFamily,
    );
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
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: 'Where this ran: ${labels.join('; ')}. Tap for details.',
      onTap: open,
      child: Wrap(
        key: const ValueKey('inference-source-badge'),
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < legs.length; i++)
            _LegChip(
              key: ValueKey('inference-leg-$i'),
              provenance: legs[i].provenance,
              label: labels[i],
              onTap: open,
            ),
        ],
      ),
    );
  }
}

class _LegChip extends StatelessWidget {
  const _LegChip({
    super.key,
    required this.provenance,
    required this.label,
    required this.onTap,
  });

  final Provenance provenance;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = provenanceColors(provenance);
    return Material(
      color: colors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  provenanceIcon(provenance),
                  size: 16,
                  color: colors.foreground,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: colors.foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
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
  constraints: const BoxConstraints(maxWidth: 720),
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
    return ListView(
      key: const ValueKey('inference-details'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
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
    final colors = provenanceColors(leg.provenance);
    final where = provenanceLabel(
      leg.provenance,
      localModel: leg.modelLabel ?? localModelFamily,
    );
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
              Icon(provenanceIcon(leg.provenance), color: colors.foreground),
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
                    Text(provenanceExplanation(leg.provenance)),
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
