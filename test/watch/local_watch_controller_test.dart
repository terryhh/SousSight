import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/payload_digest.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/frame_digest.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/watch_verdict.dart';

import 'watch_fakes.dart';

final t0 = DateTime(2026, 11, 25, 18);

class Rig {
  Rig(
    this.async, {
    HybridDispatcher? dispatcher,
    this.consent,
    this.privacy,
    bool micDenied = false,
  }) : media = FakeMedia()..micDenied = micDenied,
       dispatcher = dispatcher ?? FakeHybridDispatcher() {
    capture = CaptureOwner(media);
    watch = LocalWatchController(
      dispatcher: this.dispatcher,
      capture: capture,
      consentGate: consent,
      privacy: privacy,
      now: () => now,
      checkInterval: const Duration(seconds: 5),
    );
  }

  final FakeAsync async;
  final FakeMedia media;
  final HybridDispatcher dispatcher;
  final FakeConsentGate? consent;
  final FakePrivacy? privacy;
  late final CaptureOwner capture;
  late final LocalWatchController watch;

  DateTime get now => t0.add(async.elapsed);

  FakeHybridDispatcher get fake => dispatcher as FakeHybridDispatcher;
  ManualDispatcher get manual => dispatcher as ManualDispatcher;

  String? begin({String session = 's1'}) {
    String? id;
    watch.start(step: stepA, sessionId: session).then((v) => id = v);
    async.flushMicrotasks();
    return id;
  }

  /// A frame acquired [age] ago.
  void frame({
    Duration age = Duration.zero,
    List<int> bytes = const [1, 2, 3],
  }) {
    media.emit(now.subtract(age), bytes);
    async.flushMicrotasks();
  }
}

