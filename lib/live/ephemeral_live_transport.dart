import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'live_tools.dart';
import 'live_types.dart';

/// Metadata returned by POST /api/live-token. Validate before opening a socket;
/// the server is responsible for model selection and short expiration windows.
class LiveEphemeralToken {
  const LiveEphemeralToken({
    required this.token,
    this.model = 'gemini-3.8-live',
    this.apiVersion = 'v1beta',
  });
  final String token;
  final String model;
  final String apiVersion;

  factory LiveEphemeralToken.fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    final model = json['model'];
    final apiVersion = json['apiVersion'];
    if (token is! String ||
        !token.startsWith('auth_tokens/') ||
        model is! String ||
        !RegExp(r'^gemini-[a-zA-Z0-9.-]+$').hasMatch(model) ||
        !['v1alpha', 'v1beta'].contains(apiVersion)) {
      throw const FormatException('Invalid Live token response.');
    }
    return LiveEphemeralToken(
      token: token,
      model: model,
      apiVersion: apiVersion as String,
    );
  }
}

/// Browser-safe Gemini Live connection. The token provider calls our protected
/// backend; a long-lived Gemini API key must never be passed to this class.
///
/// Uses the server-selected API version and model. Current Google Live docs
/// use Gemini 3.8 Live with v1beta ephemeral tokens; access_token is mandatory.
class EphemeralGeminiLiveTransport implements LiveTransport {
  EphemeralGeminiLiveTransport({
    required this.tokenProvider,
    WebSocketChannel Function(Uri)? socketFactory,
  }) : _socketFactory = socketFactory ?? WebSocketChannel.connect;

  final Future<LiveEphemeralToken> Function() tokenProvider;
  final WebSocketChannel Function(Uri) _socketFactory;
  final _events = StreamController<LiveEvent>.broadcast();
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _setup;
  LiveEphemeralToken? _token;
  String? _resumeHandle;
  String _instruction = '';
  bool _closed = false;
  bool _ready = false;
  bool _resuming = false;
  Completer<void>? _resumeFinished;
  int _connectionEpoch = 0;

  @override
  Stream<LiveEvent> get events => _events.stream;

  @override
  Future<void> connect({required String systemInstruction}) async {
    _instruction = systemInstruction;
    final token = await tokenProvider();
    if (_closed) return;
    if (!token.token.startsWith('auth_tokens/') || token.token.length < 20) {
      throw StateError('The Live service did not return an ephemeral token.');
    }
    _token = token;
    await _openSocket();
  }

  Future<void> _openSocket({String? resumeHandle}) async {
    final epoch = ++_connectionEpoch;
    _ready = false;
    final socket = _socketFactory(
      Uri(
        scheme: 'wss',
        host: 'generativelanguage.googleapis.com',
        path:
            '/ws/google.ai.generativelanguage.${_token!.apiVersion}.GenerativeService.BidiGenerateContentConstrained',
        queryParameters: {'access_token': _token!.token},
      ),
    );
    _socket = socket;
    final setup = Completer<void>();
    _setup = setup;
    // Keep early socket rejection handled while we are still awaiting ready.
    unawaited(setup.future.catchError((Object _) {}));
    // Attach before awaiting ready, so an immediate server rejection is read.
    _subscription = socket.stream.listen(
      (raw) {
        if (_closed || epoch != _connectionEpoch) return;
        try {
          final data = jsonDecode(
            raw is String ? raw : utf8.decode(raw as List<int>),
          );
          if (data is! Map<String, dynamic>) {
            throw const FormatException('Invalid live event.');
          }
          _receive(data);
        } catch (_) {
          _connectionError('The live service returned an unreadable message.');
        }
      },
      onError: (Object _) {
        if (!_closed && epoch == _connectionEpoch) {
          _connectionError('Live WebSocket failed.');
        }
      },
      onDone: () {
        if (_closed || epoch != _connectionEpoch) return;
        if (!setup.isCompleted) {
          setup.completeError(
            StateError('Live service closed before setup completed.'),
          );
        } else if (!_resuming && _resumeHandle != null) {
          unawaited(_resume());
        } else if (!_resuming) {
          _events.addError(StateError('Live connection ended.'));
        }
      },
    );
    try {
      await socket.ready;
      if (_closed || epoch != _connectionEpoch) {
        await socket.sink.close();
        return;
      }
      socket.sink.add(
        jsonEncode({
          'setup': {
            'model': 'models/${_token!.model}',
            'generationConfig': {
              'responseModalities': ['AUDIO'],
            },
            'systemInstruction': {
              'parts': [
                {'text': _instruction},
              ],
            },
            'tools': [
              {
                'functionDeclarations': cookingLiveFunctions()
                    .map((f) => {...f.toJson(), 'behavior': 'BLOCKING'})
                    .toList(),
              },
            ],
            'inputAudioTranscription': <String, Object?>{},
            'outputAudioTranscription': <String, Object?>{},
            'contextWindowCompression': {'slidingWindow': <String, Object?>{}},
            'sessionResumption': {'handle': ?resumeHandle},
          },
        }),
      );
      await setup.future.timeout(const Duration(seconds: 20));
    } catch (_) {
      // Never expose a WebSocket URI or token-bearing SDK exception to UI/logs.
      await socket.sink.close();
      throw StateError('Could not establish the live cooking session.');
    }
  }

