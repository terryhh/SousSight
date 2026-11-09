import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';

import '../core/analytics.dart';

/// Google Analytics 4 through Firebase. On web, the first touch of
/// [FirebaseAnalytics.instance] loads gtag with the project's measurementId,
/// which records page_view, session_start and first_visit automatically.
class FirebaseAnalyticsSink extends Analytics {
  FirebaseAnalyticsSink([FirebaseAnalytics? analytics])
    : _analytics = analytics ?? FirebaseAnalytics.instance;
  final FirebaseAnalytics _analytics;

  /// The web SDK initializes lazily on first call; this call loads gtag so
  /// page_view is recorded on every app load, before any custom event.
  void start() => _guard(() => _analytics.setAnalyticsCollectionEnabled(true));

  void _guard(Future<void> Function() call) {
    try {
      unawaited(call().catchError((Object _) {}));
    } catch (_) {
      // Blocked or unavailable analytics must never break the app.
    }
  }

  @override
  void log(String name, [Map<String, Object> parameters = const {}]) => _guard(
    () => _analytics.logEvent(
      name: name,
      parameters: parameters.isEmpty ? null : parameters,
    ),
  );
}
