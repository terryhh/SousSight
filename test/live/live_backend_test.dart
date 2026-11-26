import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/data/live_session.dart';
import 'package:soussight/learner/cooking_app.dart' show ledgeredLiveFactory;
import 'package:soussight/live/live_backend.dart';
import 'package:soussight/live/live_controller.dart';
import 'package:soussight/live/live_tools.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/trust/privacy_preferences.dart';

/// Stands in for firebase_ai's LiveSession; records what the transport does.
class FakeLiveSession implements LiveSession {
  FakeLiveSession(this.log);
  final List<String> log;
  // Single-subscription: buffers until the transport listens.
  final server = StreamController<LiveServerResponse>();
  final resumedWith = <String?>[];
  bool closed = false;

  void emit(LiveServerMessage message) =>
      server.add(LiveServerResponse(message: message));

  @override
  Stream<LiveServerResponse> receive() => server.stream;

  @override
  Future<void> resumeSession({
    SessionResumptionConfig? sessionResumption,
  }) async {
    log.add('resume');
    resumedWith.add(sessionResumption?.handle);
  }

  @override
  Future<void> close() async {
    closed = true;
    log.add('close');
  }

  @override
  Future<void> sendVideoRealtime(InlineDataPart video) async {}
  @override
  Future<void> sendAudioRealtime(InlineDataPart audio) async {}
  @override
  Future<void> send({Content? input, bool turnComplete = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Harness {
  Harness({
    String routes = 'live',
    this.reservation = const LiveSessionGranted(model: kLiveModel),
    Set<String> localOnly = const {},
  }) : privacy = InMemoryPrivacyPreferences(localOnly),
       cloudRoutes = CloudRoutes.parse(routes);

  final log = <String>[];
  final legs = <(String, Set<DataKind>)>[];
  final sessions = <FakeLiveSession>[];
  final InMemoryPrivacyPreferences privacy;
  final CloudRoutes cloudRoutes;
  LiveSessionReservation reservation;
  Completer<void>? reservationGate;
  int reservations = 0;

  Future<LiveSessionReservation> reserve() async {
    reservations++;
    log.add('reserve');
    await reservationGate?.future;
    return reservation;
  }

  void record(String feature, Set<DataKind> kinds) {
    log.add('leg');
    legs.add((feature, kinds));
  }

  Future<LiveSession> open({
    required String model,
    required String systemInstruction,
  }) async {
    log.add('open:$model');
    final session = FakeLiveSession(log);
    sessions.add(session);
    // The first server message completes setup.
    scheduleMicrotask(
      () => session.emit(
        SessionResumptionUpdate(newHandle: 'h1', resumable: true),
      ),
    );
    return session;
  }

  LiveTransportFactory? factory({LiveLegRecorder? recorder}) =>
      aiLogicLiveTransportFactory(
        cloudRoutes: cloudRoutes,
        privacy: privacy,
        reserveSession: reserve,
        recordCloudLeg: recorder ?? record,
        openSession: open,
      );
}

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Media implements LiveMedia {
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  Stream<CapturedFrame> get timedFrames => const Stream.empty();
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> startCameraOnly() async {}
  @override
  Future<void> stop() async {}
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void playAudio(Uint8List pcm24khz) {}
  @override
  void interruptPlayback() {}
}

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) async =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

void main() {
  group('LIVE_BACKEND factory', () {
    test('tests compile with no Live backend, so no transport is built', () {
      expect(configuredLiveBackend, LiveBackend.none);
      expect(liveTransportFactory(isDemo: false), isNull);
      expect(
        liveTransportFactory(
          isDemo: false,
          cloudRoutes: CloudRoutes.parse('live'),
        ),
        isNull,
      );
    });

    test('aiLogic without the live cloud route has no Live coach', () {
      expect(Harness(routes: '').factory(), isNull);
      expect(Harness(routes: 'research,hybridFallback').factory(), isNull);
      expect(Harness().factory(), isNotNull);
    });

    test('client and functions pin the same Live model by default', () {
      // functions/src/live-token.js LIVE_MODEL; functions tests assert it too.
      expect(kLiveModel, 'gemini-3.1-flash-live-preview');
    });
  });

  group('aiLogic connect', () {
    test('reserves, then writes the leg, then opens the socket', () async {
      final h = Harness();
      final transport = h.factory()!();
      await transport.connect(systemInstruction: 'cook');
      expect(h.log, ['reserve', 'leg', 'open:$kLiveModel']);
      expect(h.legs.single.$1, 'live');
      expect(h.legs.single.$2, {DataKind.audio, DataKind.image, DataKind.text});
      await transport.close();
    });

    test('a denied reservation opens nothing and explains why', () async {
      final h = Harness(
        reservation: const LiveSessionDenied(
          LiveSessionDenial.rateLimited,
          retryAfter: Duration(seconds: 2),
        ),
      );
      final transport = h.factory()!();
      await expectLater(
        transport.connect(systemInstruction: 'cook'),
        throwsA(
          isA<LiveUnavailable>()
              .having((e) => e.message, 'message', contains('2 seconds'))
              .having((e) => e.message, 'message', contains('Coach Lite'))
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 2),
              ),
        ),
      );
      expect(h.log, ['reserve']);
      expect(h.legs, isEmpty);
      expect(h.sessions, isEmpty);
    });

    test('a reserver that throws is a denial, not a connect', () async {
      final h = Harness();
      final transport = aiLogicLiveTransportFactory(
        cloudRoutes: h.cloudRoutes,
        reserveSession: () async => throw StateError('network'),
        recordCloudLeg: h.record,
        openSession: h.open,
      )!();
      await expectLater(
        transport.connect(systemInstruction: 'cook'),
        throwsA(isA<LiveUnavailable>()),
      );
      expect(h.sessions, isEmpty);
      expect(h.legs, isEmpty);
    });

    test(
      'local-only Live blocks before the reservation is even asked',
      () async {
        final h = Harness(localOnly: {'live'});
        final transport = h.factory()!();
        await expectLater(
          transport.connect(systemInstruction: 'cook'),
          throwsA(
            isA<LiveUnavailable>().having(
              (e) => e.message,
              'message',
              contains('Coach Lite'),
            ),
          ),
        );
        expect(h.reservations, 0);
        expect(h.sessions, isEmpty);
      },
    );

    test('the route is re-read after the reservation returns', () async {
      final h = Harness()..reservationGate = Completer<void>();
      final transport = h.factory()!();
      final connecting = transport.connect(systemInstruction: 'cook');
      await _flush();
      // The cook switches Live to local-only while the reservation is out.
      h.privacy.setLocalOnly('live', true);
      h.reservationGate!.complete();
      await expectLater(connecting, throwsA(isA<LiveUnavailable>()));
      expect(h.legs, isEmpty);
      expect(h.sessions, isEmpty);
    });

    test(
      'closing during the reservation opens no socket and writes no leg',
      () async {
        final h = Harness()..reservationGate = Completer<void>();
        final transport = h.factory()!();
        final connecting = transport.connect(systemInstruction: 'cook');
        await _flush();
        await transport.close();
        h.reservationGate!.complete();
        await connecting;
        expect(h.log, ['reserve']);
        expect(h.sessions, isEmpty);
      },
    );
  });

