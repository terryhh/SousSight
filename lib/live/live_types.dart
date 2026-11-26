import 'dart:typed_data';

/// Transport-independent events keep the app and tests off SDK internals.
sealed class LiveEvent {
  const LiveEvent();
}

class LiveAudio extends LiveEvent {
  const LiveAudio(this.pcm);
  final Uint8List pcm;
}

class LiveTranscript extends LiveEvent {
  const LiveTranscript(
    this.text, {
    required this.isUser,
    this.finished = false,
  });
  final String text;
  final bool isUser;
  final bool finished;
}

class LiveTurnComplete extends LiveEvent {
  const LiveTurnComplete();
}

class LiveInterrupted extends LiveEvent {
  const LiveInterrupted();
}

class LiveToolCall extends LiveEvent {
  const LiveToolCall({required this.name, required this.arguments, this.id});
  final String name;
  final String? id;
  final Map<String, Object?> arguments;
}

class LiveToolsCancelled extends LiveEvent {
  const LiveToolsCancelled(this.ids);
  final List<String> ids;
}

class LiveConnectionNotice extends LiveEvent {
  const LiveConnectionNotice(this.message, {this.reconnecting = false});
  final String message;
  final bool reconnecting;
}

abstract class LiveTransport {
  Stream<LiveEvent> get events;
  Future<void> connect({required String systemInstruction});
  Future<void> sendAudio(Uint8List pcm16khz);
  Future<void> sendVideo(Uint8List jpeg);
  Future<void> sendText(String text);
  Future<void> respondToTool(LiveToolCall call, Map<String, Object?> response);
  Future<void> close();
}

typedef LiveTransportFactory = LiveTransport Function();
typedef LiveToolHandler = Future<Map<String, Object?>> Function(
  LiveToolCall call,
);

/// One JPEG camera frame, stamped when the browser or device acquired it, not
/// when Dart received it. Consumers judge freshness from [capturedAt].
class CapturedFrame {
  const CapturedFrame({required this.bytes, required this.capturedAt});
  final Uint8List bytes;
  final DateTime capturedAt;
}

abstract class LiveMedia {
  Stream<Uint8List> get microphone;

  /// Frames for the Live coach. Only emitted while capture was started with
  /// [start] (camera and microphone); never during [startCameraOnly].
  Stream<Uint8List> get frames;

  /// Every captured frame with its acquisition time, in both modes.
  Stream<CapturedFrame> get timedFrames;
  Stream<String> get errors;

  /// Camera and microphone, for the Live coach.
  Future<void> start();

  /// Camera only: no microphone request and no audio graph, so it works when
  /// the microphone is denied or absent. Frames arrive on [timedFrames] only.
  Future<void> startCameraOnly();
  Future<void> stop();
  void setMicrophoneMuted(bool muted);
  void playAudio(Uint8List pcm24khz);
  void interruptPlayback();
}
