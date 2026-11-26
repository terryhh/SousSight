import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'native_live_media.dart';

/// [NativeLiveMedia] backed by the `camera` and `record` plugins and the
/// app's own PCM player channel (MainActivity.kt / AppDelegate.swift).
NativeLiveMedia createNativeLiveMedia() => NativeLiveMedia(
  camera: PluginNativeCamera.new,
  microphone: PluginNativeMicrophone.new,
  player: MethodChannelPcmPlayer.new,
);

/// Microphone settings for the Live coach: PCM16 16 kHz mono with the
/// platform's echo cancellation, so the coach's own voice from the speaker is
/// not sent back as the cook speaking.
const kNativeMicrophoneConfig = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: kNativeMicSampleRate,
  numChannels: 1,
  echoCancel: true,
  noiseSuppress: true,
  androidConfig: AndroidRecordConfig(
    audioSource: AndroidAudioSource.voiceCommunication,
    // No Bluetooth SCO: it would need BLUETOOTH_CONNECT and reroute the call
    // audio; the kitchen speaker and built-in mic are the supported setup.
    manageBluetooth: false,
  ),
  iosConfig: IosRecordConfig(
    // Must match the player's category options in AppDelegate.swift, so
    // starting playback does not reconfigure the running recorder.
    categoryOptions: [
      IosAudioCategoryOption.defaultToSpeaker,
      IosAudioCategoryOption.allowBluetoothA2DP,
    ],
  ),
);

/// The back camera through the `camera` plugin, with audio disabled so the
/// camera never asks for or opens the microphone.
class PluginNativeCamera implements NativeCamera {
  CameraController? _controller;
  bool _closed = false;
  Future<void>? _opening;

  /// The controller [open] builds. Audio is off: camera-only capture must
  /// not trigger a microphone prompt (iOS asks for it when audio is on).
  @visibleForTesting
  static CameraController controllerFor(CameraDescription description) =>
      CameraController(
        description,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );

  @override
  Future<void> open() => _opening ??= _open();

  Future<void> _open() async {
    final cameras = await availableCameras();
    if (_closed) return;
    if (cameras.isEmpty) {
      throw const NativeLiveMediaException('No camera found on this device.');
    }
    final description = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = controllerFor(description);
    _controller = controller;
    try {
      // Requests the camera permission on first use (both platforms).
      await controller.initialize();
    } catch (_) {
      if (_closed) return;
      rethrow;
    }
    if (_closed) await _dispose(controller);
  }

  @override
  Future<void> startFrames(
    void Function(NativeCameraFrame frame) onFrame,
    void Function(Object error) onError,
  ) async {
    final controller = _controller;
    if (_closed || controller == null) return;
    var reported = false;
    controller.addListener(() {
      final value = controller.value;
      if (!reported && value.hasError) {
        reported = true;
        onError(value.errorDescription ?? 'camera error');
      }
    });
    await controller.startImageStream((image) {
      if (_closed) return;
      final frame = nativeFrameFrom(
        image,
        sensorOrientation: controller.description.sensorOrientation,
        lensDirection: controller.description.lensDirection,
        deviceOrientation: controller.value.deviceOrientation,
        platform: defaultTargetPlatform,
      );
      if (frame != null) onFrame(frame);
    });
    if (_closed) await _dispose(controller);
  }

  @override
  Future<void> close() async {
    _closed = true;
    final controller = _controller;
    _controller = null;
    if (controller != null) await _dispose(controller);
  }

  static Future<void> _dispose(CameraController controller) async {
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }
}

/// Converts a plugin image, or null for a format the encoder cannot read.
@visibleForTesting
NativeCameraFrame? nativeFrameFrom(
  CameraImage image, {
  required int sensorOrientation,
  required CameraLensDirection lensDirection,
  required DeviceOrientation deviceOrientation,
  required TargetPlatform platform,
}) {
  final format = switch (image.format.group) {
    ImageFormatGroup.yuv420 => NativePixelFormat.yuv420,
    ImageFormatGroup.nv21 => NativePixelFormat.nv21,
    ImageFormatGroup.bgra8888 => NativePixelFormat.bgra8888,
    _ => null,
  };
  if (format == null) return null;
  return NativeCameraFrame(
    format: format,
    width: image.width,
    height: image.height,
    planes: [
      for (final plane in image.planes)
        NativePlane(
          bytes: plane.bytes,
          bytesPerRow: plane.bytesPerRow,
          bytesPerPixel: plane.bytesPerPixel,
        ),
    ],
    rotationDegrees: nativeFrameRotation(
      platform: platform,
      sensorOrientation: sensorOrientation,
      lensDirection: lensDirection,
      deviceOrientation: deviceOrientation,
    ),
  );
}

/// Clockwise rotation that makes a streamed frame upright.
///
/// Android image analysis frames arrive in sensor orientation, so they are
/// rotated by the sensor angle relative to how the cook holds the phone. The
/// iOS plugin already rotates its video connection to the device orientation.
@visibleForTesting
int nativeFrameRotation({
  required TargetPlatform platform,
  required int sensorOrientation,
  required CameraLensDirection lensDirection,
  required DeviceOrientation deviceOrientation,
}) {
  if (platform != TargetPlatform.android) return 0;
  final device = switch (deviceOrientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  final rotation = lensDirection == CameraLensDirection.front
      ? sensorOrientation + device
      : sensorOrientation - device;
  return ((rotation % 360) + 360) % 360;
}

/// The microphone through the `record` plugin.
class PluginNativeMicrophone implements NativeMicrophone {
  PluginNativeMicrophone() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  bool _closed = false;
  Future<Stream<Uint8List>>? _starting;

  /// Requests RECORD_AUDIO (Android) or microphone access (iOS) on first use.
  @override
  Future<bool> requestPermission() =>
      _closed ? Future.value(false) : _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() {
    if (_closed) return Future.value(const Stream.empty());
    return _starting ??= _recorder.startStream(kNativeMicrophoneConfig);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Let an in-flight start settle so the recorder it opens is stopped too.
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await _recorder.dispose();
    } catch (_) {}
  }
}

/// Streaming PCM16 playback through the app's `dev.soussight/pcm_player`
/// channel: AudioTrack on Android, AVAudioEngine on iOS.
///
/// Each [open] gets a token from the native side; calls carrying an older
/// token are ignored there, so a closed session cannot stop a newer one.
class MethodChannelPcmPlayer implements NativePcmPlayer {
  MethodChannelPcmPlayer({MethodChannel? channel})
    : _channel = channel ?? kPcmPlayerChannel;

  static const kPcmPlayerChannel = MethodChannel('dev.soussight/pcm_player');

  final MethodChannel _channel;
  int? _token;
  bool _closed = false;

  @override
  Future<void> open({required int sampleRate}) async {
    final token = await _channel.invokeMethod<int>('open', {
      'sampleRate': sampleRate,
    });
    if (token == null) {
      throw PlatformException(code: 'pcm_player', message: 'No player token');
    }
    _token = token;
    // Closed while opening: release what the native side just opened.
    if (_closed) await _send('close');
  }

  @override
  void feed(Uint8List pcm) {
    if (_closed || _token == null || pcm.isEmpty) return;
    unawaited(_send('feed', {'pcm': pcm}));
  }

  @override
  void interrupt() {
    if (_closed || _token == null) return;
    unawaited(_send('interrupt'));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_token != null) await _send('close');
  }

  Future<void> _send(
    String method, [
    Map<String, Object?> extra = const {},
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, {'token': _token, ...extra});
    } catch (_) {
      // Playback is best effort; a dropped chunk must not end the session.
    }
  }
}
