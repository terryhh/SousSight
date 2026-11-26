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
    const accent = Color(0xffbf5b32);
    const foreground = Color(0xff4a2410);
    return DecoratedBox(
      key: const ValueKey('timer-suggestion'),
      decoration: BoxDecoration(
        color: const Color(0xfffff3e6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(
                        Icons.timer_outlined,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'Suggested timer · ${duration(s.seconds)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('timer-suggestion-start'),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                minimumSize: const Size.fromHeight(52),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: Icon(_started ? Icons.check : Icons.play_arrow),
              label: Text(_started ? 'Timer started' : 'Start timer'),
              onPressed: _started
                  ? null
                  : () {
                      setState(() => _started = true);
                      widget.onStart(s.label, s.seconds);
                    },
            ),
            const SizedBox(height: 6),
            Text(
              'The coach only suggests it. Nothing starts until you tap.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}
