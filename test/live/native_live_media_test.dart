import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/live/native_live_media.dart';

class FakeCamera implements NativeCamera {
  FakeCamera(this.log, {this.openGate, this.openError});

  final List<String> log;
  final Completer<void>? openGate;
  final Object? openError;
  void Function(NativeCameraFrame)? onFrame;
  void Function(Object)? onError;
  int closes = 0;

  @override
  Future<void> open() async {
    log.add('camera.open');
    await openGate?.future;
    if (openError != null) throw openError!;
  }

  @override
  Future<void> startFrames(
    void Function(NativeCameraFrame frame) onFrame,
    void Function(Object error) onError,
  ) async {
    log.add('camera.frames');
    this.onFrame = onFrame;
    this.onError = onError;
  }

  @override
  Future<void> close() async {
    closes++;
    log.add('camera.close');
  }
}

class FakeMicrophone implements NativeMicrophone {
  FakeMicrophone(this.log, {this.granted = true, this.permissionGate});

  final List<String> log;
  final bool granted;
  final Completer<void>? permissionGate;
  final pcm = StreamController<Uint8List>.broadcast();
  int closes = 0;

  @override
  Future<bool> requestPermission() async {
    log.add('mic.permission');
    await permissionGate?.future;
    return granted;
  }

  @override
  Future<Stream<Uint8List>> start() async {
    log.add('mic.start');
    return pcm.stream;
  }

  @override
  Future<void> close() async {
    closes++;
    log.add('mic.close');
  }
}

class FakePlayer implements NativePcmPlayer {
  FakePlayer(this.log);

  final List<String> log;
  final fed = <Uint8List>[];
  int? sampleRate;
  int interrupts = 0;
  int closes = 0;

  @override
  Future<void> open({required int sampleRate}) async {
    this.sampleRate = sampleRate;
    log.add('player.open');
  }

  @override
  void feed(Uint8List pcm) => fed.add(pcm);

  @override
  void interrupt() => interrupts++;

  @override
  Future<void> close() async {
    closes++;
    log.add('player.close');
  }
}

NativeCameraFrame rawFrame(int marker) => NativeCameraFrame(
  format: NativePixelFormat.bgra8888,
  width: 1,
  height: 1,
  planes: [
    NativePlane(bytes: Uint8List.fromList([marker, 0, 0, 255]), bytesPerRow: 4),
  ],
);

class Harness {
  Harness({
    this.cameraGate,
    this.cameraError,
    this.permissionGate,
    this.micGranted = true,
  }) {
    media = NativeLiveMedia(
      camera: () {
        final camera = FakeCamera(
          log,
          openGate: cameraGate,
          openError: cameraError,
        );
        cameras.add(camera);
        return camera;
      },
      microphone: () {
        final mic = FakeMicrophone(
          log,
          granted: micGranted,
          permissionGate: permissionGate,
        );
        microphones.add(mic);
        return mic;
      },
      player: () {
        final player = FakePlayer(log);
        players.add(player);
        return player;
      },
      encoder: (frame) {
        final gate = encodeGate;
        final marker = frame.planes.first.bytes.first;
        if (marker == 99) return Future.error(ArgumentError('bad frame'));
        final jpeg = Uint8List.fromList([marker]);
        return gate == null
            ? Future.value(jpeg)
            : gate.future.then((_) => jpeg);
      },
      clock: () => now,
    );
    media.frames.listen(frames.add);
    media.timedFrames.listen(timedFrames.add);
    media.microphone.listen(micChunks.add);
    media.errors.listen(errors.add);
  }

  final Completer<void>? cameraGate;
  final Object? cameraError;
  final Completer<void>? permissionGate;
  final bool micGranted;
  Completer<void>? encodeGate;

  final log = <String>[];
  final cameras = <FakeCamera>[];
  final microphones = <FakeMicrophone>[];
  final players = <FakePlayer>[];
  final frames = <Uint8List>[];
  final timedFrames = <CapturedFrame>[];
  final micChunks = <Uint8List>[];
  final errors = <String>[];
  DateTime now = DateTime.utc(2026, 11, 25, 12);
  late final NativeLiveMedia media;

  void advance(Duration by) => now = now.add(by);

  Future<void> push(int marker) async {
    cameras.last.onFrame!(rawFrame(marker));
    await pumpEventQueue();
  }
}

