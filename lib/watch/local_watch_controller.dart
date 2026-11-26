import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/payload_digest.dart';
import '../core/models.dart';
import '../live/live_types.dart';
import 'capture_owner.dart';
import 'watch_verdict.dart';

/// The ids a check was asked for. A result is applied only while all three
/// still match the running watch.
@immutable
class _WatchToken {
  const _WatchToken(this.watchId, this.step, this.sessionId);
  final String watchId;
  final RecipeStep step;
  final String sessionId;
  String get stepId => step.id;
}

class _Check {
  _Check(this.operation, this.token, this.frame, {required this.cloud});
  final HybridOperation operation;
  final _WatchToken token;
  final CapturedFrame frame;
  final bool cloud;
}

/// Camera-only watch for the current step's visible cue, checked on this
/// device through [HybridDispatcher] (feature `local_watch`; the policy forces
/// `onlyOnDevice`). DESIGN.md §6 SS-067.
///
/// - Single flight: a check never starts while another, or a consent prompt,
///   is open.
/// - Only a frame acquired less than [maxFrameAge] ago is used.
/// - The running [HybridOperation] is cancelled on [stop], step change,
///   session change, backgrounding, Live connect and the [watchLimit].
/// - Verdicts carry watch, step and session ids and are dropped if any differ.
/// - `unsure` asks for a better view; one frame goes to the cloud only through
///   [requestCloudCheck], with a [ConsentGrant] for that frame's digest.
///
/// It never certifies doneness or safety: copy says what the camera shows.
class LocalWatchController extends ChangeNotifier {
  LocalWatchController({
    required this.dispatcher,
    required this.capture,
    this.consentGate,
    this.privacy,
    DateTime Function()? now,
    this.checkInterval = const Duration(seconds: 5),
    this.maxFrameAge = const Duration(seconds: 2),
    this.watchLimit = const Duration(minutes: 3),
    this.requestTimeout = const Duration(seconds: 15),
  }) : _now = now ?? DateTime.now;

  final HybridDispatcher dispatcher;
  final CaptureOwner capture;

  /// Null hides the cloud check entirely.
  final ConsentGate? consentGate;
  final PrivacySettings? privacy;
  final DateTime Function() _now;
  final Duration checkInterval;
  final Duration maxFrameAge;
  final Duration watchLimit;
  final Duration requestTimeout;

  _WatchToken? _token;
  _Check? _inFlight;
  CapturedFrame? _latest;
  CapturedFrame? _consentFrame;
  StreamSubscription<CapturedFrame>? _frames;
  StreamSubscription<String>? _errors;
  Timer? _ticker;
  Timer? _limit;
  int _sequence = 0;
  bool _checkedOnce = false;
  bool _disposed = false;

  /// The latest verdict that matched the running (or just finished) watch.
  WatchVerdict? verdict;

  /// A one-off message: why the watch stopped, or why a request was refused.
  String? notice;

  /// Frames skipped because they were too old when a check was due.
  int staleFramesSkipped = 0;

  String? get watchId => _token?.watchId;
  String? get stepId => _token?.stepId;
  String? get sessionId => _token?.sessionId;
  bool get isActive => _token != null;
  bool get isChecking => _inFlight != null;
  bool get awaitingConsent => _consentFrame != null;

  /// The latest camera frame while a local watch runs, for the on-screen
  /// preview only. Cleared when the watch stops. Never sent anywhere.
  Uint8List? previewFrame;

  /// The exact frame the cook is being asked about, so the prompt can show it.
  CapturedFrame? get consentFrame => _consentFrame;

  /// The cloud check is offered only after `unsure`, with a consent gate.
  bool get canRequestCloudCheck =>
      consentGate != null &&
      isActive &&
      !isChecking &&
      !awaitingConsent &&
      verdict?.state == WatchState.unsure &&
      verdict?.watchId == watchId;

