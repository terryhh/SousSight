import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../trust/inference_source_badge.dart';
import '../trust/trust_motion.dart';
import 'coach_lite.dart';
import 'timer_suggestion_card.dart';

/// Why a typed question got no model answer, in plain words, or null when it
/// did (or was simply cancelled). Shown as a small status line under the
/// recipe's own step text, never mixed into it (SS-089).
String? coachLiteStatusLine(CoachLiteAnswer answer) => switch (answer.status) {
  CoachLiteStatus.answered || CoachLiteStatus.cancelled => null,
  CoachLiteStatus.invalid =>
    "I couldn't show that answer. The recipe step below still has what you "
        'need.',
  CoachLiteStatus.failed =>
    "I can't answer that right now — try the recipe step text below.",
  CoachLiteStatus.blocked => switch (answer.blocked) {
    RouteReason.modelDownloading =>
      'Help on this device is still downloading. Try again in a moment — '
          'the recipe step is below.',
    RouteReason.modelNotReady || RouteReason.noLocalModel =>
      "I can't answer questions on this device right now. The recipe step "
          'below still has what you need.',
    RouteReason.offline =>
      "You're offline, so I can't answer that right now. The recipe step is "
          'below.',
    RouteReason.localOnlySetting =>
      "You chose to keep questions on this device, and it can't answer them "
          'right now. The recipe step is below.',
    RouteReason.consentDeclined =>
      'OK — nothing was sent. The recipe step '
          'is below.',
    _ => "I can't answer that right now — try the recipe step text below.",
  },
};

/// What sits above a Coach Lite answer panel: where the answer ran (one chip
/// per leg, from the answer's own legs) and, when the model suggested one,
/// the app's own "Start timer" control. The panel itself is rendered by the
/// cooking surface below it.
class CoachLiteAnswerFooter extends StatelessWidget {
  const CoachLiteAnswerFooter({
    super.key,
    required this.answer,
    required this.onStartTimer,
    this.localModelFamily,
    this.question,
    this.recipeNotes = const [],
  });

  /// App-authored lines from the reviewed recipe, shown when there is no
  /// model answer (never with one). Labelled "From the recipe (not AI)".
  final List<String> recipeNotes;

  /// The cook's typed question, echoed so the reply reads as a reply.

  final CoachLiteAnswer answer;
  final void Function(String label, int seconds) onStartTimer;

  /// `HybridCapabilities.local?.modelFamily`, shown on on-device chips.
  final String? localModelFamily;
  final String? question;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestion = answer.timerSuggestion;
    final status = coachLiteStatusLine(answer);
    final asked = question?.trim() ?? '';
    final notes = status == null ? const <String>[] : recipeNotes;
    if (answer.legs.isEmpty &&
        suggestion == null &&
        status == null &&
        asked.isEmpty) {
      return const SizedBox.shrink();
    }
    return ArrivalTransition(
      signature: answer.stamp,
      child: Column(
        key: const ValueKey('coach-lite-footer'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (asked.isNotEmpty)
            Text(
              'You asked: “$asked”',
              key: const ValueKey('coach-lite-question'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  key: const ValueKey('coach-lite-status'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        status,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 26),
              child: Column(
                key: const ValueKey('coach-lite-recipe-notes'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'From the recipe (not AI)',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  for (final note in notes)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('• $note'),
                    ),
                ],
              ),
            ),
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
                      'ANSWER',
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
