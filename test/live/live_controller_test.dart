import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/live/live_controller.dart';
import 'package:soussight/live/live_tools.dart';
import 'package:soussight/live/live_types.dart';

class TestMedia implements LiveMedia {
  final audio = StreamController<Uint8List>.broadcast();
  final video = StreamController<Uint8List>.broadcast();
  final failures = StreamController<String>.broadcast();
  int starts = 0;
  int stops = 0;
  int played = 0;
  int interruptions = 0;
  bool muted = false;
  bool active = false;
  Completer<void>? stopGate;
  @override
  Stream<Uint8List> get microphone => audio.stream;
  @override
  Stream<Uint8List> get frames => video.stream;
  @override
  Stream<String> get errors => failures.stream;
  @override
  Future<void> start() async {
    starts++;
    active = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopGate?.future;
    active = false;
  }

  @override
  void setMicrophoneMuted(bool value) {
    muted = value;
  }

  @override
  void playAudio(Uint8List pcm24khz) {
    played++;
  }

  @override
  void interruptPlayback() {
    interruptions++;
  }
}

class TestTransport implements LiveTransport {
  final source = StreamController<LiveEvent>.broadcast();
  final responses = <(LiveToolCall, Map<String, Object?>)>[];
  final texts = <String>[];
  Completer<void>? connectionGate;
  Completer<void>? textGate;
  int framesSent = 0;
  int audioSent = 0;
  int closes = 0;
  @override
  Stream<LiveEvent> get events => source.stream;
  @override
  Future<void> connect({required String systemInstruction}) async {
    await connectionGate?.future;
  }

  @override
  Future<void> sendAudio(Uint8List pcm16khz) async {
    audioSent++;
  }

  @override
  Future<void> sendVideo(Uint8List jpeg) async {
    framesSent++;
  }