  /// The one status line a UI shows for this watch.
  String? get statusText {
    final token = _token;
    if (token == null) {
      return verdict?.state == WatchState.ready ? verdict!.message : notice;
    }
    if (awaitingConsent) {
      return 'Waiting for your OK before one photo is sent for a cloud check.';
    }
    final current = verdict;
    if (current != null && current.watchId == token.watchId) {
      return current.message;
    }
    if (isChecking) return 'Checking the photo on this device…';
    if (capture.mode != CaptureMode.localCamera) return 'Starting the camera…';
    return 'Watching on this device for: ${watchCue(token.step)}';
  }

  /// What the capture indicator says while this watch holds the camera.
  /// Never "Camera and microphone off" during a local watch.
  String? get captureLabel =>
      isActive ? 'Camera on for an on-device watch · microphone off' : null;

  /// Starts a watch for [step]. Returns the watch id, or null when it could
  /// not start ([notice] says why) or was superseded before the camera opened.
  ///
  /// [stillWanted] lets a caller abandon the start (Stop, a step change)
  /// while it awaits; it is checked before the camera opens and after.
  Future<String?> start({
    required RecipeStep step,
    required String sessionId,
    bool Function()? stillWanted,
  }) async {
    await stop();
    if (stillWanted != null && !stillWanted()) return null;
    if (watchCue(step) == null) {
      notice = 'This step has no visible cue to watch for.';
      _notify();
      return null;
    }
    final token = _WatchToken('local-watch-${++_sequence}', step, sessionId);
    _token = token;
    verdict = null;
    notice = null;
    _checkedOnce = false;
    _notify();
    CaptureLease? lease;
    try {
      lease = await capture.acquireLocalCamera();
    } catch (error) {
      if (_token == token) {
        _token = null;
        notice = 'The camera could not start, so I can\'t watch: $error';
        _notify();
      }
      return null;
    }
    if (lease == null || _token != token) return null;
    if (stillWanted != null && !stillWanted()) {
      await stop();
      return null;
    }
    _frames = capture.framesFor(lease).listen((frame) {
      if (_token != token) return;
      _latest = frame;
      // The cook sees what the watch sees. The frame stays on this device.
      previewFrame = frame.bytes;
      _notify();
      if (!_checkedOnce) unawaited(_check(token));
    });
    _errors = capture.media.errors.listen((message) {
      if (_token == token) unawaited(stop(notice: message));
    });
    _ticker = Timer.periodic(checkInterval, (_) => unawaited(_check(token)));
    _limit = Timer(watchLimit, () {
      if (_token != token) return;
      unawaited(
        stop(
          notice:
              'Watch paused after ${watchLimit.inMinutes} minutes — tap '
              'Watch my food to continue.',
        ),
      );
    });
    _notify();
    return token.watchId;
  }

  /// Runs one check now with the latest frame, if nothing else is in flight.
  Future<WatchVerdict?> checkNow() {
    final token = _token;
    return token == null ? Future.value() : _check(token);
  }

  /// Stops the watch, cancels any running check and releases the camera.
  Future<void> stop({String? notice}) async {
    final token = _token;
    _token = null;
    _ticker?.cancel();
    _limit?.cancel();
    _ticker = _limit = null;
    final frames = _frames, errors = _errors;
    _frames = _errors = null;
    _inFlight?.operation.cancel();
    _inFlight = null;
    _latest = null;
    previewFrame = null;
    _consentFrame = null;
    if (notice != null) this.notice = notice;
    if (token != null) _notify();
    // Not awaited: the subscriptions are inert once the token is cleared.
    unawaited(frames?.cancel());
    unawaited(errors?.cancel());
    if (capture.mode == CaptureMode.localCamera ||
        capture.pending == CaptureMode.localCamera) {
      await capture.release();
    }
  }

  void onStepChanged(String stepId) {
    if (_token != null && _token!.stepId != stepId) {
      unawaited(stop(notice: 'Watch stopped because the step changed.'));
    } else if (_token == null && verdict != null && verdict!.stepId != stepId) {
      _forgetFinished();
    }
  }