void main() {
  test('checks a fresh frame on this device with the step cue and schema', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.fake.enqueue(verdictJson('not_yet', direction: 'more'));
      final id = rig.begin();
      expect(id, isNotNull);
      expect(rig.media.log, ['startCameraOnly']);
      expect(rig.watch.captureLabel, contains('microphone off'));
      rig.frame();
      expect(rig.fake.tasks, hasLength(1));
      final task = rig.fake.tasks.single;
      expect(task.feature, kLocalWatchFeature);
      expect(task.jsonSchema, kWatchSchema);
      expect(task.hasImage, isTrue);
      expect((task.parts.first as HybridText).text, contains(stepA.cue));
      async.flushMicrotasks();
      final verdict = rig.watch.verdict!;
      expect(verdict.state, WatchState.notYet);
      expect(verdict.direction, WatchDirection.more);
      expect(verdict.watchId, id);
      expect(verdict.stepId, 'a');
      expect(verdict.sessionId, 's1');
      expect(verdict.source, WatchVerdictSource.onDevice);
      expect(rig.watch.statusText, contains('keep going'));
      expect(rig.watch.isActive, isTrue);
    });
  });

  test('shows the cook each local frame and clears it when the watch stops', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.fake.enqueue(verdictJson('not_yet', direction: 'more'));
      rig.begin();
      expect(rig.watch.previewFrame, isNull);
      rig.frame(bytes: const [9, 8, 7]);
      expect(rig.watch.previewFrame, [9, 8, 7]);
      rig.watch.stop();
      async.flushMicrotasks();
      expect(rig.watch.previewFrame, isNull);
    });
  });

  test('a frame acquired 2 s or more ago is skipped', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.begin();
      rig.frame(age: const Duration(seconds: 2));
      expect(rig.fake.tasks, isEmpty);
      // The periodic check also refuses it once it is older still.
      async.elapse(const Duration(seconds: 5));
      expect(rig.fake.tasks, isEmpty);
      expect(rig.watch.staleFramesSkipped, greaterThanOrEqualTo(2));
      // A fresh frame is used.
      rig.fake.enqueue(verdictJson('not_yet'));
      rig.frame(age: const Duration(milliseconds: 1999));
      expect(rig.fake.tasks, hasLength(1));
    });
  });

  test('single flight: no new check starts while one is running', () {
    fakeAsync((async) {
      final rig = Rig(async, dispatcher: ManualDispatcher());
      rig.begin();
      rig.frame();
      expect(rig.manual.tasks, hasLength(1));
      for (var i = 0; i < 4; i++) {
        async.elapse(const Duration(seconds: 5));
        rig.frame();
        rig.watch.checkNow();
        async.flushMicrotasks();
      }
      expect(rig.manual.tasks, hasLength(1));
      expect(rig.watch.isChecking, isTrue);
      rig.manual.answer(0, verdictJson('not_yet'));
      async.flushMicrotasks();
      expect(rig.watch.isChecking, isFalse);
      async.elapse(const Duration(seconds: 5));
      rig.frame();
      rig.watch.checkNow();
      async.flushMicrotasks();
      expect(rig.manual.tasks, hasLength(2));
    });
  });

  for (final trigger in [
    'stop',
    'step change',
    'session change',
    'backgrounding',
    'Live connect',
    '3-minute limit',
  ]) {
    test(
      '$trigger cancels the running check, releases the camera and drops its late verdict',
      () {
        fakeAsync((async) {
          final rig = Rig(async, dispatcher: ManualDispatcher());
          rig.begin();
          rig.frame();
          expect(rig.manual.tasks, hasLength(1));
          switch (trigger) {
            case 'stop':
              rig.watch.stop();
            case 'step change':
              rig.watch.onStepChanged('b');
            case 'session change':
              rig.watch.onSessionChanged('s2');
            case 'backgrounding':
              rig.watch.onBackgrounded();
            case 'Live connect':
              rig.watch.onLiveConnecting();
            case '3-minute limit':
              async.elapse(const Duration(minutes: 3));
          }
          async.flushMicrotasks();
          expect(rig.manual.cancelled, [0]);
          expect(rig.watch.isActive, isFalse);
          expect(rig.capture.mode, CaptureMode.off);
          expect(rig.media.log.last, 'stop');
          // The platform could only abandon the request: its answer still
          // arrives, and is dropped.
          rig.manual.answer(0, verdictJson('ready'));
          async.flushMicrotasks();
          expect(rig.watch.verdict, isNull);
          if (trigger == '3-minute limit') {
            expect(rig.watch.notice, contains('3 minutes'));
          }
        });
      },
    );
  }

  test('the same step does not cancel the watch', () {
    fakeAsync((async) {
      final rig = Rig(async, dispatcher: ManualDispatcher());
      rig.begin();
      rig.watch.onStepChanged('a');
      rig.watch.onSessionChanged('s1');
      async.flushMicrotasks();
      expect(rig.watch.isActive, isTrue);
    });
  });

  test('a verdict from a previous watch is dropped even with the same step and session', () {
    fakeAsync((async) {
      final rig = Rig(async, dispatcher: ManualDispatcher());
      final first = rig.begin();
      rig.frame();
      final second = rig.begin();
      expect(second, isNot(first));
      rig.manual.answer(0, verdictJson('ready'));
      async.flushMicrotasks();
      expect(rig.watch.verdict, isNull);
      expect(rig.watch.isActive, isTrue);
      expect(rig.watch.watchId, second);
    });
  });

  test('isCurrent rejects a verdict whose watch, step or session differs', () {
    fakeAsync((async) {
      final rig = Rig(async);
      final id = rig.begin()!;
      WatchVerdict make({
        String? watch,
        String step = 'a',
        String session = 's1',
      }) => WatchVerdict(
        state: WatchState.ready,
        direction: WatchDirection.none,
        whatISee: '',
        watchId: watch ?? id,
        stepId: step,
        sessionId: session,
        frameCapturedAt: t0,
        source: WatchVerdictSource.onDevice,
      );
      expect(rig.watch.isCurrent(make()), isTrue);
      expect(rig.watch.isCurrent(make(watch: 'other')), isFalse);
      expect(rig.watch.isCurrent(make(step: 'b')), isFalse);
      expect(rig.watch.isCurrent(make(session: 's2')), isFalse);
    });
  });

  test('ready says what it sees, defers to the cook and frees the camera', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.fake.enqueue(
        verdictJson('ready', see: 'Golden edges on soft onions.'),
      );
      rig.begin();
      rig.frame();
      async.flushMicrotasks();
      expect(rig.watch.verdict!.state, WatchState.ready);
      expect(rig.watch.isActive, isFalse);
      expect(rig.capture.mode, CaptureMode.off);
      final text = rig.watch.statusText!;
      expect(text, contains('Golden edges on soft onions.'));
      expect(text, contains('Have a look yourself'));
      expect(text, contains('can\'t check temperature or food safety'));
    });
  });

  test('an incomplete ready answer does not end the watch', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.fake.enqueue('{"state":"ready"}');
      rig.begin();
      rig.frame();
      async.flushMicrotasks();
      expect(rig.watch.verdict!.state, WatchState.unsure);
      expect(rig.watch.isActive, isTrue);
      expect(rig.capture.mode, CaptureMode.localCamera);
    });
  });

  test(
    'a finished ready verdict is forgotten when the step or session moves on',
    () {
      for (final change in ['step', 'session']) {
        fakeAsync((async) {
          final rig = Rig(async);
          rig.fake.enqueue(verdictJson('ready', see: 'Golden edges.'));
          rig.begin();
          rig.frame();
          async.flushMicrotasks();
          expect(rig.watch.isActive, isFalse);
          expect(rig.watch.statusText, contains('cue for this step'));
          // Same step and session: the cook still sees it.
          rig.watch.onStepChanged('a');
          rig.watch.onSessionChanged('s1');
          expect(rig.watch.verdict, isNotNull);
          if (change == 'step') {
            rig.watch.onStepChanged('b');
          } else {
            rig.watch.onSessionChanged('s2');
          }
          expect(rig.watch.verdict, isNull, reason: change);
          expect(rig.watch.statusText, isNull, reason: change);
        });
      }
    },
  );

  test('a blocked local route stops the watch with a reason and sends nothing else', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.fake.enqueueBlocked(RouteReason.noLocalModel);
      rig.begin();
      rig.frame();
      async.flushMicrotasks();
      expect(rig.watch.isActive, isFalse);
      expect(rig.watch.notice, contains('Live coach'));
      expect(rig.fake.tasks, hasLength(1));
    });
  });

  test('mic denied with camera granted: the camera-only watch still runs', () {
    fakeAsync((async) {
      final rig = Rig(async, micDenied: true);
      rig.fake.enqueue(verdictJson('not_yet'));
      expect(rig.begin(), isNotNull);
      rig.frame();
      async.flushMicrotasks();
      expect(rig.media.log, isNot(contains('start')));
      expect(rig.watch.verdict!.state, WatchState.notYet);
    });
  });

  test('a camera that cannot start reports why', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.media.cameraDenied = true;
      expect(rig.begin(), isNull);
      expect(rig.watch.isActive, isFalse);
      expect(rig.watch.notice, contains('camera could not start'));
    });
  });

  group('unsure', () {
    test('asks for a better view and keeps watching on this device', () {
      fakeAsync((async) {
        final rig = Rig(async, consent: FakeConsentGate());
        rig.fake.enqueue(verdictJson('unsure', see: 'Steam covers the pan.'));
        rig.begin();
        rig.frame();
        async.flushMicrotasks();
        expect(rig.watch.verdict!.state, WatchState.unsure);
        expect(rig.watch.statusText, contains('Move the camera closer'));
        expect(rig.watch.isActive, isTrue);
        expect(rig.watch.canRequestCloudCheck, isTrue);
      });
    });

    test('malformed model output is treated as unsure', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.fake.enqueue('Looks done to me!');
        rig.begin();
        rig.frame();
        async.flushMicrotasks();
        expect(rig.watch.verdict!.state, WatchState.unsure);
        expect(rig.watch.canRequestCloudCheck, isFalse); // no consent gate
      });
    });

    Rig unsureRig(FakeAsync async, {FakePrivacy? privacy}) {
      final rig = Rig(async, consent: FakeConsentGate(), privacy: privacy);
      rig.fake.enqueue(verdictJson('unsure'));
      rig.begin();
      rig.frame(bytes: [9, 9, 9]);
      async.flushMicrotasks();
      return rig;
    }

    test('one frame goes to the cloud only with a grant for its digest', () {
      fakeAsync((async) {
        final rig = unsureRig(async);
        rig.frame(bytes: [4, 5, 6]);
        WatchVerdict? cloud;
        rig.watch.requestCloudCheck().then((v) => cloud = v);
        async.flushMicrotasks();
        final ask = rig.consent!.asks.single;
        expect(ask.feature, kWatchCloudCheckFeature);
        expect(ask.sessionId, 's1');
        expect(ask.kinds, {DataKind.image, DataKind.text});
        expect(ask.payloadDigest, isNotEmpty);
        expect(rig.watch.consentFrame!.bytes, [4, 5, 6]);
        expect(rig.watch.statusText, contains('Waiting for your OK'));
        // No local check runs while the prompt is open.
        async.elapse(const Duration(seconds: 10));
        expect(rig.fake.tasks, hasLength(1));
        rig.fake.enqueue(
          verdictJson('not_yet', direction: 'more'),
          provenance: Provenance.sdkCloud,
        );
        rig.consent!.grant();
        async.flushMicrotasks();
        expect(rig.fake.tasks, hasLength(2));
        final sent = rig.fake.tasks.last;
        expect(sent.feature, kWatchCloudCheckFeature);
        final image = sent.parts.whereType<HybridInlineData>().single;
        expect(image.bytes, [4, 5, 6]);
        // The digest is the dispatcher's own, and the grant travels with
        // the send so the dispatcher does not prompt again.
        expect(hybridPayloadDigest(sent), ask.payloadDigest);
        expect(rig.fake.grants.last?.ask, same(ask));
        expect(cloud!.source, WatchVerdictSource.cloud);
        expect(cloud!.message, contains('cloud check of one photo'));
      });
    });

    test('a grant for a different frame sends nothing', () {
      fakeAsync((async) {
        final rig = unsureRig(async);
        rig.frame(bytes: [4, 5, 6]);
        rig.watch.requestCloudCheck();
        async.flushMicrotasks();
        final ask = rig.consent!.asks.single;
        rig.consent!.grantFor(
          ConsentAsk(
            feature: ask.feature,
            kinds: ask.kinds,
            payloadDigest: frameDigest(Uint8List.fromList([7, 7, 7])),
            sessionId: ask.sessionId,
          ),
        );
        async.flushMicrotasks();
        expect(rig.fake.tasks, hasLength(1));
        expect(rig.watch.notice, contains('different photo'));
      });
    });

    test('declining keeps the photo on this device', () {
      fakeAsync((async) {
        final rig = unsureRig(async);
        rig.frame();
        rig.watch.requestCloudCheck();
        async.flushMicrotasks();
        rig.consent!.decline();
        async.flushMicrotasks();
        expect(rig.fake.tasks, hasLength(1));
        expect(rig.watch.notice, contains('stays on this device'));
        expect(rig.watch.isActive, isTrue);
      });
    });

    test('Stop while the consent prompt is open sends nothing', () {
      fakeAsync((async) {
        final rig = unsureRig(async);
        rig.frame();
        rig.watch.requestCloudCheck();
        async.flushMicrotasks();
        rig.watch.stop();
        async.flushMicrotasks();
        rig.consent!.grant();
        async.flushMicrotasks();
        expect(rig.fake.tasks, hasLength(1));
        expect(rig.capture.mode, CaptureMode.off);
      });
    });

    test(
      'a privacy change to local-only while the prompt is open sends nothing',
      () {
        fakeAsync((async) {
          final privacy = FakePrivacy();
          final rig = unsureRig(async, privacy: privacy);
          rig.frame();
          rig.watch.requestCloudCheck();
          async.flushMicrotasks();
          privacy.local = true;
          rig.consent!.grant();
          async.flushMicrotasks();
          expect(rig.fake.tasks, hasLength(1));
          expect(rig.watch.notice, contains('privacy setting'));
        });
      },
    );

    test(
      'the watch feature\'s own local-only setting blocks the cloud check',
      () {
        fakeAsync((async) {
          final privacy = FakePrivacy()..localFeatures.add(kLocalWatchFeature);
          final rig = unsureRig(async, privacy: privacy);
          rig.frame();
          rig.watch.requestCloudCheck();
          async.flushMicrotasks();
          expect(rig.consent!.asks, isEmpty);
          expect(rig.fake.tasks, hasLength(1));
          expect(rig.watch.notice, contains('privacy setting'));
        });
      },
    );

    test('turning on the watch\'s local-only setting during the prompt sends nothing', () {
      fakeAsync((async) {
        final privacy = FakePrivacy();
        final rig = unsureRig(async, privacy: privacy);
        rig.frame();
        rig.watch.requestCloudCheck();
        async.flushMicrotasks();
        privacy.localFeatures.add(kLocalWatchFeature);
        rig.consent!.grant();
        async.flushMicrotasks();
        expect(rig.fake.tasks, hasLength(1));
        expect(rig.watch.notice, contains('privacy setting'));
      });
    });

    test('local-only privacy never asks', () {
      fakeAsync((async) {
        final privacy = FakePrivacy()..local = true;
        final rig = unsureRig(async, privacy: privacy);
        rig.frame();
        rig.watch.requestCloudCheck();
        async.flushMicrotasks();
        expect(rig.consent!.asks, isEmpty);
      });
    });

    test('a stale frame is never offered for a cloud check', () {
      fakeAsync((async) {
        final rig = unsureRig(async);
        async.elapse(const Duration(seconds: 3));
        rig.watch.requestCloudCheck();
        async.flushMicrotasks();
        expect(rig.consent!.asks, isEmpty);
        expect(rig.watch.notice, contains('Hold the camera'));
      });
    });
  });
}
