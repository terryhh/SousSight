// Product analytics. Usage counts only: event names plus small enum-like
// parameters (recipe ids, step numbers, kinds). Never send free text, recipe
// questions, pantry contents, names, or phone numbers.
//
// The real sink is Google Analytics via Firebase (lib/data/firebase_analytics_sink.dart);
// fake/demo builds and tests use [NoopAnalytics] or [RecordingAnalytics].

abstract class Analytics {
  const Analytics();

  /// Fire-and-forget. Implementations must never throw: analytics failures
  /// (ad blockers, offline) cannot affect cooking.
  void log(String name, [Map<String, Object> parameters = const {}]);
}

class NoopAnalytics extends Analytics {
  const NoopAnalytics();
  @override
  void log(String name, [Map<String, Object> parameters = const {}]) {}
}

/// Test double that keeps every event in order.
class RecordingAnalytics extends Analytics {
  final List<AnalyticsEvent> events = [];
  List<String> get names => [for (final e in events) e.name];
  @override
  void log(String name, [Map<String, Object> parameters = const {}]) =>
      events.add(AnalyticsEvent(name, Map.unmodifiable(parameters)));
}

class AnalyticsEvent {
  const AnalyticsEvent(this.name, this.parameters);
  final String name;
  final Map<String, Object> parameters;
  @override
  String toString() => 'AnalyticsEvent($name, $parameters)';
}

/// Event names in one place so the GA reports stay consistent.
abstract final class AnalyticsEvents {
  static const recipeChosen = 'recipe_chosen';
  static const cookSessionStarted = 'cook_session_started';
  static const liveCoachConnected = 'live_coach_connected';
  static const stepCompleted = 'step_completed';
  static const mealCompleted = 'meal_completed';
  static const timerStarted = 'timer_started';
  static const watchStarted = 'watch_started';
  static const researchAsked = 'research_asked';
  static const householdMessageSent = 'household_message_sent';
}