  void onSessionChanged(String sessionId) {
    if (_token != null && _token!.sessionId != sessionId) {
      unawaited(
        stop(notice: 'Watch stopped because the cooking session changed.'),
      );
    } else if (_token == null &&
        verdict != null &&
        verdict!.sessionId != sessionId) {
      _forgetFinished();
    }
  }

  /// A finished watch's verdict and notice describe another step or session.
  void _forgetFinished() {
    verdict = null;
    notice = null;
    _notify();
  }

  void onBackgrounded() {
    if (_token != null) {
      unawaited(
        stop(notice: 'Watch paused while the app was in the background.'),
      );
    }
  }

  /// Live is about to take the camera and microphone.
  Future<void> onLiveConnecting() async {
    if (_token != null) {
      await stop(notice: 'The Live coach is taking over the camera.');
    }
  }

  /// True only while [candidate] belongs to the running watch, step and
  /// session.
  bool isCurrent(WatchVerdict candidate) {
    final token = _token;
    return token != null &&
        candidate.watchId == token.watchId &&
        candidate.stepId == token.stepId &&
        candidate.sessionId == token.sessionId;
  }

  /// After `unsure`: asks the cook to let one exact frame go to the cloud.
  /// Sends only with a grant for that frame's digest and this session, and
  /// only if the watch is still the same and privacy still allows it when the
  /// prompt closes. A different frame needs a new grant.
  Future<WatchVerdict?> requestCloudCheck() async {
    final token = _token;
    final gate = consentGate;
    if (token == null || gate == null || isChecking || awaitingConsent) {
      return null;
    }
    if (_localOnly) {
      notice = 'Your privacy setting keeps watch photos on this device.';
      _notify();
      return null;
    }
    final frame = _freshFrame();
    if (frame == null) {
      notice = 'Hold the camera on the food for a moment, then try again.';
      _notify();
      return null;
    }
    final task = _task(token, frame, cloud: true);
    final digest = _payloadDigest(task);
    _consentFrame = frame;
    _notify();
    ConsentGrant? grant;
    try {
      grant = await gate.request(
        ConsentAsk(
          feature: kWatchCloudCheckFeature,
          kinds: const {DataKind.image, DataKind.text},
          payloadDigest: digest,
          sessionId: token.sessionId,
        ),
      );
    } finally {
      if (_token == token) _consentFrame = null;
    }
    if (_token != token) return null; // stopped or moved on during the prompt
    if (grant == null) {
      notice = 'OK — that photo stays on this device.';
      _notify();
      return null;
    }
    final ask = grant.ask;
    if (ask.feature != kWatchCloudCheckFeature ||
        ask.sessionId != token.sessionId ||
        ask.payloadDigest != digest ||
        _payloadDigest(task) != digest) {
      notice =
          'That permission was for a different photo, so nothing was sent.';
      _notify();
      return null;
    }
    return _send(token, frame, task, grant: grant);
  }

  /// The cook's "keep Watch my food on this device" setting is keyed by
  /// [kLocalWatchFeature]; the cloud-check key is honoured too. Read live.
  bool get _localOnly =>
      (privacy?.localOnly(kLocalWatchFeature) ?? false) ||
      (privacy?.localOnly(kWatchCloudCheckFeature) ?? false);

  /// The digest a consent grant names: the dispatcher's own digest of the
  /// whole task (prompt and frame), so the grant passed with the send matches
  /// and the dispatcher does not ask the cook a second time.
  String _payloadDigest(HybridTask task) => hybridPayloadDigest(task);

  /// The only call into the dispatcher.
  HybridOperation _dispatch(
    HybridTask task,
    String sessionId, {
    ConsentGrant? grant,
  }) => dispatcher.start(task, sessionId: sessionId, grant: grant);

  CapturedFrame? _freshFrame() {
    final frame = _latest;
    if (frame == null) return null;
    final age = _now().difference(frame.capturedAt);
    if (age.abs() >= maxFrameAge) return null;
    return frame;
  }

