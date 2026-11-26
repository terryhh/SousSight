import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Delivers one announcement to the platform's screen reader.
typedef CookAnnouncementSender = Future<void> Function(String message);

/// Tells a screen reader when the cook screen changes under the cook's hands
/// (WCAG 4.1.3 Status Messages): a new step, or a timer that just started.
///
/// The cooking coordinator owns one announcer. It calls [stepShown] when the
/// step on screen changes (not on the first render of a session) and
/// [timerStarted] when the cook starts a timer that did not exist before. A
/// timer restored from a saved session is not "started" and is not reported.
///
/// Each step and each timer is announced at most once per session, however
/// often the workspace rebuilds or the same call repeats. Calls made in the
/// same event-loop turn go out as a single polite announcement, so a step
/// change and a timer start do not cut each other off; when the step changes
/// twice before delivery, only the step now on screen is read. A different
/// session, [reset] or [dispose] drops anything not yet delivered.
class CookAnnouncer {
  CookAnnouncer({CookAnnouncementSender? send})
    : _send = send ?? _sendToImplicitView;

  final CookAnnouncementSender _send;
  String? _sessionId;
  String? _stepId;
  final Set<String> _timerIds = {};
  String? _pendingStep;
  final List<String> _pendingTimers = [];
  Timer? _delivery;
  bool _disposed = false;

  /// The step now on screen is [stepId], number [number] of [count].
  void stepShown({
    required String sessionId,
    required String stepId,
    required int number,
    required int count,
    required String title,
    String instruction = '',
  }) {
    if (_disposed || !_bind(sessionId) || stepId == _stepId) return;
    _stepId = stepId;
    _pendingStep = [
      'Step $number of $count.',
      _sentence(title),
      _sentence(instruction),
    ].where((part) => part.isNotEmpty).join(' ');
    _schedule();
  }

  /// The cook just started timer [timerId] for [seconds].
  void timerStarted({
    required String sessionId,
    required String timerId,
    required String label,
    required int seconds,
  }) {
    if (_disposed || !_bind(sessionId) || !_timerIds.add(timerId)) return;
    final name = _sentence(label);
    _pendingTimers.add(
      name.isEmpty
          ? '${timerLength(seconds)} timer started.'
          : '${timerLength(seconds)} timer started: $name',
    );
    _schedule();
  }

  /// Forgets the session: nothing pending is read, and the next step or timer
  /// counts as new. Call it when the cook leaves or starts a new cook.
  void reset() {
    _delivery?.cancel();
    _delivery = null;
    _sessionId = null;
    _stepId = null;
    _timerIds.clear();
    _pendingStep = null;
    _pendingTimers.clear();
  }

  void dispose() {
    reset();
    _disposed = true;
  }

  /// Binds to [sessionId]; a new session discards the old one's state.
  bool _bind(String sessionId) {
    if (sessionId.isEmpty) return false;
    if (_sessionId != sessionId) {
      reset();
      _sessionId = sessionId;
    }
    return true;
  }

  void _schedule() => _delivery ??= Timer(Duration.zero, _deliver);

  void _deliver() {
    _delivery = null;
    final message = [?_pendingStep, ..._pendingTimers].join(' ');
    _pendingStep = null;
    _pendingTimers.clear();
    if (_disposed || message.isEmpty) return;
    // An announcement that fails to send is not retried: by the next change
    // it would be stale, and the screen still shows the same text.
    unawaited(_send(message).catchError((Object _) {}));
  }

  static Future<void> _sendToImplicitView(String message) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return Future<void>.value();
    return SemanticsService.sendAnnouncement(view, message, TextDirection.ltr);
  }
}

/// "5-minute" or "90-second", matching the cook screen's timer button.
String timerLength(int seconds) => seconds > 0 && seconds % 60 == 0
    ? '${seconds ~/ 60}-minute'
    : '$seconds-second';

String _sentence(String text) {
  final trimmed = text.trim().replaceAll(RegExp(r'\s*\n+\s*'), ' ');
  if (trimmed.isEmpty) return '';
  return RegExp(r'[.!?…]$').hasMatch(trimmed) ? trimmed : '$trimmed.';
}