  void _receive(Map<String, dynamic> message) {
    if (message['error'] != null) {
      _connectionError('The Live service rejected the request.');
      return;
    }
    if (message.containsKey('setupComplete')) {
      _ready = true;
      if (_setup?.isCompleted == false) _setup!.complete();
    }
    final content = message['serverContent'];
    if (content is Map) {
      if (content['interrupted'] == true) _events.add(const LiveInterrupted());
      final turn = content['modelTurn'];
      final parts = turn is Map ? turn['parts'] : null;
      if (parts is List) {
        for (final part in parts.whereType<Map>()) {
          final inline = part['inlineData'];
          if (inline is Map &&
              inline['mimeType'] is String &&
              (inline['mimeType'] as String).startsWith('audio/pcm') &&
              inline['data'] is String) {
            _events.add(LiveAudio(base64Decode(inline['data'] as String)));
          }
          // AUDIO sessions request outputAudioTranscription. Model text and
          // spoken transcription can arrive in separate packets; mixing both
          // duplicates captions and may display non-spoken model text.
        }
      }
      for (final entry in [
        ('inputTranscription', true),
        ('outputTranscription', false),
      ]) {
        final transcription = content[entry.$1];
        if (transcription is Map && transcription['text'] is String) {
          _events.add(
            LiveTranscript(
              transcription['text'] as String,
              isUser: entry.$2,
              finished: transcription['finished'] == true,
            ),
          );
        }
      }
      if (content['turnComplete'] == true) {
        _events.add(const LiveTurnComplete());
      }
    }
    final toolCall = message['toolCall'];
    if (toolCall is Map && toolCall['functionCalls'] is List) {
      for (final call in (toolCall['functionCalls'] as List).whereType<Map>()) {
        if (call['name'] is! String || call['args'] is! Map) continue;
        _events.add(
          LiveToolCall(
            name: call['name'] as String,
            arguments: Map<String, Object?>.from(call['args'] as Map),
            id: call['id'] as String?,
          ),
        );
      }
    }
    final cancellation = message['toolCallCancellation'];
    if (cancellation is Map && cancellation['ids'] is List) {
      _events.add(
        LiveToolsCancelled(
          (cancellation['ids'] as List).whereType<String>().toList(),
        ),
      );
    }
    final resumption = message['sessionResumptionUpdate'];
    if (resumption is Map) {
      if (resumption['resumable'] == false) _resumeHandle = null;
      if (resumption['resumable'] == true &&
          resumption['newHandle'] is String) {
        _resumeHandle = resumption['newHandle'] as String;
      }
    }
    if (message.containsKey('goAway')) unawaited(_resume());
  }

  void _connectionError(String message) {
    if (_closed) return;
    if (_setup?.isCompleted == false) {
      _setup!.completeError(StateError(message));
    } else {
      _events.addError(StateError(message));
    }
  }

  Future<void> _resume() async {
    if (_resuming || _closed) return;
    if (_resumeHandle == null) {
      _events.addError(
        StateError('Live session expired; reconnect to continue.'),
      );
      return;
    }
    _resuming = true;
    final resumed = Completer<void>();
    _resumeFinished = resumed;
    _ready = false;
    _events.add(
      const LiveConnectionNotice(
        'Reconnecting live session…',
        reconnecting: true,
      ),
    );
    try {
      ++_connectionEpoch;
      await _subscription?.cancel();
      await _socket?.sink.close();
      if (_closed) return;
      await _openSocket(resumeHandle: _resumeHandle);
      if (!_closed) {
        _events.add(const LiveConnectionNotice('Live session resumed.'));
      }
    } catch (_) {
      if (!_closed) {
        _events.addError(
          StateError(
            'Could not resume the live session. Reconnect to continue.',
          ),
        );
      }
    } finally {
      _resuming = false;
      resumed.complete();
    }
  }

  void _send(Map<String, Object?> data) {
    if (!_closed && _ready) _socket!.sink.add(jsonEncode(data));
  }

  @override
  Future<void> sendAudio(Uint8List pcm16khz) async => _send({
    'realtimeInput': {
      'audio': {
        'mimeType': 'audio/pcm;rate=16000',
        'data': base64Encode(pcm16khz),
      },
    },
  });
  @override
  Future<void> sendVideo(Uint8List jpeg) async => _send({
    'realtimeInput': {
      'video': {'mimeType': 'image/jpeg', 'data': base64Encode(jpeg)},
    },
  });
  Future<void> _awaitReady() async {
    if (_resuming && _resumeFinished != null) {
      await _resumeFinished!.future.timeout(const Duration(seconds: 25));
    }
    if (_closed || !_ready) throw StateError('Live connection is not ready.');
  }

  @override
  Future<void> sendText(String text) async {
    await _awaitReady();
    _send({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
            ],
          },
        ],
        'turnComplete': true,
      },
    });
  }

  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async {
    // Preserve stateful tool acknowledgements through a brief reconnection;
    // media can be dropped, but pretending a tool reply was sent is incorrect.
    await _awaitReady();
    _send({
      'toolResponse': {
        'functionResponses': [
          {
            'name': call.name,
            if (call.id != null) 'id': call.id,
            'response': response,
          },
        ],
      },
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ready = false;
    ++_connectionEpoch;
    if (_setup?.isCompleted == false) {
      _setup!.completeError(StateError('Live session closed.'));
    }
    await _subscription?.cancel();
    await _socket?.sink.close();
    _token = null;
    _resumeHandle = null;
    await _events.close();
  }
}