  Future<WatchVerdict?> _check(_WatchToken token) async {
    if (_token != token || isChecking || awaitingConsent) return null;
    final frame = _freshFrame();
    if (frame == null) {
      if (_latest != null) staleFramesSkipped++;
      return null;
    }
    _checkedOnce = true;
    return _send(token, frame, _task(token, frame, cloud: false));
  }

  HybridTask _task(
    _WatchToken token,
    CapturedFrame frame, {
    required bool cloud,
  }) => HybridTask(
    feature: cloud ? kWatchCloudCheckFeature : kLocalWatchFeature,
    systemInstruction: kWatchSystemInstruction,
    parts: [
      HybridText(buildWatchPrompt(token.step)),
      HybridInlineData(frame.bytes, 'image/jpeg'),
    ],
    jsonSchema: kWatchSchema,
    maxOutputTokens: 96,
    timeout: requestTimeout,
  );

  Future<WatchVerdict?> _send(
    _WatchToken token,
    CapturedFrame frame,
    HybridTask task, {
    ConsentGrant? grant,
  }) async {
    final cloud = task.feature == kWatchCloudCheckFeature;
    // Privacy is read live, immediately before an upload.
    if (cloud && _localOnly) {
      notice = 'Your privacy setting keeps watch photos on this device.';
      _notify();
      return null;
    }
    // No `validate`: a rejected on-device answer must never trigger the
    // dispatcher's cloud retry with this frame. Malformed output becomes
    // `unsure` below instead.
    final operation = _dispatch(task, token.sessionId, grant: grant);
    final check = _Check(operation, token, frame, cloud: cloud);
    _inFlight = check;
    _notify();
    DispatchResult result;
    try {
      result = await operation.result;
    } catch (_) {
      if (_inFlight == check) {
        _inFlight = null;
        notice = 'I couldn\'t check that view. I\'ll try again.';
        _notify();
      }
      return null;
    }
    if (_inFlight != check) return null; // cancelled or superseded
    _inFlight = null;
    if (!result.ok) {
      _blocked(token, result.blocked);
      return null;
    }
    final parsed = parseWatchJson(result.text!, cue: watchCue(token.step));
    final next = WatchVerdict(
      state: parsed.state,
      direction: parsed.direction,
      whatISee: parsed.whatISee,
      redacted: parsed.redacted,
      watchId: token.watchId,
      stepId: token.stepId,
      sessionId: token.sessionId,
      frameCapturedAt: frame.capturedAt,
      source: sourceOf(result.legs),
      legs: result.legs,
    );
    if (!isCurrent(next)) return null;
    verdict = next;
    notice = null;
    if (next.state == WatchState.ready) {
      // Hand the decision to the cook and free the camera.
      await stop();
    } else {
      _notify();
    }
    return next;
  }

  void _blocked(_WatchToken token, RouteReason? reason) {
    if (_token != token || reason == RouteReason.cancelled) return;
    final message = switch (reason) {
      RouteReason.modelDownloading =>
        'The on-device model is still downloading, so I can\'t watch yet.',
      RouteReason.modelNotReady =>
        'The on-device model isn\'t ready yet, so I can\'t watch.',
      RouteReason.noLocalModel || RouteReason.imageNeedsCloud =>
        'This device\'s on-device model can\'t look at photos. Connect the '
            'Live coach to watch with cloud vision.',
      RouteReason.consentDeclined => 'OK — that photo stays on this device.',
      RouteReason.localOnlySetting =>
        'Your privacy setting keeps watch photos on this device.',
      _ => 'I couldn\'t check the camera view, so the watch stopped.',
    };
    // A refused cloud check leaves the local watch running.
    if (reason == RouteReason.consentDeclined ||
        reason == RouteReason.localOnlySetting ||
        reason == RouteReason.cloudNotApproved) {
      notice = reason == RouteReason.cloudNotApproved
          ? 'Cloud checks are turned off in this build, so nothing was sent.'
          : message;
      _notify();
      return;
    }
    unawaited(stop(notice: message));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    _disposed = true;
    super.dispose();
  }
}
