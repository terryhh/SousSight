import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/live/firebase_live_transport.dart';
import 'package:soussight/live/live_tools.dart' show kLiveModel;
import 'package:soussight/live/live_types.dart';

/// In-memory stand-in for firebase_ai's [LiveSession]: no WebSocket, no
/// network. The test pushes server messages and inspects what was sent.
class FakeLiveSession implements LiveSession {
  final server = StreamController<LiveServerResponse>.broadcast();
  final sent = <String>[];
  final audio = <InlineDataPart>[];
  final video = <InlineDataPart>[];
  final texts = <Content>[];
  final toolResponses = <List<FunctionResponse>>[];
  final resumedWith = <String?>[];
  Completer<void>? resumeGate;
  Object? resumeError;
  bool closed = false;

  void push(LiveServerMessage message) =>
      server.add(LiveServerResponse(message: message));

  @override
  Stream<LiveServerResponse> receive() => server.stream;

  @override
  Future<void> resumeSession({
    SessionResumptionConfig? sessionResumption,
  }) async {
    resumedWith.add(sessionResumption?.handle);
    sent.add('resume');
    await resumeGate?.future;
    if (resumeError case final error?) throw error;
  }

  @override
  Future<void> sendAudioRealtime(InlineDataPart audio) async {
    sent.add('audio');
    this.audio.add(audio);
  }

  @override
  Future<void> sendVideoRealtime(InlineDataPart video) async {
    sent.add('video');
    this.video.add(video);
  }

  @override
  Future<void> send({Content? input, bool turnComplete = false}) async {
    sent.add('text:$turnComplete');
    texts.add(input!);
  }

  @override
  Future<void> sendToolResponse(
    List<FunctionResponse>? functionResponses,
  ) async {
    sent.add('tool');
    toolResponses.add(functionResponses!);
  }

