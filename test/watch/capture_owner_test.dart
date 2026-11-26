import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/watch/capture_owner.dart';

import 'watch_fakes.dart';

void main() {
  test(
    'local camera uses the camera-only path and works with the mic denied',
    () async {
      final media = FakeMedia()..micDenied = true;
      final owner = CaptureOwner(media);
      final lease = await owner.acquireLocalCamera();
      expect(lease, isNotNull);
      expect(owner.mode, CaptureMode.localCamera);
      expect(media.log, ['startCameraOnly']);
      // The same media's audio/video path is denied.
      await expectLater(owner.acquireLiveAv(), throwsStateError);
      expect(owner.mode, CaptureMode.off);
    },
  );

  test(
    'every transition releases the previous capture before starting',
    () async {
      final media = FakeMedia();
      final owner = CaptureOwner(media);
      final local = await owner.acquireLocalCamera();
      final live = await owner.acquireLiveAv();
      expect(media.log, ['startCameraOnly', 'stop', 'start']);
      expect(owner.mode, CaptureMode.liveAv);
      expect(owner.isCurrent(local!), isFalse);
      expect(owner.isCurrent(live!), isTrue);
      await owner.release();
      expect(owner.mode, CaptureMode.off);
      expect(media.log.last, 'stop');
    },
  );

  test('a late camera grant after a handoff to Live never becomes current or publishes', () async {
    final media = FakeMedia()..cameraGate = Completer<void>();
    final owner = CaptureOwner(media);
    final late = owner.acquireLocalCamera();
    expect(owner.pending, CaptureMode.localCamera);
    await owner.handOffToLive();
    expect(owner.mode, CaptureMode.liveAv);
    // The pending start was stopped by the handoff.
    expect(media.log, ['startCameraOnly', 'stop']);
    media.cameraGate!.complete();
    expect(await late, isNull);
    expect(owner.mode, CaptureMode.liveAv);
    // The superseded acquisition did not stop Live's capture.
    expect(media.log, ['startCameraOnly', 'stop']);
  });

  test('frames for a lease stop as soon as the lease is superseded', () async {
    final media = FakeMedia();
    final owner = CaptureOwner(media);
    final lease = await owner.acquireLocalCamera();
    final seen = <DateTime>[];
    final sub = owner.framesFor(lease!).listen((f) => seen.add(f.capturedAt));
    final t0 = DateTime(2026, 11, 25, 12);
    media.emit(t0);
    await Future<void>.delayed(Duration.zero);
    await owner.handOffToLive();
    media.emit(t0.add(const Duration(seconds: 1)));
    await Future<void>.delayed(Duration.zero);
    expect(seen, [t0]);
    await sub.cancel();
  });

  test(
    'Live releasing capture on its own does not clobber a newer owner',
    () async {
      final media = FakeMedia();
      final owner = CaptureOwner(media);
      await owner.handOffToLive();
      expect(owner.mode, CaptureMode.liveAv);
      owner.liveReleased();
      expect(owner.mode, CaptureMode.off);
      final lease = await owner.acquireLocalCamera();
      owner.liveReleased();
      expect(owner.isCurrent(lease!), isTrue);
    },
  );

  test('a camera that fails to start leaves capture off', () async {
    final media = FakeMedia()..cameraDenied = true;
    final owner = CaptureOwner(media);
    await expectLater(owner.acquireLocalCamera(), throwsStateError);
    expect(owner.mode, CaptureMode.off);
    expect(owner.pending, isNull);
    expect(media.log, ['startCameraOnly', 'stop']);
  });
}
