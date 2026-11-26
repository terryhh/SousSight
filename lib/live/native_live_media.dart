import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'live_types.dart';
import 'native_live_media_encoder.dart';

export 'native_live_media_encoder.dart'
    show NativeCameraFrame, NativePixelFormat, NativePlane;

/// Live coach microphone format: PCM16 little-endian, 16 kHz, mono.
const kNativeMicSampleRate = 16000;

/// Live coach reply format: PCM16 little-endian, 24 kHz, mono.
const kNativePlaybackSampleRate = 24000;

/// One frame per second, like the browser capture.
const kNativeFrameInterval = Duration(seconds: 1);

/// A failure the cook can act on (permission denied, no camera). The message
/// is safe to show as is.
class NativeLiveMediaException implements Exception {
  const NativeLiveMediaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The device camera, opened for one capture session.
abstract class NativeCamera {
  /// Requests camera permission if needed and opens the back camera. Must
  /// never request microphone access.
  Future<void> open();

  /// Starts delivering raw frames. [onError] reports a camera failure after
  /// a successful start.
  Future<void> startFrames(
    void Function(NativeCameraFrame frame) onFrame,
    void Function(Object error) onError,
  );

  /// Stops frames and releases the camera. Safe to call more than once and
  /// before [open] finished.
  Future<void> close();
}

/// The device microphone, opened for one capture session.
abstract class NativeMicrophone {
  /// Requests microphone permission if needed. False when the cook declined.
  Future<bool> requestPermission();

  /// Starts PCM16 16 kHz mono capture.
  Future<Stream<Uint8List>> start();

  /// Stops capture and releases the recorder. Safe to call more than once.
  Future<void> close();
}

/// Streaming PCM16 playback of the coach's voice.
abstract class NativePcmPlayer {
  Future<void> open({required int sampleRate});

  /// Queues [pcm] after anything already queued.
  void feed(Uint8List pcm);

  /// Drops queued audio immediately and keeps the player open.
  void interrupt();

  /// Safe to call more than once.
  Future<void> close();
}

typedef NativeFrameEncoder = Future<Uint8List> Function(NativeCameraFrame);

Future<Uint8List> _encodeInBackground(NativeCameraFrame frame) =>
    Isolate.run(() => encodeNativeFrameJpeg(frame));

/// [LiveMedia] for Android and iOS: camera frames as JPEG (longest side at
/// most 768 px, one per second), microphone PCM16 16 kHz mono, and PCM16
/// 24 kHz playback with immediate interrupt.
///
/// [startCameraOnly] never creates, asks permission for, or opens the
/// microphone or the audio player. Its frames go to [timedFrames] only, never
/// to [frames], so they cannot reach the Live coach.
///
/// Frames and audio exist only in memory for the session; nothing is written
/// to disk.
class NativeLiveMedia implements LiveMedia {
  NativeLiveMedia({
    required NativeCamera Function() camera,
    required NativeMicrophone Function() microphone,
    required NativePcmPlayer Function() player,
    NativeFrameEncoder? encoder,
    DateTime Function()? clock,
    this.frameInterval = kNativeFrameInterval,
  }) : _cameraFactory = camera,
       _microphoneFactory = microphone,
       _playerFactory = player,
       _encoder = encoder ?? _encodeInBackground,
       _clock = clock ?? DateTime.now;

  final NativeCamera Function() _cameraFactory;
  final NativeMicrophone Function() _microphoneFactory;
  final NativePcmPlayer Function() _playerFactory;
  final NativeFrameEncoder _encoder;
  final DateTime Function() _clock;
  final Duration frameInterval;

  final _microphone = StreamController<Uint8List>.broadcast();
  final _frames = StreamController<Uint8List>.broadcast();
  final _timedFrames = StreamController<CapturedFrame>.broadcast();
  final _errors = StreamController<String>.broadcast();

  _Session? _session;
  bool _muted = false;

  @override
  Stream<Uint8List> get microphone => _microphone.stream;

  /// Frames for the Live coach; only while started with [start].
  @override
  Stream<Uint8List> get frames => _frames.stream;

  /// Every captured frame with its capture time, in both modes.
  @override
  Stream<CapturedFrame> get timedFrames => _timedFrames.stream;

  @override
  Stream<String> get errors => _errors.stream;

  /// Whether a capture session is open or opening.
  bool get isActive => _session != null;

  /// Whether the active session is camera-only.
  bool get isCameraOnly => _session?.cameraOnly ?? false;

  /// Camera, microphone and playback for the Live coach.
  @override
  Future<void> start() => _begin(cameraOnly: false);

  /// Camera only. No microphone permission prompt, no recorder, no player.
  @override
  Future<void> startCameraOnly() => _begin(cameraOnly: true);

