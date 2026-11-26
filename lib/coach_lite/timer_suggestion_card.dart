import 'package:flutter/material.dart';

import 'coach_lite.dart';

/// Shows a Coach Lite timer suggestion with the app's own "Start timer"
/// control. The model cannot start a timer: only the cook's tap calls
/// [onStart], once, with the clamped label and seconds.
class TimerSuggestionCard extends StatefulWidget {
  const TimerSuggestionCard({
    super.key,
    required this.suggestion,
    required this.onStart,
  });

  final CoachLiteTimerSuggestion suggestion;
  final void Function(String label, int seconds) onStart;

  @override
  State<TimerSuggestionCard> createState() => _TimerSuggestionCardState();
}

class _TimerSuggestionCardState extends State<TimerSuggestionCard> {
  bool _started = false;

  @override
  void didUpdateWidget(TimerSuggestionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.suggestion, widget.suggestion)) _started = false;
  }

  static String duration(int seconds) {
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    if (rest == 0) return '$minutes min';
    return '$minutes min ${rest.toString().padLeft(2, '0')} s';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.timer_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.label, style: theme.textTheme.titleMedium),
                  Text(
                    'Suggested timer · ${duration(s.seconds)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (s.capped)
                    Text(
                      coachLiteTimerCapNote,
                      key: const ValueKey('timer-cap-note'),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              icon: Icon(_started ? Icons.check : Icons.play_arrow),
              label: Text(_started ? 'Timer started' : 'Start timer'),
              onPressed: _started
                  ? null
                  : () {
                      setState(() => _started = true);
                      widget.onStart(s.label, s.seconds);
                    },
            ),
          ],
        ),
      ),
    );
  }
}