  @override
  Future<void> sendText(String text) async {
    texts.add(text);
    await textGate?.future;
  }

  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async {
    responses.add((call, response));
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late TestMedia media;
  late TestTransport transport;
  late LiveCookingController controller;
  late List<LiveToolCall> calls;
  setUp(() {
    media = TestMedia();
    transport = TestTransport();
    calls = [];
    controller = LiveCookingController(
      transportFactory: () => transport,
      media: media,
      onToolCall: (call) async {
        calls.add(call);
        return {'ok': true};
      },
    );
  });
  tearDown(() async {
    await controller.stop();
    controller.dispose();
  });

  test('keeps listening across turns and plays subsequent audio', () async {
    await controller.start(cookingContext: 'chickpea wrap');
    transport.source.add(LiveAudio(Uint8List(4)));
    transport.source.add(const LiveTurnComplete());
    transport.source.add(LiveAudio(Uint8List(4)));
    await flush();
    expect(media.played, 2);
    expect(controller.status, LiveCookingStatus.speaking);
    transport.source.add(const LiveInterrupted());
    await flush();
    expect(media.interruptions, 1);
    expect(controller.status, LiveCookingStatus.listening);
  });

  test('muting gates microphone but continues camera frames', () async {
    await controller.start(cookingContext: 'wrap');
    controller.setMicrophoneMuted(true);
    media.audio.add(Uint8List(8));
    media.video.add(Uint8List(8));
    await flush();
    expect(media.muted, true);
    expect(transport.audioSent, 0);
    expect(transport.framesSent, 1);
  });

  test(
    'stop releases media and ignores late server and media events',
    () async {
      await controller.start(cookingContext: 'wrap');
      await controller.stop();
      transport.source.add(LiveAudio(Uint8List(4)));
      media.video.add(Uint8List(4));
      media.audio.add(Uint8List(4));
      await flush();
      expect(media.stops, 1);
      expect(transport.closes, 1);
      expect(media.played, 0);
      expect(controller.latestFrame, isNull);
      expect(controller.status, LiveCookingStatus.idle);
    },
  );

  test('stopping during connection does not resurrect a session', () async {
    transport.connectionGate = Completer<void>();
    final starting = controller.start(cookingContext: 'wrap');
    await flush();
    await controller.stop();
    transport.connectionGate!.complete();
    await starting;
    expect(controller.status, LiveCookingStatus.idle);
    expect(transport.texts, isEmpty);
    expect(transport.closes, greaterThanOrEqualTo(1));
  });

  test('duplicate tool ids run once and return the saved result', () async {
    await controller.start(cookingContext: 'wrap');
    const call = LiveToolCall(
      id: 'timer-1',
      name: 'start_timer',
      arguments: {'id': 'onions', 'label': 'Quick pickle', 'seconds': 300},
    );
    transport.source.add(call);
    transport.source.add(call);
    await flush();
    expect(calls, hasLength(1));
    expect(transport.responses, hasLength(2));
    expect(transport.responses.last.$2, {'ok': true});
  });

  test('invalid actions cannot reach the host handler', () async {
    await controller.start(cookingContext: 'wrap');
    transport.source.add(
      const LiveToolCall(
        id: 'bad',
        name: 'start_timer',
        arguments: {'id': 'timer', 'label': 'Oops', 'seconds': -30},
      ),
    );
    transport.source.add(
      const LiveToolCall(
        id: 'send',
        name: 'send_sms',
        arguments: {'phone': '123'},
      ),
    );
    await flush();
    expect(calls, isEmpty);
    expect(transport.responses.every((r) => r.$2['ok'] == false), true);
  });

  test('readiness requires an active watch and a fresh frame', () async {
    await controller.start(cookingContext: 'wrap');
    transport.source.add(
      const LiveToolCall(
        id: 'r1',
        name: 'report_readiness',
        arguments: {
          'watchId': 'inactive',
          'state': 'ready',
          'observation': 'Mixture looks evenly combined.',
        },
      ),
    );
    await flush();
    expect(calls, isEmpty);
    final id = controller.startWatch('Evenly mixed');
    media.video.add(Uint8List(8));
    await flush();
    transport.source.add(
      LiveToolCall(
        id: 'r2',
        name: 'report_readiness',
        arguments: {
          'watchId': id,
          'state': 'ready',
          'observation': 'Mixture looks evenly combined.',
        },
      ),
    );
    await flush();
    expect(calls, hasLength(1));
    transport.source.add(
      LiveToolCall(
        id: 'r3',
        name: 'report_readiness',
        arguments: {
          'watchId': id,
          'state': 'ready',
          'observation': 'Still combined.',
        },
      ),
    );
    await flush();
    expect(calls, hasLength(1));
    expect(transport.responses.last.$2['alreadyReported'], true);
  });

  test(
    'a readiness result for an old watch cannot update the new watch',
    () async {
      await controller.start(cookingContext: 'wrap');
      final oldId = controller.startWatch('Mixed yogurt');
      media.video.add(Uint8List(8));
      await flush();
      final currentId = controller.startWatch('Mashed chickpeas');
      expect(currentId, isNot(oldId));
      transport.source.add(
        LiveToolCall(
          id: 'old-report',
          name: 'report_readiness',
          arguments: {
            'watchId': oldId,
            'state': 'ready',
            'observation': 'Yogurt looks mixed.',
          },
        ),
      );
      await flush();
      expect(calls, isEmpty);
      expect(transport.responses.single.$2['ok'], false);
      expect(controller.watchId, currentId);
      transport.source.add(
        LiveToolCall(
          id: 'current-report',
          name: 'report_readiness',
          arguments: {
            'watchId': currentId,
            'state': 'ready',
            'observation': 'Chickpeas look mashed.',
          },
        ),
      );
      await flush();
      expect(calls.single.id, 'current-report');
    },
  );

  test(
    'a cached old readiness result is rejected after switching watches',
    () async {
      await controller.start(cookingContext: 'wrap');
      final oldId = controller.startWatch('Mixed yogurt');
      media.video.add(Uint8List(8));
      await flush();
      final oldCall = LiveToolCall(
        id: 'cached-report',
        name: 'report_readiness',
        arguments: {
          'watchId': oldId,
          'state': 'ready',
          'observation': 'Yogurt looks mixed.',
        },
      );
      transport.source.add(oldCall);
      await flush();
      expect(calls, hasLength(1));
      controller.startWatch('Mashed chickpeas');
      transport.source.add(oldCall);
      await flush();
      expect(calls, hasLength(1));
      expect(transport.responses.last.$2['ok'], false);
    },
  );

  test(
    'watch tool returns a host id that subsequent reports must echo',
    () async {
      await controller.start(cookingContext: 'wrap');
      transport.source.add(
        const LiveToolCall(
          id: 'watch',
          name: 'watch_cooking',
          arguments: {'goal': 'Evenly mixed'},
        ),
      );
      await flush();
      expect(controller.watchId, isNotNull);
      expect(transport.responses.single.$2['watchId'], controller.watchId);
      controller.stopWatch();
      expect(controller.watchId, isNull);
    },
  );

  test(
    'old asynchronous readiness completion does not suppress the new watch',
    () async {
      final gate = Completer<Map<String, Object?>>();
      controller.dispose();
      controller = LiveCookingController(
        transportFactory: () => transport,
        media: media,
        onToolCall: (call) async {
          calls.add(call);
          if (call.id == 'slow') return gate.future;
          return {'ok': true};
        },
      );
      await controller.start(cookingContext: 'wrap');
      final oldId = controller.startWatch('Mixed yogurt');
      media.video.add(Uint8List(8));
      await flush();
      transport.source.add(
        LiveToolCall(
          id: 'slow',
          name: 'report_readiness',
          arguments: {
            'watchId': oldId,
            'state': 'ready',
            'observation': 'Yogurt looks mixed.',
          },
        ),
      );
      await flush();
      final currentId = controller.startWatch('Mashed chickpeas');
      gate.complete({'ok': true});
      await flush();
      expect(transport.responses.single.$2['ok'], false);
      transport.source.add(
        LiveToolCall(
          id: 'current',
          name: 'report_readiness',
          arguments: {
            'watchId': currentId,
            'state': 'ready',
            'observation': 'Chickpeas look mashed.',
          },
        ),
      );
      await flush();
      expect(calls.map((c) => c.id), ['slow', 'current']);
      expect(transport.responses.last.$2['alreadyReported'], isNot(true));
    },
  );

  test(
    'connect waits for previous media cleanup before starting capture',
    () async {
      await controller.start(cookingContext: 'wrap');
      media.stopGate = Completer<void>();
      final stopping = controller.stop();
      transport = TestTransport();
      final restarting = controller.start(cookingContext: 'new step');
      await flush();
      expect(media.starts, 1);
      media.stopGate!.complete();
      await stopping;
      await restarting;
      expect(media.starts, 2);
      expect(media.active, true);
      expect(controller.status, LiveCookingStatus.listening);
    },
  );

  test(
    'late send failure from a stopped session does not stop its replacement',
    () async {
      await controller.start(cookingContext: 'wrap');
      final oldTransport = transport;
      oldTransport.textGate = Completer<void>();
      final sending = controller.sendText('a slow message');
      await flush();
      await controller.stop();
      transport = TestTransport();
      await controller.start(cookingContext: 'new step');
      oldTransport.textGate!.completeError(StateError('Old connection failed'));
      await sending;
      expect(controller.status, LiveCookingStatus.listening);
      expect(transport.closes, 0);
      expect(media.active, true);
    },
  );

  test(
    'duplicate Connect then Stop cannot start an unexpected replacement',
    () async {
      transport.connectionGate = Completer<void>();
      final first = controller.start(cookingContext: 'wrap');
      await flush();
      final duplicate = controller.start(cookingContext: 'wrap');
      await controller.stop();
      transport.connectionGate!.complete();
      await first;
      await duplicate;
      expect(media.starts, 1);
      expect(controller.status, LiveCookingStatus.idle);
    },
  );

  test('disposing while a reconnect waits cannot restart capture', () async {
    transport.connectionGate = Completer<void>();
    final first = controller.start(cookingContext: 'wrap');
    await flush();
    await controller.stop();
    final replacement = controller.start(cookingContext: 'wrap');
    controller.dispose();
    transport.connectionGate!.complete();
    await first;
    await replacement;
    expect(media.starts, 1);
    expect(controller.status, LiveCookingStatus.idle);
  });

  test('cancelled queued tools do not execute', () async {
    final gate = Completer<Map<String, Object?>>();
    controller.dispose();
    controller = LiveCookingController(
      transportFactory: () => transport,
      media: media,
      onToolCall: (call) {
        calls.add(call);
        return gate.future;
      },
    );
    await controller.start(cookingContext: 'wrap');
    transport.source.add(
      const LiveToolCall(id: 'first', name: 'check_now', arguments: {}),
    );
    await flush();
    transport.source.add(
      const LiveToolCall(id: 'second', name: 'next_step', arguments: {}),
    );
    transport.source.add(const LiveToolsCancelled(['second']));
    await flush();
    gate.complete({'ok': true});
    await flush();
    expect(calls.map((c) => c.id), ['first']);
  });

  test('tool validation checks bounds and malformed UI', () {
    expect(
      validateLiveTool(
        const LiveToolCall(
          name: 'show_cooking_ui',
          arguments: {'uiJson': 'oops'},
        ),
      ),
      isNotNull,
    );
    expect(
      validateLiveTool(
        const LiveToolCall(
          name: 'start_timer',
          arguments: {'id': 'x', 'label': 'X', 'seconds': 1.5},
        ),
      ),
      isNotNull,
    );
    expect(
      validateLiveTool(
        const LiveToolCall(
          name: 'show_cooking_ui',
          arguments: {'uiJson': '{"components":[]}'},
        ),
      ),
      isNull,
    );
  });
}