  group('aiLogic resume', () {
    test('each resume writes a leg and never reserves again', () async {
      final h = Harness();
      final transport = h.factory()!();
      await transport.connect(systemInstruction: 'cook');
      final session = h.sessions.single;

      session.emit(const GoingAwayNotice());
      await _flush();
      session.emit(SessionResumptionUpdate(newHandle: 'h2', resumable: true));
      await _flush();
      session.emit(const GoingAwayNotice());
      await _flush();

      expect(h.reservations, 1);
      expect(h.legs.length, 3, reason: 'one connect + two resumes');
      expect(session.resumedWith, ['h1', 'h2']);
      expect(h.log, [
        'reserve',
        'leg',
        'open:$kLiveModel',
        'leg',
        'resume',
        'leg',
        'resume',
      ]);
      await transport.close();
    });

    test('a resume after Live became local-only is refused', () async {
      final h = Harness();
      final transport = h.factory()!();
      final errors = <Object>[];
      transport.events.listen((_) {}, onError: errors.add);
      await transport.connect(systemInstruction: 'cook');
      h.privacy.setLocalOnly('live', true);
      h.sessions.single.emit(const GoingAwayNotice());
      await _flush();
      expect(h.sessions.single.resumedWith, isEmpty);
      expect(h.legs.length, 1);
      expect(errors.single.toString(), contains('Coach Lite'));
      await transport.close();
    });
  });

  group('through the controller and the session ledger', () {
    test('each Start reserves once and writes cloudAdapter legs', () async {
      final runtime = HybridRuntime.create(
        inference: FakeHybridInference(),
        cloudRoutes: CloudRoutes.parse('live'),
        cloudFallback: _NoCloud(),
        isOnline: () => true,
        cloudModel: 'test-cloud-model',
      );
      final h = Harness();
      final controller = LiveCookingController(
        // The app's path: the guard opens each leg, the wrapper settles it.
        transportFactory: ledgeredLiveFactory(
          isDemo: false,
          hybrid: runtime,
          selfRecording: true,
          build: (record) => h.factory(recorder: record),
        )!,
        media: _Media(),
        onToolCall: (_) async => const {},
      );
      await controller.start(cookingContext: 'Mash potatoes');
      expect(controller.status, LiveCookingStatus.listening);
      h.sessions.single.emit(const GoingAwayNotice());
      await _flush();
      await controller.stop();
      await controller.start(cookingContext: 'Mash potatoes');

      expect(h.reservations, 2, reason: 'one per Start, none for the resume');
      final legs = runtime.ledger.legs;
      expect(legs.length, 3);
      for (final leg in legs) {
        expect(leg.feature, 'live');
        expect(leg.provenance, Provenance.cloudAdapter);
        expect(leg.transferPermitted, isTrue);
        expect(leg.kinds, {DataKind.audio, DataKind.image, DataKind.text});
      }
      await controller.stop();
      controller.dispose();
    });

    test(
      'a denied Start never connects and leaves the coach stopped',
      () async {
        final h = Harness(
          reservation: const LiveSessionDenied(LiveSessionDenial.unverified),
        );
        final controller = LiveCookingController(
          transportFactory: h.factory()!,
          media: _Media(),
          onToolCall: (_) async => const {},
        );
        await controller.start(cookingContext: 'Mash potatoes');
        expect(controller.status, LiveCookingStatus.error);
        expect(controller.isActive, isFalse);
        expect(h.sessions, isEmpty);
        expect(h.legs, isEmpty);
        controller.dispose();
      },
    );
  });
}
