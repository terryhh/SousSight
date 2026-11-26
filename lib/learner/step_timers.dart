// Step timer IDs (SS-100). Shared by the coordinator, which starts and
// dismisses step timers, and the dinner estimate, which reads them.

/// Whether [timerId] is [stepId]'s step timer. Step timers are named
/// `step-<stepId>` (a restored timer) or `step-<stepId>-<millis>-<seq>` (see
/// `CookingCoordinator.startStepTimer`); the step ID must match exactly, so
/// `step-prep-sauce-…` never counts as step `prep`'s timer.
bool isStepTimerFor(String timerId, String stepId) {
  final prefix = 'step-$stepId';
  if (timerId == prefix) return true;
  if (!timerId.startsWith('$prefix-')) return false;
  return RegExp(r'^\d+-\d+$').hasMatch(timerId.substring(prefix.length + 1));
}