void main() {
  test('NativeLiveMedia is a LiveMedia', () {
    expect(Harness().media, isA<LiveMedia>());
  });

  group('start (Live coach)', () {
    test('opens camera, microphone and 24 kHz playback', () async {
      final h = Harness();
      await h.media.start();

      expect(h.log, [
        'camera.open',
        'mic.permission',
        'mic.start',
        'player.open',
        'camera.frames',
      ]);
      expect(h.players.single.sampleRate, 24000);
      expect(kNativeMicSampleRate, 16000);
      expect(h.media.isActive, isTrue);
      expect(h.media.isCameraOnly, isFalse);
    });

    test(
      'frames reach the coach and the timed stream with capture time',
      () async {
        final h = Harness();
        await h.media.start();
        final capturedAt = h.now;
        await h.push(7);

        expect(h.frames.single, [7]);
        expect(h.timedFrames.single.bytes, [7]);
        expect(h.timedFrames.single.capturedAt, capturedAt);
      },
    );

    test('microphone PCM is forwarded unless muted', () async {
      final h = Harness();
      await h.media.start();
      final mic = h.microphones.single;

      mic.pcm.add(Uint8List.fromList([1, 2]));
      await pumpEventQueue();
      h.media.setMicrophoneMuted(true);
      mic.pcm.add(Uint8List.fromList([3, 4]));
      await pumpEventQueue();
      h.media.setMicrophoneMuted(false);
      mic.pcm.add(Uint8List.fromList([5, 6]));
      await pumpEventQueue();

      expect(h.micChunks, [
        [1, 2],
        [5, 6],
      ]);
    });

    test('a new session starts unmuted', () async {
      final h = Harness();
      await h.media.start();
      h.media.setMicrophoneMuted(true);
      await h.media.stop();

      await h.media.start();
      h.microphones.last.pcm.add(Uint8List.fromList([9]));
      await pumpEventQueue();

      expect(h.micChunks, [
        [9],
      ]);
    });

    test('playback feeds the player and interrupt flushes it', () async {
      final h = Harness();
      await h.media.start();

      h.media.playAudio(Uint8List.fromList([1, 0, 2, 0]));
      h.media.playAudio(Uint8List(0));
      h.media.interruptPlayback();

      expect(h.players.single.fed, [
        [1, 0, 2, 0],
      ]);
      expect(h.players.single.interrupts, 1);
    });

    test('a denied microphone fails start and releases the camera', () async {
      final h = Harness(micGranted: false);

      await expectLater(
        h.media.start(),
        throwsA(
          isA<NativeLiveMediaException>().having(
            (e) => e.message,
            'message',
            contains('Microphone permission'),
          ),
        ),
      );
      expect(h.cameras.single.closes, 1);
      expect(h.microphones.single.closes, 1);
      expect(h.players, isEmpty);
      expect(h.media.isActive, isFalse);
    });

    test(
      'a denied camera gives a camera message and opens nothing else',
      () async {
        final h = Harness(
          cameraError: Exception('CameraAccessDenied: permission denied'),
        );

        await expectLater(
          h.media.start(),
          throwsA(
            isA<NativeLiveMediaException>().having(
              (e) => e.message,
              'message',
              contains('Camera permission'),
            ),
          ),
        );
        expect(h.microphones, isEmpty);
        expect(h.players, isEmpty);
        expect(h.cameras.single.closes, 1);
      },
    );
  });

  group('startCameraOnly (local watch)', () {
    test('never creates, asks for or opens the microphone or player', () async {
      final h = Harness();
      await h.media.startCameraOnly();

      expect(h.log, ['camera.open', 'camera.frames']);
      expect(h.microphones, isEmpty);
      expect(h.players, isEmpty);
      expect(h.media.isCameraOnly, isTrue);
    });

    test('frames go to timedFrames only, never to the coach', () async {
      final h = Harness();
      await h.media.startCameraOnly();
      await h.push(3);

      expect(h.frames, isEmpty);
      expect(h.timedFrames.single.bytes, [3]);
    });

    test('playback and mute are inert without an audio graph', () async {
      final h = Harness();
      await h.media.startCameraOnly();

      h.media.playAudio(Uint8List.fromList([1, 0]));
      h.media.interruptPlayback();
      h.media.setMicrophoneMuted(true);

      expect(h.players, isEmpty);
      expect(h.microphones, isEmpty);
    });
  });

  group('frame throttling', () {
    test('at most one frame per second', () async {
      final h = Harness();
      await h.media.startCameraOnly();

      await h.push(1); // t = 0: accepted
      h.advance(const Duration(milliseconds: 500));
      await h.push(2); // 0.5 s: dropped
      h.advance(const Duration(milliseconds: 500));
      await h.push(3); // 1.0 s: accepted
      h.advance(const Duration(milliseconds: 999));
      await h.push(4); // 1.999 s: dropped
      h.advance(const Duration(milliseconds: 1));
      await h.push(5); // 2.0 s: accepted

      expect(h.timedFrames.map((f) => f.bytes.single), [1, 3, 5]);
    });

    test('frames arriving while one is encoding are dropped', () async {
      final h = Harness();
      await h.media.startCameraOnly();
      h.encodeGate = Completer<void>();

      await h.push(1);
      h.advance(const Duration(seconds: 2));
      await h.push(2); // still encoding frame 1
      h.encodeGate!.complete();
      await pumpEventQueue();

      expect(h.timedFrames.map((f) => f.bytes.single), [1]);
    });

    test('a frame that fails to encode is skipped, not fatal', () async {
      final h = Harness();
      await h.media.start();

      await h.push(99);
      h.advance(const Duration(seconds: 1));
      await h.push(4);

      expect(h.frames.map((f) => f.single), [4]);
      expect(h.errors, isEmpty);
    });
  });

  group('stop and handoff', () {
    test('stop releases everything and silences all streams', () async {
      final h = Harness();
      await h.media.start();
      final camera = h.cameras.single;
      final mic = h.microphones.single;

      await h.media.stop();
      camera.onFrame!(rawFrame(1));
      mic.pcm.add(Uint8List.fromList([1]));
      camera.onError!('lost');
      h.media.playAudio(Uint8List.fromList([1, 0]));
      await pumpEventQueue();

      expect(camera.closes, 1);
      expect(mic.closes, 1);
      expect(h.players.single.closes, 1);
      expect(h.players.single.fed, isEmpty);
      expect(h.frames, isEmpty);
      expect(h.micChunks, isEmpty);
      expect(h.errors, isEmpty);
      expect(h.media.isActive, isFalse);
    });

    test(
      'stop while the camera is opening releases it and opens nothing else',
      () async {
        final gate = Completer<void>();
        final h = Harness(cameraGate: gate);
        final starting = h.media.start();
        await pumpEventQueue();

        await h.media.stop();
        gate.complete();
        await starting; // completes quietly; nobody is waiting for it

        expect(h.cameras.single.closes, greaterThanOrEqualTo(1));
        expect(h.microphones, isEmpty);
        expect(h.players, isEmpty);
        expect(h.log, isNot(contains('camera.frames')));
      },
    );

    test('stop during the microphone prompt never starts recording', () async {
      final gate = Completer<void>();
      final h = Harness(permissionGate: gate);
      final starting = h.media.start();
      await pumpEventQueue();

      await h.media.stop();
      gate.complete();
      await starting;

      expect(h.log, isNot(contains('mic.start')));
      expect(h.players, isEmpty);
      expect(h.microphones.single.closes, greaterThanOrEqualTo(1));
      expect(h.cameras.single.closes, greaterThanOrEqualTo(1));
    });

    test('a frame still encoding when capture stops is dropped', () async {
      final h = Harness();
      await h.media.start();
      h.encodeGate = Completer<void>();

      await h.push(1);
      await h.media.stop();
      h.encodeGate!.complete();
      await pumpEventQueue();

      expect(h.frames, isEmpty);
      expect(h.timedFrames, isEmpty);
    });

    test(
      'switching from Live to camera-only drops the mic and its frames',
      () async {
        final h = Harness();
        await h.media.start();
        final liveCamera = h.cameras.single;
        h.encodeGate = Completer<void>();
        await h.push(1); // Live frame mid-encode during the handoff

        await h.media.startCameraOnly();
        h.encodeGate!.complete();
        h.encodeGate = null;
        await pumpEventQueue();
        liveCamera.onFrame!(rawFrame(2)); // late frame from the old camera
        await pumpEventQueue();
        h.advance(const Duration(seconds: 1));
        await h.push(3);

        expect(liveCamera.closes, 1);
        expect(h.microphones.single.closes, 1);
        expect(h.players.single.closes, 1);
        expect(h.cameras, hasLength(2));
        expect(h.frames, isEmpty);
        expect(h.timedFrames.map((f) => f.bytes.single), [3]);
        expect(h.media.isCameraOnly, isTrue);
      },
    );

    test(
      'a camera failure after start is reported once per live session',
      () async {
        final h = Harness();
        await h.media.start();

        h.cameras.single.onError!('disconnected');
        await pumpEventQueue();

        expect(h.errors, ['The camera stopped. Please reconnect.']);
      },
    );

    test('dispose stops capture and closes the streams', () async {
      final h = Harness();
      await h.media.start();
      await h.media.dispose();

      expect(h.cameras.single.closes, 1);
      expect(h.media.isActive, isFalse);
    });
  });
}
