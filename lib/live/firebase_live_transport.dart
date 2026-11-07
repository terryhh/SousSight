import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';

import 'live_tools.dart';
import 'live_types.dart';

/// Native Firebase AI Logic adapter. On web use EphemeralGeminiLiveTransport:
/// firebase_ai 5.1's browser WebSocket cannot attach App Check headers.
class FirebaseLiveTransport implements LiveTransport {
  FirebaseLiveTransport({this.model = kLiveModel});
  final String model;
  final _events = StreamController<LiveEvent>.broadcast();
  LiveSession? _session;
  StreamSubscription<LiveServerResponse>? _subscription;
  String? _resumeHandle;
  bool _closed = false;
  bool _resuming = false;
  Completer<void>? _setup;

  @override
  Stream<LiveEvent> get events => _events.stream;

  @override
  Future<void> connect({required String systemInstruction}) async {
    final liveModel = FirebaseAI.googleAI().liveGenerativeModel(
      model: model,
      systemInstruction: Content.system(systemInstruction),
      liveGenerationConfig: LiveGenerationConfig(
        responseModalities: [ResponseModalities.audio],
        inputAudioTranscription: AudioTranscriptionConfig(),
        outputAudioTranscription: AudioTranscriptionConfig(),
        contextWindowCompression: ContextWindowCompressionConfig(
          slidingWindow: SlidingWindow(),
        ),
      ),
      tools: [Tool.functionDeclarations(cookingLiveFunctions())],
    );
    final session = await liveModel.connect(
      sessionResumption: SessionResumptionConfig(),
    );
    if (_closed) {
      await session.close();
      return;
    }
    _session = session;
    _setup = Completer<void>();
    _listen(session);
    await _setup!.future.timeout(const Duration(seconds: 20));
  }

  void _listen(LiveSession session) {
    // receive() in 5.1 is persistent. Do not break on turnComplete; doing so
    // drops all subsequent conversation turns and function calls.
    _subscription = session.receive().listen(
      (response) {
        if (_closed) return;
        if (_setup?.isCompleted == false) _setup!.complete();
        switch (response.message) {
          case LiveServerContent(
            :final modelTurn,
            :final turnComplete,
            :final interrupted,
            :final inputTranscription,
            :final outputTranscription,
          ):
            if (interrupted == true) _events.add(const LiveInterrupted());
            for (final part in modelTurn?.parts ?? <Part>[]) {
              if (part is InlineDataPart &&
                  part.mimeType.startsWith('audio/pcm')) {
                _events.add(LiveAudio(part.bytes));
              }
              if (part is TextPart && outputTranscription == null) {
                _events.add(LiveTranscript(part.text, isUser: false));
              }
            }
            if (inputTranscription?.text case final text?) {
              _events.add(
                LiveTranscript(
                  text,
                  isUser: true,
                  finished: inputTranscription?.finished == true,
                ),
              );
            }
            if (outputTranscription?.text case final text?) {
              _events.add(
                LiveTranscript(
                  text,
                  isUser: false,
                  finished: outputTranscription?.finished == true,
                ),
              );
            }
            if (turnComplete == true) _events.add(const LiveTurnComplete());
          case LiveServerToolCall(:final functionCalls):
            for (final call in functionCalls ?? <FunctionCall>[]) {
              _events.add(
                LiveToolCall(
                  name: call.name,
                  arguments: call.args,
                  id: call.id,
                ),
              );
            }
          case LiveServerToolCallCancellation(:final functionIds):
            _events.add(LiveToolsCancelled(functionIds ?? []));
          case SessionResumptionUpdate(:final newHandle, :final resumable):
            if (resumable == true && newHandle != null) {
              _resumeHandle = newHandle;
            }
            if (resumable == false) _resumeHandle = null;
          case GoingAwayNotice():
            unawaited(_resume());
          default:
            break;
        }
      },
      onError: (Object error) {
        if (_setup?.isCompleted == false) {
          _setup!.completeError(StateError('Live setup failed.'));
        }
        if (!_closed) _events.addError(StateError('Live connection failed.'));
      },
      onDone: () {
        if (!_closed && !_resuming) {
          _events.addError(StateError('Live connection ended.'));
        }
      },
    );
  }

  Future<void> _resume() async {
    if (_resuming || _closed) return;
    final handle = _resumeHandle;
    final session = _session;
    if (handle == null || session == null) {
      _events.addError(
        StateError('Live session expired; reconnect to continue.'),
      );
      return;
    }
    _resuming = true;
    _events.add(
      const LiveConnectionNotice(
        'Reconnecting live session…',
        reconnecting: true,
      ),
    );
    try {
      await session.resumeSession(
        sessionResumption: SessionResumptionConfig.resume(handle),
      );
      if (!_closed) {
        _events.add(const LiveConnectionNotice('Live session resumed.'));
      }
    } catch (_) {
      if (!_closed) {
        _events.addError(StateError('Could not resume live session.'));
      }
    } finally {
      _resuming = false;
    }
  }

  @override
  Future<void> sendAudio(Uint8List pcm16khz) async {
    if (!_closed && !_resuming) {
      await _session?.sendAudioRealtime(
        InlineDataPart('audio/pcm;rate=16000', pcm16khz),
      );
    }
  }

  @override
  Future<void> sendVideo(Uint8List jpeg) async {
    if (!_closed && !_resuming) {
      await _session?.sendVideoRealtime(InlineDataPart('image/jpeg', jpeg));
    }
  }

  @override
  Future<void> sendText(String text) async {
    if (!_closed && !_resuming) {
      await _session?.send(input: Content.text(text), turnComplete: true);
    }
  }

  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async {
    if (!_closed) {
      await _session?.sendToolResponse([
        FunctionResponse(call.name, response, id: call.id),
      ]);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_setup?.isCompleted == false) {
      _setup!.completeError(StateError('Live session closed.'));
    }
    await _subscription?.cancel();
    await _session?.close();
    await _events.close();
  }
}
