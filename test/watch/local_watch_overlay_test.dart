import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/local_watch_overlay.dart';
import 'package:soussight/watch/watch_service.dart';
import 'package:soussight/watch/watch_verdict.dart';

import 'watch_fakes.dart';

final t0 = DateTime(2026, 11, 25, 18);

InferenceLeg watchLeg(
  Provenance provenance, {
  String feature = kLocalWatchFeature,
  bool transferPermitted = false,
}) => InferenceLeg(
  requestId: 'r-$feature-${provenance.name}',
  feature: feature,
  mode: feature == kLocalWatchFeature
      ? HybridMode.onlyOnDevice
      : HybridMode.onlyInCloud,
  kinds: const {DataKind.image, DataKind.text},
  transferPermitted: transferPermitted,
  provenance: provenance,
);

class _Rig {
  _Rig(this.async) {
    capture = CaptureOwner(media);
    local = LocalWatchController(
      dispatcher: dispatcher,
      capture: capture,
      now: () => t0.add(async.elapsed),
      checkInterval: const Duration(seconds: 5),
    );
    service = WatchService(
      local: local,
      startLiveWatch: (_) => 'live-watch-1',
      stopLiveWatch: () {},
      localVisionSupported: () => true,
    );
  }
  final FakeAsync async;
  final media = FakeMedia()..micDenied = true;
  final dispatcher = FakeHybridDispatcher();
  late final CaptureOwner capture;
  late final LocalWatchController local;
  late final WatchService service;

  void begin() {
    service.startWatch(step: stepA, sessionId: 's1', liveActive: false);
    async.flushMicrotasks();
  }

  void frame() {
    media.emit(t0.add(async.elapsed));
    async.flushMicrotasks();
  }
}

Future<void> pumpPreview(WidgetTester tester, Widget overlay) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              const AspectRatio(
                aspectRatio: 4 / 3,
                child: ColoredBox(color: Colors.brown),
              ),
              Positioned.fill(child: overlay),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('privacy chip wording comes from ledger legs', () {
    test('only on-device and failed local legs: nothing uploaded', () {
      final uploads = watchUploads([
        watchLeg(Provenance.sdkOnDevice),
        watchLeg(Provenance.unknown), // failed, never allowed to leave
        // Another feature's cloud leg is not a watch upload.
        watchLeg(
          Provenance.sdkCloud,
          feature: 'coach_lite',
          transferPermitted: true,
        ),
      ]);
      expect(uploads, (sent: 0, maybe: 0));
      expect(watchPrivacyLabel(uploads), 'On this device · nothing uploaded');
    });

    test('a consented cloud check that was sent is counted and said', () {
      final uploads = watchUploads([
        watchLeg(Provenance.sdkOnDevice),
        watchLeg(
          Provenance.cloudAdapter,
          feature: kWatchCloudCheckFeature,
          transferPermitted: true,
        ),
      ]);
      expect(uploads, (sent: 1, maybe: 0));
      expect(
        watchPrivacyLabel(uploads),
        'On this device · 1 photo sent for a cloud check',
      );
    });

    test('a permitted check that failed may have been sent', () {
      final uploads = watchUploads([
        watchLeg(
          Provenance.unknown,
          feature: kWatchCloudCheckFeature,
          transferPermitted: true,
        ),
      ]);
      expect(uploads, (sent: 0, maybe: 1));
      expect(watchPrivacyLabel(uploads), contains('may have been sent'));
      expect(watchPrivacyLabel(uploads), isNot(contains('nothing')));
    });

    test('with no ledger to read, no upload claim is made', () {
      expect(watchPrivacyLabel(null), 'On this device');
    });
  });

  test('phase text never certifies doneness or safety', () {
    for (final phase in WatchOverlayPhase.values) {
      for (final direction in WatchDirection.values) {
        final text = watchPhaseText(phase, direction: direction);
        final all = '${text.title} ${text.hint ?? ''}'.toLowerCase();
        expect(all, isNot(contains('safe')));
        expect(all, isNot(contains('done')));
        expect(all, isNot(contains('cooked')));
        expect(all, isNot(contains('certif')));
      }
    }
    expect(
      watchPhaseText(WatchOverlayPhase.ready).title,
      contains('you decide'),
    );
    expect(
      watchPhaseText(WatchOverlayPhase.unsure).title,
      'Move the pan or bowl into view',
    );
  });

  test('phase follows the running watch, and clears when it stops', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      expect(watchOverlayPhase(rig.local), isNull);
      rig.dispatcher.enqueue(verdictJson('unsure'));
      rig.begin();
      expect(watchOverlayPhase(rig.local), WatchOverlayPhase.watching);
      rig.frame();
      async.flushMicrotasks();
      expect(watchOverlayPhase(rig.local), WatchOverlayPhase.unsure);
      expect(watchNoticeState(rig.service), WatchState.unsure);

      rig.dispatcher.enqueue(verdictJson('ready'));
      async.elapse(const Duration(seconds: 4));
      rig.frame(); // fresh when the next check is due
      async.elapse(const Duration(seconds: 1));
      // Ready ends the watch and hands the decision to the cook.
      expect(rig.local.verdict?.state, WatchState.ready);
      expect(watchOverlayPhase(rig.local), isNull);
      expect(watchNoticeState(rig.service), WatchState.ready);
    });
  });

  test('a Live watch is never styled as a local verdict', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.service.startWatch(step: stepA, sessionId: 's1', liveActive: true);
      async.flushMicrotasks();
      expect(rig.service.activeRoute, WatchRoute.live);
      expect(watchNoticeState(rig.service), isNull);
      expect(watchStatusNotice(rig.service), isNull);
    });
  });

  testWidgets('unsure shows the reframe prompt and the on-device chip', (
    tester,
  ) async {
    await pumpPreview(
      tester,
      const LocalWatchOverlay(
        phase: WatchOverlayPhase.unsure,
        uploads: (sent: 0, maybe: 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('On this device · nothing uploaded'), findsOneWidget);
    expect(find.text('Move the pan or bowl into view'), findsOneWidget);
    expect(find.byIcon(Icons.center_focus_weak), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready is calm and leaves the decision with the cook', (
    tester,
  ) async {
    await pumpPreview(
      tester,
      const LocalWatchOverlay(
        phase: WatchOverlayPhase.ready,
        uploads: (sent: 1, maybe: 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Looks like the cue — you decide'), findsOneWidget);
    expect(find.textContaining("can't check temperature"), findsOneWidget);
    expect(
      find.text('On this device · 1 photo sent for a cloud check'),
      findsOneWidget,
    );
    expect(find.textContaining('nothing uploaded'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion: phase changes swap instantly', (tester) async {
    Widget at(WatchOverlayPhase phase) => MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: LocalWatchOverlay(phase: phase, uploads: (sent: 0, maybe: 0)),
    );
    await pumpPreview(tester, at(WatchOverlayPhase.watching));
    await pumpPreview(tester, at(WatchOverlayPhase.notYet));
    // One frame, no settling: the old status is already gone.
    expect(find.text('Not yet — keep going'), findsOneWidget);
    expect(find.text('Watching for the cue'), findsNothing);
  });
}