  @override
  Future<void> close() async {
    closed = true;
    sent.add('close');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Harness {
  Harness() {
    transport = FirebaseLiveTransport(
      model: 'gemini-test-live',
      openSession: ({required model, required systemInstruction}) {
        openedModel = model;
        openedInstruction = systemInstruction;
        return opener.future;
      },
    );
    transport.events.listen(events.add, onError: errors.add);
  }

  late final FirebaseLiveTransport transport;
  final session = FakeLiveSession();
  final opener = Completer<LiveSession>();
  final events = <LiveEvent>[];
  final errors = <Object>[];
  String? openedModel;
  String? openedInstruction;

  /// Opens the session and completes setup with the first server message
  /// (setupComplete is not exported by firebase_ai; any message completes it).
  Future<void> connect() async {
    final connecting = transport.connect(systemInstruction: 'Coach the cook.');
    opener.complete(session);
    await pumpEventQueue();
    session.push(LiveServerContent());
    await connecting;
    await pumpEventQueue();
  }

  List<String> get errorMessages => [
    for (final e in errors) (e as StateError).message,
  ];
}

LiveServerContent content({
  List<Part> parts = const [],
  bool? turnComplete,
  bool? interrupted,
  Transcription? input,
  Transcription? output,
}) => LiveServerContent(
  modelTurn: parts.isEmpty ? null : Content.model(parts),
  turnComplete: turnComplete,
  interrupted: interrupted,
  inputTranscription: input,
  outputTranscription: output,
);

void main() {
  group('connect', () {
    test('opens the configured model with the instruction and waits for '
        'the first server message', () async {
      final h = Harness();
      var connected = false;
      final connecting = h.transport
          .connect(systemInstruction: 'Coach the cook.')
          .then((_) => connected = true);
      h.opener.complete(h.session);
      await pumpEventQueue();

      expect(h.openedModel, 'gemini-test-live');
      expect(h.openedInstruction, 'Coach the cook.');
      expect(connected, isFalse, reason: 'setup has not completed yet');

      h.session.push(LiveServerContent());
      await connecting;
      expect(connected, isTrue);
      expect(h.events, isEmpty, reason: 'setup emits no cook-facing event');
      expect(h.errors, isEmpty);
    });

    test('defaults to the shipped Live model', () {
      expect(FirebaseLiveTransport().model, kLiveModel);
    });

    test('a server that never answers setup times out after 20 s', () {
      fakeAsync((async) {
        final h = Harness();
        Object? failure;
        h.transport
            .connect(systemInstruction: 'x')
            .catchError((Object e) => failure = e);
        h.opener.complete(h.session);
        async.elapse(const Duration(seconds: 19));
        expect(failure, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(failure, isA<TimeoutException>());
      });
    });

    test('closing while the session opens closes that session and stays '
        'silent', () async {
      final h = Harness();
      final connecting = h.transport.connect(systemInstruction: 'x');
      await h.transport.close();
      h.opener.complete(h.session);
      await connecting;

      expect(h.session.closed, isTrue);
      // Never bound: later sends do not reach the stale session.
      await h.transport.sendText('hello');
      expect(h.session.sent, ['close']);
      expect(h.errors, isEmpty);
    });

    test(
      'closing during setup fails connect and releases the session',
      () async {
        final h = Harness();
        final connecting = h.transport.connect(systemInstruction: 'x');
        h.opener.complete(h.session);
        await pumpEventQueue();
        final failure = expectLater(
          connecting,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Live session closed.',
            ),
          ),
        );
        await h.transport.close();
        await failure;

        expect(h.session.closed, isTrue);
        expect(h.errors, isEmpty);
      },
    );

    test('a stream error during setup fails connect without leaking the '
        'provider error', () async {
      final h = Harness();
      final connecting = h.transport.connect(systemInstruction: 'x');
      h.opener.complete(h.session);
      await pumpEventQueue();
      h.session.server.addError(Exception('apiKey=secret-ish provider text'));

      await expectLater(
        connecting,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Live setup failed.',
          ),
        ),
      );
      await pumpEventQueue();
      expect(h.errorMessages, ['Live connection failed.']);
    });
  });

  group('server messages', () {
    test('audio, transcripts, interruption and turn end map to Live events '
        'in order', () async {
      final h = Harness();
      await h.connect();
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      h.session.push(
        content(
          interrupted: true,
          parts: [
            InlineDataPart('audio/pcm;rate=24000', pcm),
            const TextPart('model prose is not a caption'),
            InlineDataPart('image/png', Uint8List(2)),
          ],
          input: const Transcription(text: 'is it done?', finished: true),
          output: const Transcription(text: 'Let me look'),
          turnComplete: true,
        ),
      );
      await pumpEventQueue();

      expect(h.events, hasLength(5));
      expect(h.events[0], isA<LiveInterrupted>());
      expect((h.events[1] as LiveAudio).pcm, pcm);
      final heard = h.events[2] as LiveTranscript;
      expect(
        (heard.text, heard.isUser, heard.finished),
        ('is it done?', true, true),
      );
      final spoken = h.events[3] as LiveTranscript;
      expect(
        (spoken.text, spoken.isUser, spoken.finished),
        ('Let me look', false, false),
      );
      expect(h.events[4], isA<LiveTurnComplete>());
    });

    test(
      'empty content and transcriptions without text emit nothing',
      () async {
        final h = Harness();
        await h.connect();
        h.session.push(
          content(
            input: const Transcription(finished: true),
            output: const Transcription(),
            turnComplete: false,
            interrupted: false,
          ),
        );
        await pumpEventQueue();
        expect(h.events, isEmpty);
      },
    );

    test(
      'tool calls carry name, arguments and id; cancellations carry ids',
      () async {
        final h = Harness();
        await h.connect();
        h.session.push(
          LiveServerToolCall(
            functionCalls: [
              const FunctionCall('start_timer', {'minutes': 3}, id: 'call-1'),
              const FunctionCall('next_step', {}),
            ],
          ),
        );
        h.session.push(LiveServerToolCall());
        h.session.push(LiveServerToolCallCancellation(functionIds: ['call-1']));
        h.session.push(LiveServerToolCallCancellation());
        await pumpEventQueue();

        final first = h.events[0] as LiveToolCall;
        expect(first.name, 'start_timer');
        expect(first.arguments, {'minutes': 3});
        expect(first.id, 'call-1');
        final second = h.events[1] as LiveToolCall;
        expect(second.name, 'next_step');
        expect(second.id, isNull);
        expect((h.events[2] as LiveToolsCancelled).ids, ['call-1']);
        expect((h.events[3] as LiveToolsCancelled).ids, isEmpty);
        expect(h.events, hasLength(4));
      },
    );

    test('a stream error after setup is reported generically', () async {
      final h = Harness();
      await h.connect();
      h.session.server.addError(Exception('raw provider failure'));
      await pumpEventQueue();
      expect(h.errorMessages, ['Live connection failed.']);
    });

    test(
      'the server ending the stream is reported unless the cook closed',
      () async {
        final ended = Harness();
        await ended.connect();
        await ended.session.server.close();
        await pumpEventQueue();
        expect(ended.errorMessages, ['Live connection ended.']);

        final closed = Harness();
        await closed.connect();
        await closed.transport.close();
        await closed.session.server.close();
        await pumpEventQueue();
        expect(closed.errors, isEmpty);
      },
    );
  });

  group('session resumption', () {
    test(
      'a going-away notice resumes with the latest resumable handle',
      () async {
        final h = Harness();
        await h.connect();
        h.session.push(
          SessionResumptionUpdate(newHandle: 'h1', resumable: true),
        );
        h.session.push(
          SessionResumptionUpdate(newHandle: 'h2', resumable: true),
        );
        // A non-resumable update without a handle neither sets nor clears.
        h.session.push(SessionResumptionUpdate());
        h.session.push(const GoingAwayNotice(timeLeft: '10s'));
        await pumpEventQueue();

        expect(h.session.resumedWith, ['h2']);
        final notices = h.events.whereType<LiveConnectionNotice>().toList();
        expect(notices.map((n) => (n.message, n.reconnecting)), [
          ('Reconnecting live session…', true),
          ('Live session resumed.', false),
        ]);
        expect(h.errors, isEmpty);
      },
    );

    test('without a handle the cook is told to reconnect', () async {
      final h = Harness();
      await h.connect();
      h.session.push(const GoingAwayNotice());
      await pumpEventQueue();

      expect(h.session.resumedWith, isEmpty);
      expect(h.errorMessages, ['Live session expired; reconnect to continue.']);
    });

    test('a resumable:false update clears the stored handle', () async {
      final h = Harness();
      await h.connect();
      h.session.push(SessionResumptionUpdate(newHandle: 'h1', resumable: true));
      h.session.push(
        SessionResumptionUpdate(newHandle: 'h9', resumable: false),
      );
      h.session.push(const GoingAwayNotice());
      await pumpEventQueue();

      expect(h.session.resumedWith, isEmpty);
      expect(h.errorMessages, ['Live session expired; reconnect to continue.']);
    });

    test('while resuming, media and text are dropped, a second notice is '
        'ignored and the old stream ending is not an error', () async {
      final h = Harness();
      await h.connect();
      h.session.resumeGate = Completer<void>();
      h.session.push(SessionResumptionUpdate(newHandle: 'h1', resumable: true));
      h.session.push(const GoingAwayNotice());
      h.session.push(const GoingAwayNotice());
      await pumpEventQueue();

      await h.transport.sendAudio(Uint8List(4));
      await h.transport.sendVideo(Uint8List(4));
      await h.transport.sendText('still there?');
      // Tool results are still delivered so the model is not left waiting.
      await h.transport.respondToTool(
        const LiveToolCall(name: 'start_timer', arguments: {}, id: 'c1'),
        {'ok': true},
      );
      await h.session.server.close();
      await pumpEventQueue();

      expect(h.session.sent, ['resume', 'tool']);
      expect(h.errors, isEmpty);

      h.session.resumeGate!.complete();
      await pumpEventQueue();
      await h.transport.sendText('back');
      expect(h.session.sent, ['resume', 'tool', 'text:true']);
    });

    test(
      'a failed resume is reported and sending works again afterwards',
      () async {
        final h = Harness();
        await h.connect();
        h.session.resumeError = Exception('socket refused');
        h.session.push(
          SessionResumptionUpdate(newHandle: 'h1', resumable: true),
        );
        h.session.push(const GoingAwayNotice());
        await pumpEventQueue();

        expect(h.errorMessages, ['Could not resume live session.']);
        expect(
          h.events.whereType<LiveConnectionNotice>().map((n) => n.message),
          ['Reconnecting live session…'],
        );
        await h.transport.sendAudio(Uint8List(2));
        expect(h.session.sent.last, 'audio');
      },
    );

    test('closing mid-resume suppresses both the success notice and the '
        'failure', () async {
      for (final fails in [false, true]) {
        final h = Harness();
        await h.connect();
        h.session.resumeGate = Completer<void>();
        if (fails) h.session.resumeError = Exception('late failure');
        h.session.push(
          SessionResumptionUpdate(newHandle: 'h', resumable: true),
        );
        h.session.push(const GoingAwayNotice());
        await pumpEventQueue();
        await h.transport.close();
        h.session.resumeGate!.complete();
        await pumpEventQueue();

        expect(
          h.events.whereType<LiveConnectionNotice>().map((n) => n.message),
          ['Reconnecting live session…'],
          reason: 'fails=$fails',
        );
        expect(h.errors, isEmpty, reason: 'fails=$fails');
      }
    });
  });

  group('client messages', () {
    test(
      'audio, video, text and tool results use the Live wire formats',
      () async {
        final h = Harness();
        await h.connect();
        final pcm = Uint8List.fromList([9, 9]);
        final jpeg = Uint8List.fromList([0xff, 0xd8]);
        await h.transport.sendAudio(pcm);
        await h.transport.sendVideo(jpeg);
        await h.transport.sendText('What next?');
        await h.transport.respondToTool(
          const LiveToolCall(name: 'start_timer', arguments: {}, id: 'c7'),
          {'started': true},
        );

        expect(h.session.sent, ['audio', 'video', 'text:true', 'tool']);
        expect(h.session.audio.single.mimeType, 'audio/pcm;rate=16000');
        expect(h.session.audio.single.bytes, pcm);
        expect(h.session.video.single.mimeType, 'image/jpeg');
        expect(h.session.video.single.bytes, jpeg);
        expect(
          (h.session.texts.single.parts.single as TextPart).text,
          'What next?',
        );
        final response = h.session.toolResponses.single.single;
        expect(response.name, 'start_timer');
        expect(response.id, 'c7');
        expect(response.response, {'started': true});
      },
    );

    test('nothing is sent before connect or after close; close is '
        'idempotent', () async {
      final idle = FirebaseLiveTransport(
        openSession: ({required model, required systemInstruction}) =>
            throw StateError('not opened'),
      );
      await idle.sendAudio(Uint8List(1));
      await idle.sendVideo(Uint8List(1));
      await idle.sendText('x');
      await idle.respondToTool(
        const LiveToolCall(name: 'n', arguments: {}),
        const {},
      );
      await idle.close();

      final h = Harness();
      await h.connect();
      await h.transport.close();
      await h.transport.close();
      await h.transport.sendAudio(Uint8List(1));
      await h.transport.sendVideo(Uint8List(1));
      await h.transport.sendText('x');
      await h.transport.respondToTool(
        const LiveToolCall(name: 'n', arguments: {}),
        const {},
      );
      expect(h.session.sent, ['close']);
    });

    test('close ends the event stream', () async {
      final h = Harness();
      await h.connect();
      final done = expectLater(h.transport.events, emitsDone);
      await h.transport.close();
      await done;
    });
  });
}