  Future<void> _begin({required bool cameraOnly}) async {
    // A new start replaces whatever was running, as on the web.
    final previous = _session;
    final session = _Session(cameraOnly: cameraOnly);
    _session = session;
    // Each session starts unmuted, like a new browser capture handle; the
    // controller applies the cook's mute choice after start.
    _muted = false;
    if (previous != null) await previous.release();
    if (!_current(session)) return;

    var stage = _Stage.camera;
    try {
      final camera = _cameraFactory();
      session.camera = camera;
      await camera.open();
      if (!_current(session)) return await session.release();

      if (!cameraOnly) {
        stage = _Stage.microphone;
        final microphone = _microphoneFactory();
        session.microphone = microphone;
        final granted = await microphone.requestPermission();
        if (!_current(session)) return await session.release();
        if (!granted) {
          throw const NativeLiveMediaException(
            'Microphone permission is off. Allow it in Settings to talk to '
            'the coach, or use the camera-only check.',
          );
        }

        // The recorder starts first: on iOS it sets the shared audio session
        // (play-and-record, speaker), which the player then reuses unchanged.
        final pcm = await microphone.start();
        if (!_current(session)) return await session.release();
        session.microphoneSubscription = pcm.listen(
          (chunk) {
            if (_current(session) && !_muted) _microphone.add(chunk);
          },
          onError: (Object _) =>
              _report(session, 'The microphone stopped. Please reconnect.'),
        );

        stage = _Stage.speaker;
        final player = _playerFactory();
        session.player = player;
        await player.open(sampleRate: kNativePlaybackSampleRate);
        if (!_current(session)) return await session.release();
      }

      stage = _Stage.camera;
      await camera.startFrames(
        (frame) => _onFrame(session, frame),
        (_) => _report(session, 'The camera stopped. Please reconnect.'),
      );
      if (!_current(session)) return await session.release();
    } catch (error) {
      final stale = !_current(session);
      await session.release();
      if (identical(_session, session)) _session = null;
      // A start that was stopped or replaced meanwhile fails quietly; its
      // error is about a session nobody is waiting for.
      if (stale) return;
      if (error is NativeLiveMediaException) rethrow;
      throw NativeLiveMediaException(_describe(stage, error));
    }
  }

  void _onFrame(_Session session, NativeCameraFrame frame) {
    if (!_current(session) || session.encoding) return;
    final now = _clock();
    final last = session.lastFrameAt;
    if (last != null && now.difference(last) < frameInterval) return;
    session.lastFrameAt = now;
    session.encoding = true;
    unawaited(_encode(session, frame, now));
  }

  Future<void> _encode(
    _Session session,
    NativeCameraFrame frame,
    DateTime capturedAt,
  ) async {
    try {
      final jpeg = await _encoder(frame);
      // Stopped, replaced or switched mode while encoding: drop the frame.
      if (!_current(session)) return;
      if (!session.cameraOnly) _frames.add(jpeg);
      _timedFrames.add(CapturedFrame(bytes: jpeg, capturedAt: capturedAt));
    } catch (_) {
      // A malformed frame is dropped; the next one is tried a second later.
    } finally {
      session.encoding = false;
    }
  }

  void _report(_Session session, String message) {
    if (_current(session)) _errors.add(message);
  }

  bool _current(_Session session) =>
      identical(_session, session) && !session.released;

  @override
  Future<void> stop() async {
    final session = _session;
    _session = null;
    await session?.release();
  }

  @override
  void setMicrophoneMuted(bool muted) => _muted = muted;

  @override
  void playAudio(Uint8List pcm24khz) {
    final session = _session;
    if (session == null || session.released || pcm24khz.isEmpty) return;
    session.player?.feed(pcm24khz);
  }

  @override
  void interruptPlayback() {
    final session = _session;
    if (session == null || session.released) return;
    session.player?.interrupt();
  }

  /// Stops capture and closes the streams. The object cannot be reused.
  Future<void> dispose() async {
    await stop();
    await Future.wait([
      _microphone.close(),
      _frames.close(),
      _timedFrames.close(),
      _errors.close(),
    ]);
  }

  static String _describe(_Stage stage, Object error) {
    final text = '$error'.toLowerCase();
    final denied = text.contains('permission') || text.contains('denied');
    return switch (stage) {
      _Stage.camera when denied =>
        'Camera permission is off. Allow it in Settings to show the coach '
            'your food.',
      _Stage.camera => 'Could not start the camera on this device.',
      _Stage.microphone when denied =>
        'Microphone permission is off. Allow it in Settings to talk to the '
            'coach, or use the camera-only check.',
      _Stage.microphone => 'Could not start the microphone on this device.',
      _Stage.speaker => 'Could not start audio playback on this device.',
    };
  }
}

enum _Stage { camera, microphone, speaker }

/// Resources acquired for one start. [release] is idempotent and also frees
/// anything attached after a stop, so a slow start never leaks a camera or
/// microphone.
class _Session {
  _Session({required this.cameraOnly});

  final bool cameraOnly;
  NativeCamera? camera;
  NativeMicrophone? microphone;
  NativePcmPlayer? player;
  StreamSubscription<Uint8List>? microphoneSubscription;
  DateTime? lastFrameAt;
  bool encoding = false;
  bool released = false;

  Future<void> release() async {
    released = true;
    final subscription = microphoneSubscription;
    final microphone = this.microphone;
    final player = this.player;
    final camera = this.camera;
    microphoneSubscription = null;
    this.microphone = null;
    this.player = null;
    this.camera = null;
    await Future.wait([
      if (subscription != null) _quietly(subscription.cancel),
      if (microphone != null) _quietly(microphone.close),
      if (player != null) _quietly(player.close),
      if (camera != null) _quietly(camera.close),
    ]);
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Shutdown is best effort; one failing device must not keep another open.
    }
  }
}
