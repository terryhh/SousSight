import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/live/ephemeral_live_transport.dart';
import 'package:soussight/live/live_types.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class TestSocket implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final outgoing = <dynamic>[];
  late final TestSink _sink = TestSink(outgoing);
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  Future<void> get ready async {}
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  void receive(Map<String, Object?> json) => incoming.add(jsonEncode(json));
}

class TestSink implements WebSocketSink {
  TestSink(this.sent);
  final List<dynamic> sent;
  bool closed = false;
  @override
  void add(dynamic event) => sent.add(event);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final value in stream) {
      add(value);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  Future<void> get done async {}
}

Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'uses constrained beta endpoint and waits for server setup acknowledgement',
    () async {
      final socket = TestSocket();
      Uri? url;
      final transport = EphemeralGeminiLiveTransport(
        tokenProvider: () async =>
            const LiveEphemeralToken(token: 'auth_tokens/test-session-token'),
        socketFactory: (uri) {
          url = uri;
          return socket;
        },
      );
      final events = <LiveEvent>[];
      final subscription = transport.events.listen(events.add);
      var connected = false;
      final connection = transport
          .connect(systemInstruction: 'Cook together.')
          .then((_) {
            connected = true;
          });
      await flush();
      expect(connected, false);
      expect(
        url!.path,
        contains('v1beta.GenerativeService.BidiGenerateContentConstrained'),
      );
      expect(url!.queryParameters.keys, ['access_token']);
      final setup = jsonDecode(socket.outgoing.single as String)['setup'];
      expect(setup['model'], 'models/gemini-3.8-live');
      expect(setup['generationConfig']['responseModalities'], ['AUDIO']);
      expect(
        setup['tools'][0]['functionDeclarations'][0]['behavior'],
        'BLOCKING',
      );
      socket.receive({'setupComplete': {}});
      await connection;
      expect(connected, true);
      socket.receive({
        'serverContent': {'turnComplete': true},
      });
      socket.receive({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {
                  'mimeType': 'audio/pcm;rate=24000',
                  'data': base64Encode([0, 1, 2, 3]),
                },
              },
            ],
          },
        },
      });
      await flush();
      expect(events.whereType<LiveTurnComplete>(), hasLength(1));
      expect(events.whereType<LiveAudio>(), hasLength(1));
      await transport.sendAudio(Uint8List.fromList([1, 2]));
      expect(
        jsonDecode(
          socket.outgoing.last as String,
        )['realtimeInput']['audio']['mimeType'],
        'audio/pcm;rate=16000',
      );
      await subscription.cancel();
      await transport.close();
    },
  );

  test('rejects long-lived API keys before opening any socket', () async {
    var opened = false;
    final transport = EphemeralGeminiLiveTransport(
      tokenProvider: () async =>
          const LiveEphemeralToken(token: 'long-lived-secret-key'),
      socketFactory: (_) {
        opened = true;
        return TestSocket();
      },
    );
    await expectLater(
      transport.connect(systemInstruction: 'cook'),
      throwsStateError,
    );
    expect(opened, false);
    await transport.close();
  });

  test(
    'tool call identifiers round-trip and interruption is emitted',
    () async {
      final socket = TestSocket();
      final transport = EphemeralGeminiLiveTransport(
        tokenProvider: () async =>
            const LiveEphemeralToken(token: 'auth_tokens/test-session-token'),
        socketFactory: (_) => socket,
      );
      final events = <LiveEvent>[];
      final subscription = transport.events.listen(events.add);
      final connection = transport.connect(systemInstruction: 'cook');
      await flush();
      socket.receive({'setupComplete': {}});
      await connection;
      socket.receive({
        'toolCall': {
          'functionCalls': [
            {'id': 'call-7', 'name': 'check_now', 'args': {}},
          ],
        },
      });
      socket.receive({
        'serverContent': {'interrupted': true},
      });
      await flush();
      final call = events.whereType<LiveToolCall>().single;
      expect(call.id, 'call-7');
      expect(events.whereType<LiveInterrupted>(), hasLength(1));
      await transport.respondToTool(call, {'ok': true});
      final response = jsonDecode(
        socket.outgoing.last as String,
      )['toolResponse']['functionResponses'][0];
      expect(response['id'], 'call-7');
      expect(response['response'], {'ok': true});
      await subscription.cancel();
      await transport.close();
    },
  );

  test(
    'token metadata rejects injected model paths and unsupported API versions',
    () {
      expect(
        () => LiveEphemeralToken.fromJson({
          'token': 'auth_tokens/test',
          'model': '../other',
          'apiVersion': 'v1beta',
        }),
        throwsFormatException,
      );
      expect(
        () => LiveEphemeralToken.fromJson({
          'token': 'auth_tokens/test',
          'model': 'gemini-3.8-live',
          'apiVersion': 'evil',
        }),
        throwsFormatException,
      );
    },
  );
}
