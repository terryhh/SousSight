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
  Completer<void>? closeGate;
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
    await closeGate?.future;
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
        setup['generationConfig']['mediaResolution'],
        'MEDIA_RESOLUTION_LOW',
      );
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

  test('spoken captions use transcription deltas without duplicate model text packets', () async {
    final socket = TestSocket();
    final transport = EphemeralGeminiLiveTransport(
      tokenProvider: () async =>
          const LiveEphemeralToken(token: 'auth_tokens/test-session-token'),
      socketFactory: (_) => socket,
    );
    final events = <LiveEvent>[];
    final subscription = transport.events.listen(events.add);
    final connecting = transport.connect(systemInstruction: 'Cook together.');
    await flush();
    socket.receive({'setupComplete': {}});
    await connecting;
    socket.receive({
      'serverContent': {
        'modelTurn': {
          'parts': [
            {'text': 'Stir, stir, then stop.'},
            {'text': 'Private reasoning', 'thought': true},
          ],
        },
      },
    });
    socket.receive({
      'serverContent': {
        'outputTranscription': {'text': 'Stir, '},
      },
    });
    socket.receive({
      'serverContent': {
        'modelTurn': {
          'parts': [
            {'text': 'Stir, stir, then stop.'},
          ],
        },
      },
    });
    socket.receive({
      'serverContent': {
        'outputTranscription': {'text': 'stir, then stop.'},
      },
    });
    socket.receive({
      'serverContent': {'turnComplete': true},
    });
    await flush();
    expect(events.whereType<LiveTranscript>().map((event) => event.text), [
      'Stir, ',
      'stir, then stop.',
    ]);
    expect(events.whereType<LiveTurnComplete>(), hasLength(1));
    await subscription.cancel();
    await transport.close();
  });

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

  test('resumption keeps tool replies queued until the replacement acknowledges setup', () async {
    final original = TestSocket();
    final replacement = TestSocket();
    final sockets = [original, replacement];
    var opened = 0;
    final transport = EphemeralGeminiLiveTransport(
      tokenProvider: () async =>
          const LiveEphemeralToken(token: 'auth_tokens/test-session-token'),
      socketFactory: (_) => sockets[opened++],
    );
    final events = <LiveEvent>[];
    final errors = <Object>[];
    final subscription = transport.events.listen(
      events.add,
      onError: errors.add,
    );
    addTearDown(() async {
      await transport.close();
      await subscription.cancel();
    });
    final connecting = transport.connect(systemInstruction: 'Keep cooking.');
    await flush();
    original.receive({'setupComplete': {}});
    await connecting;
    original.receive({
      'sessionResumptionUpdate': {
        'resumable': true,
        'newHandle': 'resume-meal',
      },
    });
    original.receive({
      'goAway': {'timeLeft': '5s'},
    });
    await flush();
    expect(opened, 2);
    expect(original._sink.closed, isTrue);
    final setup = jsonDecode(replacement.outgoing.single as String)['setup'];
    expect(setup['sessionResumption']['handle'], 'resume-meal');
    expect(setup['systemInstruction']['parts'][0]['text'], 'Keep cooking.');
    var acknowledged = false;
    final replying = transport
        .respondToTool(
          const LiveToolCall(id: 'timer-1', name: 'start_timer', arguments: {}),
          {'ok': true, 'id': 'rest'},
        )
        .then((_) {
          acknowledged = true;
        });
    await transport.sendAudio(Uint8List.fromList([1, 2]));
    await flush();
    expect(acknowledged, isFalse);
    expect(replacement.outgoing, hasLength(1));
    original.receive({
      'serverContent': {'turnComplete': true},
    });
    replacement.receive({'setupComplete': {}});
    await replying;
    expect(acknowledged, isTrue);
    final reply = jsonDecode(
      replacement.outgoing.last as String,
    )['toolResponse']['functionResponses'].single;
    expect(reply['id'], 'timer-1');
    expect(reply['response'], {'ok': true, 'id': 'rest'});
    expect(events.whereType<LiveTurnComplete>(), isEmpty);
    expect(
      events.whereType<LiveConnectionNotice>().map((e) => e.reconnecting),
      [true, false],
    );
    expect(errors, isEmpty);
  });

  group('network error mid-session', () {
    Future<
      ({
        EphemeralGeminiLiveTransport transport,
        List<LiveEvent> events,
        List<Object> errors,
        int Function() opened,
      })
    >
    connected(List<TestSocket> sockets, {bool resumable = true}) async {
      var opened = 0;
      final transport = EphemeralGeminiLiveTransport(
        tokenProvider: () async =>
            const LiveEphemeralToken(token: 'auth_tokens/test-session-token'),
        socketFactory: (_) => sockets[opened++],
      );
      final events = <LiveEvent>[];
      final errors = <Object>[];
      final subscription = transport.events.listen(
        events.add,
        onError: errors.add,
      );
      addTearDown(() async {
        await transport.close();
        await subscription.cancel();
      });
      final connecting = transport.connect(systemInstruction: 'Keep cooking.');
      await flush();
      sockets.first.receive({'setupComplete': {}});
      await connecting;
      if (resumable) {
        sockets.first.receive({
          'sessionResumptionUpdate': {
            'resumable': true,
            'newHandle': 'resume-meal',
          },
        });
        await flush();
      }
      return (
        transport: transport,
        events: events,
        errors: errors,
        opened: () => opened,
      );
    }

    test('resumes once with the latest handle instead of failing', () async {
      final original = TestSocket();
      final replacement = TestSocket();
      final live = await connected([original, replacement]);
      original.incoming.addError(StateError('network dropped'));
      // A dropped socket usually closes right after the error; it must not
      // trigger a second resume.
      unawaited(original.incoming.close());
      await flush();
      expect(live.opened(), 2);
      final setup = jsonDecode(replacement.outgoing.single as String)['setup'];
      expect(setup['sessionResumption']['handle'], 'resume-meal');
      replacement.receive({'setupComplete': {}});
      await flush();
      expect(live.errors, isEmpty);
      expect(
        live.events.whereType<LiveConnectionNotice>().map((e) => e.reconnecting),
        [true, false],
      );
    });

    test('without a resume handle the error is surfaced', () async {
      final original = TestSocket();
      final live = await connected([original], resumable: false);
      original.incoming.addError(StateError('network dropped'));
      await flush();
      expect(live.opened(), 1);
      expect(live.errors, hasLength(1));
      expect(live.events.whereType<LiveConnectionNotice>(), isEmpty);
    });

    test('falls back to an error when the resume attempt fails', () async {
      final original = TestSocket();
      final replacement = TestSocket();
      final live = await connected([original, replacement]);
      original.incoming.addError(StateError('network dropped'));
      await flush();
      expect(live.opened(), 2);
      replacement.receive({'error': {'code': 503}});
      await flush();
      expect(live.errors, hasLength(1));
      expect(live.errors.single.toString(), contains('Could not resume'));
    });
  });

  test(
    'closing during old-socket cleanup prevents a replacement connection',
    () async {
      final original = TestSocket();
      var opened = 0;
      final transport = EphemeralGeminiLiveTransport(
        tokenProvider: () async =>
            const LiveEphemeralToken(token: 'auth_tokens/test-session-token'),
        socketFactory: (_) {
          opened++;
          return original;
        },
      );
      final events = <LiveEvent>[];
      final errors = <Object>[];
      final subscription = transport.events.listen(
        events.add,
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      final connecting = transport.connect(systemInstruction: 'Keep cooking.');
      await flush();
      original.receive({'setupComplete': {}});
      await connecting;
      original._sink.closeGate = Completer<void>();
      original.receive({
        'sessionResumptionUpdate': {
          'resumable': true,
          'newHandle': 'resume-meal',
        },
      });
      original.receive({'goAway': {}});
      await flush();
      expect(original._sink.closed, isTrue);
      final closing = transport.close();
      original._sink.closeGate!.complete();
      await closing;
      await flush();
      expect(opened, 1);
      expect(
        events.whereType<LiveConnectionNotice>().where((e) => !e.reconnecting),
        isEmpty,
      );
      expect(errors, isEmpty);
    },
  );

  test('closing during resumed setup rejects pending tool replies without sending them', () async {
    final original = TestSocket();
    final replacement = TestSocket();
    final sockets = [original, replacement];
    var opened = 0;
    final transport = EphemeralGeminiLiveTransport(
      tokenProvider: () async =>
          const LiveEphemeralToken(token: 'auth_tokens/test-session-token'),
      socketFactory: (_) => sockets[opened++],
    );
    final events = <LiveEvent>[];
    final errors = <Object>[];
    final subscription = transport.events.listen(
      events.add,
      onError: errors.add,
    );
    addTearDown(subscription.cancel);
    final connecting = transport.connect(systemInstruction: 'Keep cooking.');
    await flush();
    original.receive({'setupComplete': {}});
    await connecting;
    original.receive({
      'sessionResumptionUpdate': {
        'resumable': true,
        'newHandle': 'resume-meal',
      },
    });
    original.receive({'goAway': {}});
    await flush();
    expect(opened, 2);
    final rejectedReply = expectLater(
      transport.respondToTool(
        const LiveToolCall(id: 'timer-1', name: 'start_timer', arguments: {}),
        {'ok': true},
      ),
      throwsStateError,
    );
    await transport.close();
    await rejectedReply;
    replacement.receive({'setupComplete': {}});
    await flush();
    expect(opened, 2);
    expect(replacement._sink.closed, isTrue);
    expect(replacement.outgoing, hasLength(1));
    expect(
      events.whereType<LiveConnectionNotice>().where((e) => !e.reconnecting),
      isEmpty,
    );
    expect(errors, isEmpty);
  });

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
