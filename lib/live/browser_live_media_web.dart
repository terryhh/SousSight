import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'live_types.dart';

@JS('globalThis.soussightLive')
external JSAny? get _bridge;

@JS('soussightLive.create')
external _MediaHandle _createMedia(
  JSFunction audio,
  JSFunction frame,
  JSFunction error,
);

extension type _MediaHandle(JSObject _) implements JSObject {
  external JSPromise<JSAny?> start();
  external JSPromise<JSAny?> startCameraOnly();
  external void stop();
  external void mute(JSBoolean value);
  external void play(JSUint8Array value);
  external void interrupt();
}

LiveMedia createBrowserLiveMedia() => BrowserLiveMedia();

/// Thin bridge to browser media primitives. No third-party CDN or recording
/// service is involved. Images/audio are ephemeral, kept only in this session.
class BrowserLiveMedia implements LiveMedia {
  final _microphone = StreamController<Uint8List>.broadcast();
  final _frames = StreamController<Uint8List>.broadcast();
  final _timedFrames = StreamController<CapturedFrame>.broadcast();
  final _errors = StreamController<String>.broadcast();
  _MediaHandle? _handle;
  int _epoch = 0;

  @override
  Stream<Uint8List> get microphone => _microphone.stream;
  @override
  Stream<Uint8List> get frames => _frames.stream;
  @override
  Stream<CapturedFrame> get timedFrames => _timedFrames.stream;
  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> start() => _begin(cameraOnly: false);

  @override
  Future<void> startCameraOnly() => _begin(cameraOnly: true);

  Future<void> _begin({required bool cameraOnly}) async {
    if (_bridge == null) {
      throw StateError('Live media bridge is missing from index.html.');
    }
    final epoch = ++_epoch;
    final handle = _createMedia(
      ((JSUint8Array data) {
        if (_epoch == epoch && !cameraOnly) _microphone.add(data.toDart);
      }).toJS,
      ((JSUint8Array data, JSNumber capturedAt) {
        if (_epoch != epoch) return;
        final bytes = data.toDart;
        // Camera-only frames never reach the Live coach's stream.
        if (!cameraOnly) _frames.add(bytes);
        _timedFrames.add(
          CapturedFrame(
            bytes: bytes,
            capturedAt: DateTime.fromMillisecondsSinceEpoch(
              capturedAt.toDartDouble.round(),
            ),
          ),
        );
      }).toJS,
      ((JSString error) {
        if (_epoch == epoch) _errors.add(error.toDart);
      }).toJS,
    );
    _handle = handle;
    await (cameraOnly ? handle.startCameraOnly() : handle.start()).toDart;
    if (_epoch != epoch) handle.stop();
  }

  @override
  Future<void> stop() async {
    ++_epoch;
    final handle = _handle;
    _handle = null;
    handle?.stop();
  }

  @override
  void setMicrophoneMuted(bool muted) => _handle?.mute(muted.toJS);
  @override
  void playAudio(Uint8List pcm24khz) => _handle?.play(pcm24khz.toJS);
  @override
  void interruptPlayback() => _handle?.interrupt();
}
