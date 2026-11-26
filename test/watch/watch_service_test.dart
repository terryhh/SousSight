import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/watch_service.dart';

import 'watch_fakes.dart';

class ServiceRig {
  ServiceRig({bool localVision = true}) {
    capture = CaptureOwner(media);
    local = LocalWatchController(dispatcher: dispatcher, capture: capture);
    service = WatchService(
      local: local,
      startLiveWatch: (goal) {
        liveGoals.add(goal);
        return 'live-watch-1';
      },
      stopLiveWatch: () => liveStops++,
      localVisionSupported: () => localVision,
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
      expect(rig.service.statusText, contains('cloud'));
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
}
