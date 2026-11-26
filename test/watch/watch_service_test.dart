import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/watch_service.dart';

import 'watch_fakes.dart';

class ServiceRig {
  ServiceRig({bool localVision = true, Future<bool>? vision}) {
    capture = CaptureOwner(media);
    local = LocalWatchController(dispatcher: dispatcher, capture: capture);
    service = WatchService(
      local: local,
      startLiveWatch: (goal) {
        liveGoals.add(goal);
        return 'live-watch-1';
      },
      stopLiveWatch: () => liveStops++,
      localVisionSupported: () => vision ?? localVision,
    );
  }
  final media = FakeMedia()..micDenied = true;
  final dispatcher = FakeHybridDispatcher();
  late final CaptureOwner capture;
  late final LocalWatchController local;
  late final WatchService service;
  final liveGoals = <String>[];
  int liveStops = 0;
}

void main() {
  test('without Live it starts a local watch and says so', () {
    fakeAsync((async) {
      final rig = ServiceRig();
      WatchStart? start;
      rig.service
          .startWatch(step: stepA, sessionId: 's1', liveActive: false)
          .then((v) => start = v);
      async.flushMicrotasks();
      expect(start!.route, WatchRoute.local);
      expect(start!.started, isTrue);
      expect(start!.message, contains('on this device'));
      expect(rig.service.activeRoute, WatchRoute.local);
      expect(rig.liveGoals, isEmpty);
      // The capture line must never read "Camera and microphone off" now.
      expect(
        rig.service.captureLabel,
        'Camera on for an on-device watch · microphone off',
      );
      expect(rig.service.statusText, contains(stepA.cue));
      rig.service.stopWatch();
      async.flushMicrotasks();
      expect(rig.service.captureLabel, isNull);
      expect(rig.capture.mode, CaptureMode.off);
    });
  });

  test('with Live active it uses the Live watch, labelled as cloud', () {
    fakeAsync((async) {
      final rig = ServiceRig();
      WatchStart? start;
      rig.service
          .startWatch(step: stepA, sessionId: 's1', liveActive: true)
          .then((v) => start = v);
      async.flushMicrotasks();
      expect(start!.route, WatchRoute.live);
      expect(start!.watchId, 'live-watch-1');
      expect(start!.message, contains('cloud'));
      expect(rig.liveGoals, [stepA.cue]);
      expect(rig.media.log, isEmpty);
      expect(rig.service.statusText, contains("online to Google's AI"));
      rig.service.stopWatch();
      async.flushMicrotasks();
      expect(rig.liveStops, 1);
    });
  });

  test('where the local model cannot see images it offers the Live watch', () {
    fakeAsync((async) {
      final rig = ServiceRig(localVision: false);
      WatchStart? start;
      rig.service
          .startWatch(step: stepA, sessionId: 's1', liveActive: false)
          .then((v) => start = v);
      async.flushMicrotasks();
      expect(start!.started, isFalse);
      expect(start!.message, contains('Live coach'));
      expect(start!.message, contains('cloud'));
      expect(rig.media.log, isEmpty);
    });
  });

  test('Live connecting cancels the local watch and hands capture to Live', () {
    fakeAsync((async) {
      final rig = ServiceRig();
      rig.dispatcher.delay = const Duration(seconds: 3);
      rig.dispatcher.enqueue(verdictJson('ready'));
      rig.service.startWatch(step: stepA, sessionId: 's1', liveActive: false);
      async.flushMicrotasks();
      rig.media.emit(DateTime.now());
      async.flushMicrotasks();
      expect(rig.dispatcher.tasks, hasLength(1));
      rig.service.onLiveConnecting();
      async.flushMicrotasks();
      expect(rig.dispatcher.cancelledOperations, ['op-1']);
      expect(rig.capture.mode, CaptureMode.liveAv);
      async.elapse(const Duration(seconds: 3));
      expect(rig.local.verdict, isNull);
      rig.service.onLiveStopped();
      expect(rig.capture.mode, CaptureMode.off);
    });
  });

  test('a model-initiated Live watch takes over from a local one', () {
    fakeAsync((async) {
      final rig = ServiceRig();
      rig.service.startWatch(step: stepA, sessionId: 's1', liveActive: false);
      async.flushMicrotasks();
      rig.service.liveWatchStarted('watch-2-1');
      async.flushMicrotasks();
      expect(rig.service.activeRoute, WatchRoute.live);
      expect(rig.local.isActive, isFalse);
    });
  });

  for (final cancel in [
    'Stop',
    'backgrounding',
    'step change',
    'session change',
    'Live takeover',
  ]) {
    test('$cancel during a pending startup never opens the camera', () {
      fakeAsync((async) {
        final vision = Completer<bool>();
        final rig = ServiceRig(vision: vision.future);
        WatchStart? start;
        rig.service
            .startWatch(step: stepA, sessionId: 's1', liveActive: false)
            .then((v) => start = v);
        async.flushMicrotasks();
        switch (cancel) {
          case 'Stop':
            rig.service.stopWatch();
          case 'backgrounding':
            rig.service.onBackgrounded();
          case 'step change':
            rig.service.onStepChanged('b');
          case 'session change':
            rig.service.onSessionChanged('s2');
          case 'Live takeover':
            rig.service.onLiveConnecting();
        }
        async.flushMicrotasks();
        vision.complete(true);
        async.flushMicrotasks();
        expect(start!.started, isFalse);
        expect(rig.media.log, isNot(contains('startCameraOnly')));
        expect(rig.local.isActive, isFalse);
        expect(rig.service.captureLabel, isNull);
      });
    });
  }

  test('a context change for the same step keeps a pending startup', () {
    fakeAsync((async) {
      final vision = Completer<bool>();
      final rig = ServiceRig(vision: vision.future);
      WatchStart? start;
      rig.service
          .startWatch(step: stepA, sessionId: 's1', liveActive: false)
          .then((v) => start = v);
      async.flushMicrotasks();
      rig.service.onStepChanged('a');
      rig.service.onSessionChanged('s1');
      vision.complete(true);
      async.flushMicrotasks();
      expect(start!.started, isTrue);
      expect(rig.local.isActive, isTrue);
    });
  });

  test('Stop while the camera permission is pending leaves no watch', () {
    fakeAsync((async) {
      final rig = ServiceRig();
      rig.media.cameraGate = Completer<void>();
      WatchStart? start;
      rig.service
          .startWatch(step: stepA, sessionId: 's1', liveActive: false)
          .then((v) => start = v);
      async.flushMicrotasks();
      rig.service.stopWatch();
      async.flushMicrotasks();
      rig.media.cameraGate!.complete();
      async.flushMicrotasks();
      expect(start!.started, isFalse);
      expect(rig.local.isActive, isFalse);
      expect(rig.capture.mode, CaptureMode.off);
    });
  });

  test('after a ready verdict and a step change no stale status remains', () {
    fakeAsync((async) {
      final rig = ServiceRig();
      rig.dispatcher.enqueue(verdictJson('ready'));
      rig.service.startWatch(step: stepA, sessionId: 's1', liveActive: false);
      async.flushMicrotasks();
      rig.media.emit(DateTime.now());
      async.flushMicrotasks();
      expect(rig.service.statusText, contains('cue for this step'));
      rig.service.onStepChanged('b');
      expect(rig.service.statusText, isNull);
    });
  });
}
