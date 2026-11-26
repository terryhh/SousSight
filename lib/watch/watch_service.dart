import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'capture_owner.dart';
import 'local_watch_controller.dart';
import 'watch_verdict.dart';

/// Where a watch runs.
enum WatchRoute {
  /// Camera only; frames are checked by the on-device model.
  local,

  /// The Live coach watches through its cloud camera and microphone stream.
  live,
}

/// The outcome of [WatchService.startWatch]. [message] is cook-facing and
/// always states which route was chosen, or why none could start.
@immutable
class WatchStart {
  const WatchStart({this.route, this.watchId, required this.message});
  final WatchRoute? route;
  final String? watchId;
  final String message;
  bool get started => watchId != null;
}

/// The one coordinator-facing entry point for "Watch my food", the Live
/// `watch_cooking` tool and app lifecycle events. It picks local or Live
/// watch and says which. DESIGN.md §6 SS-067.
class WatchService extends ChangeNotifier {
  WatchService({
    required this.local,
    required this.startLiveWatch,
    required this.stopLiveWatch,
    FutureOr<bool> Function()? localVisionSupported,
    this.liveAvailable = true,
    this.simulated = false,
  }) : _localVisionSupported = localVisionSupported ?? (() => true) {
    local.addListener(_onLocal);
  }

  final LocalWatchController local;

  /// False in builds without the Live coach: messages never point to it.
  final bool liveAvailable;

  /// Practice mode: messages say the watch is pretend.
  final bool simulated;

  /// `LiveCookingController.startWatch`: returns a watch id or null.
  final String? Function(String goal) startLiveWatch;

  /// `LiveCookingController.stopWatch`.
  final void Function() stopLiveWatch;

  /// False where the local model cannot take an image (iOS, or a browser
  /// without multimodal Prompt API): the button then offers the Live watch.
  final FutureOr<bool> Function() _localVisionSupported;

  String? _liveWatchId;
  String? _message;

  /// Bumped by every start, stop and context change. A startup that awaited
  /// across a bump is abandoned and never opens the camera or a watch.
  int _epoch = 0;
  String? _startingStepId;
  String? _startingSessionId;

  void _invalidateStartup() {
    _epoch++;
    _startingStepId = _startingSessionId = null;
  }

  CaptureOwner get capture => local.capture;

  /// The route of the watch that is running now, if any.
  WatchRoute? get activeRoute => local.isActive
      ? WatchRoute.local
      : (_liveWatchId != null ? WatchRoute.live : null);

  bool get isWatching => activeRoute != null;

  /// The watch status line a UI should show, or null when there is nothing
  /// to say.
  String? get statusText => switch (activeRoute) {
    WatchRoute.local => local.statusText,
    WatchRoute.live =>
      'The Live coach is watching (cloud vision): camera and microphone are '
          'streaming to Gemini Live.',
    null => local.statusText ?? _message,
  };

  /// Replaces the capture line ("Camera and microphone off") while a local
  /// watch holds the camera. Null means: keep the existing Live label.
  String? get captureLabel => local.captureLabel;

  Future<WatchStart> startWatch({
    required RecipeStep step,
    required String sessionId,
    required bool liveActive,
  }) async {
    final epoch = ++_epoch;
    _startingStepId = step.id;
    _startingSessionId = sessionId;
    bool current() => epoch == _epoch;
    const superseded = WatchStart(
      message: 'That watch was cancelled before it started.',
    );
    final cue = watchCue(step);
    if (cue == null) {
      return _result(
        const WatchStart(message: 'This step has no visible cue to watch for.'),
      );
    }
    if (liveActive) {
      await local.stop();
      if (!current()) return superseded;
      final id = startLiveWatch(cue);
      _liveWatchId = id;
      return _result(
        WatchStart(
          route: WatchRoute.live,
          watchId: id,
          message: id == null
              ? 'The Live coach could not start a watch.'
              : 'The Live coach is watching (cloud vision). Keep the food in '
                    'view.',
        ),
      );
    }
    _liveWatchId = null;
    final supported = await _localVisionSupported();
    if (!current()) return superseded;
    if (!supported) {
      return _result(
        WatchStart(
          message: liveAvailable
              ? 'The on-device model here can\'t look at photos. Connect the '
                    'Live coach to watch with cloud vision.'
              : "This device can't look at photos on its own. Keep an eye on "
                    'the food yourself — the step says what to look for.',
        ),
      );
    }
    final id = await local.start(
      step: step,
      sessionId: sessionId,
      stillWanted: current,
    );
    if (!current()) {
      // Belt and braces: never leave a watch running that was cancelled.
      if (id != null && local.watchId == id) await local.stop();
      return superseded;
    }
    _startingStepId = _startingSessionId = null;
    return _result(
      WatchStart(
        route: WatchRoute.local,
        watchId: id,
        message: id == null
            ? (local.notice ?? 'The on-device watch could not start.')
            : simulated
            ? 'Practice watch: pretend checks of a practice camera picture. '
                  'Nothing is sent.'
            : 'Watching on this device: camera on, microphone off. Photos '
                  'are checked by the on-device model.',
      ),
    );
  }

  /// Records a watch the Live model started itself (`watch_cooking`).
  void liveWatchStarted(String watchId) {
    _invalidateStartup();
    unawaited(local.stop());
    _liveWatchId = watchId;
    _notify();
  }

  Future<void> stopWatch() async {
    _invalidateStartup();
    if (_liveWatchId != null) {
      _liveWatchId = null;
      stopLiveWatch();
    }
    await local.stop();
    _message = 'Watch paused. Start another watch when you are ready.';
    _notify();
  }

  void onStepChanged(String stepId) {
    if (_startingStepId != null && _startingStepId != stepId) {
      _invalidateStartup();
    }
    if (_message != null) {
      _message = null;
      _notify();
    }
    local.onStepChanged(stepId);
  }

  void onSessionChanged(String sessionId) {
    if (_startingSessionId != null && _startingSessionId != sessionId) {
      _invalidateStartup();
    }
    if (_message != null) {
      _message = null;
      _notify();
    }
    local.onSessionChanged(sessionId);
  }

  void onBackgrounded() {
    _invalidateStartup();
    local.onBackgrounded();
  }

  /// Call before `LiveCookingController.start`: cancels the local watch and
  /// its running check, releases the camera, and hands capture to Live.
  Future<void> onLiveConnecting() async {
    _invalidateStartup();
    await local.onLiveConnecting();
    await capture.handOffToLive();
  }

  /// Call when Live stops for any reason.
  void onLiveStopped() {
    _liveWatchId = null;
    capture.liveReleased();
    _notify();
  }

  WatchStart _result(WatchStart start) {
    // A started watch reports through [statusText]; keep only failures.
    _message = start.started ? null : start.message;
    _notify();
    return start;
  }

  void _onLocal() => _notify();

  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    local.removeListener(_onLocal);
    super.dispose();
  }
}
