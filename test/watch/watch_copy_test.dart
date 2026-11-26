// Watch wording for builds without Live and for practice mode (SS-089).
// Fakes only.

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

final t0 = DateTime(2026, 11, 26, 18);

void main() {
  LocalWatchController controller(
    FakeAsync async,
    FakeHybridDispatcher dispatcher,
    FakeMedia media, {
    bool liveAvailable = true,
    bool simulated = false,
  }) => LocalWatchController(
    dispatcher: dispatcher,
    capture: CaptureOwner(media),
    now: () => t0.add(async.elapsed),
    liveAvailable: liveAvailable,
    simulated: simulated,
  );

  test('Live off: a refusal never points to the Live coach (item 2)', () {
    fakeAsync((async) {
      final dispatcher = FakeHybridDispatcher()
        ..enqueueBlocked(RouteReason.noLocalModel);
      final media = FakeMedia();
      final local = controller(async, dispatcher, media, liveAvailable: false);
      local.start(step: stepA, sessionId: 's1');
      async.flushMicrotasks();
      media.emit(t0.add(async.elapsed));
      async.flushMicrotasks();
      expect(local.isActive, isFalse);
      expect(local.notice, startsWith("This device can't look at photos"));
      expect(local.notice, isNot(contains('Live')));
    });
  });

  test('Live on: the refusal still offers the Live coach', () {
    fakeAsync((async) {
      final dispatcher = FakeHybridDispatcher()
        ..enqueueBlocked(RouteReason.imageNeedsCloud);
      final media = FakeMedia();
      final local = controller(async, dispatcher, media);
      local.start(step: stepA, sessionId: 's1');
      async.flushMicrotasks();
      media.emit(t0.add(async.elapsed));
      async.flushMicrotasks();
      expect(local.notice, contains('Live coach'));
    });
  });

  test('WatchService: no vision and no Live gives the plain refusal', () async {
    final local = LocalWatchController(
      dispatcher: FakeHybridDispatcher(),
      capture: CaptureOwner(FakeMedia()),
    );
    final service = WatchService(
      local: local,
      startLiveWatch: (_) => null,
      stopLiveWatch: () {},
      localVisionSupported: () => false,
      liveAvailable: false,
    );
    final start = await service.startWatch(
      step: stepA,
      sessionId: 's1',
      liveActive: false,
    );
    expect(start.started, isFalse);
    expect(start.message, isNot(contains('Live')));
    expect(service.statusText, start.message);
  });

  test('practice mode: statuses and capture label say pretend', () {
    fakeAsync((async) {
      final dispatcher = FakeHybridDispatcher()
        ..enqueue(
          '{"state":"not_yet","direction":"more","whatISee":"Bread."}',
          provenance: Provenance.simulated,
        );
      final media = FakeMedia();
      final local = controller(async, dispatcher, media, simulated: true);
      final service = WatchService(
        local: local,
        startLiveWatch: (_) => null,
        stopLiveWatch: () {},
        simulated: true,
      );
      WatchStart? start;
      service
          .startWatch(step: stepA, sessionId: 's1', liveActive: false)
          .then((s) => start = s);
      async.flushMicrotasks();
      expect(start!.message, startsWith('Practice watch:'));
      expect(local.captureLabel, 'Practice camera on · microphone off');
      expect(local.statusText, startsWith('Practice watch (pretend) for:'));
      media.emit(t0.add(async.elapsed));
      async.flushMicrotasks();
      expect(local.verdict!.source, WatchVerdictSource.simulated);
      expect(local.statusText, contains('(practice mode, pretend answer)'));
      local.stop();
      async.flushMicrotasks();
      expect(local.captureLabel, isNull);
    });
  });

  test('practice mode: the checking line is pretend too', () {
    fakeAsync((async) {
      final dispatcher = ManualDispatcher();
      final media = FakeMedia();
      final local = LocalWatchController(
        dispatcher: dispatcher,
        capture: CaptureOwner(media),
        now: () => t0.add(async.elapsed),
        simulated: true,
      );
      local.start(step: stepA, sessionId: 's1');
      async.flushMicrotasks();
      media.emit(t0.add(async.elapsed));
      async.flushMicrotasks();
      expect(local.isChecking, isTrue);
      expect(local.statusText, 'Checking the practice picture (pretend)…');
      local.stop();
      async.flushMicrotasks();
    });
  });

  test('overlay chip and checking title in practice mode', () {
    expect(
      watchPrivacyLabel((sent: 0, maybe: 0), simulated: true),
      'Practice mode · pretend checks, nothing sent',
    );
    expect(watchPrivacyLabel(null, simulated: true), contains('Practice'));
    expect(
      watchPhaseText(WatchOverlayPhase.checking, simulated: true).title,
      'Checking this practice picture…',
    );
    expect(
      watchPhaseText(WatchOverlayPhase.checking).title,
      'Checking this frame on this device…',
    );
  });

  testWidgets('overlay renders the practice chip', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: LocalWatchOverlay(
            phase: WatchOverlayPhase.checking,
            uploads: (sent: 0, maybe: 0),
            simulated: true,
          ),
        ),
      ),
    );
    expect(
      find.text('Practice mode · pretend checks, nothing sent'),
      findsOneWidget,
    );
    expect(find.text('Checking this practice picture…'), findsOneWidget);
    expect(find.textContaining('on this device'), findsNothing);
  });
}
