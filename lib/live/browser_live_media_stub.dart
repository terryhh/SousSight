import 'dart:typed_data';

import 'live_types.dart';

LiveMedia createBrowserLiveMedia() => _UnsupportedMedia();

class _UnsupportedMedia implements LiveMedia {
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Future<void> start() async => throw UnsupportedError(
    'The cooking camera currently requires a browser.',
  );
  @override
  Future<void> stop() async {}
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void playAudio(Uint8List pcm24khz) {}
  @override
  void interruptPlayback() {}
}
