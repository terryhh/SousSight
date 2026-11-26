import 'package:flutter/material.dart';

import '../trust/inference_source_badge.dart';
import '../trust/trust_motion.dart';
import 'coach_lite.dart';
import 'timer_suggestion_card.dart';

/// What sits under a Coach Lite answer panel: where the answer ran (one chip
/// per leg, from the answer's own legs) and, when the model suggested one,
/// the app's own "Start timer" control. The panel itself is rendered by the
/// cooking surface above it.
class CoachLiteAnswerFooter extends StatelessWidget {
  const CoachLiteAnswerFooter({
    super.key,
    required this.answer,
    required this.onStartTimer,
    this.localModelFamily,
  });

  final CoachLiteAnswer answer;
  final void Function(String label, int seconds) onStartTimer;

  /// `HybridCapabilities.local?.modelFamily`, shown on on-device chips.
  final String? localModelFamily;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestion = answer.timerSuggestion;
    if (answer.legs.isEmpty && suggestion == null) {
      return const SizedBox.shrink();
    }
    return ArrivalTransition(
      signature: answer.stamp,
      child: Column(
        key: const ValueKey('coach-lite-footer'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (answer.legs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              // Wraps, so the badge drops under the label at large text
              // sizes or on narrow screens instead of overflowing.
              child: Wrap(
                key: const ValueKey('coach-lite-header'),
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 6,
                children: [
                  ExcludeSemantics(
                    child: Text(
                      'COACH LITE',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  InferenceSourceBadge(
                    key: const ValueKey('coach-lite-source'),
                    legs: answer.legs,
                    reason: answer.blocked,
                    localModelFamily: localModelFamily,
                  ),
                ],
              ),
            ),
          if (suggestion != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TimerSuggestionCard(
                key: ValueKey(answer.stamp),
                suggestion: suggestion,
                onStart: onStartTimer,
              ),
            ),
        ],
      ),
    );
  }
}
