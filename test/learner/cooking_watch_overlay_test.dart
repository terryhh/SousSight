// The cooking screen's local watch overlay and Coach Lite footer (SS-086),
// wired through a real HybridRuntime over FakeHybridInference. No model,
// camera or network is used.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/watch/watch_verdict.dart';

/// A valid 1×1 PNG, so the preview can decode it.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);

class _Media implements LiveMedia {
  final timed = StreamController<CapturedFrame>.broadcast();
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Stream<CapturedFrame> get timedFrames => timed.stream;
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

String _verdict(String state) => jsonEncode({
  'state': state,
  'direction': 'none',
  'whatISee': 'A pan of chickpeas.',
});

void main() {
  late FakeHybridInference inference;
  late HybridRuntime hybrid;
  late _Media media;
  late CookingCoordinator cook;

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(fakeServices))!;
    inference = FakeHybridInference();
    hybrid = HybridRuntime.create(
      inference: inference,
      cloudRoutes: CloudRoutes.parse(''),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    media = _Media();
    cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: null,
      media: media,
      coachLite: CoachLite(
        dispatcher: hybrid.dispatcher,
        privacy: hybrid.privacy,
        cloudRoutes: hybrid.cloudRoutes,
        isOnline: hybrid.isOnline,
      ),
      watchServiceFactory: (live) => buildWatchService(hybrid, live),
      onSessionReady: hybrid.bindCookingSession,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(
          services: services,
          isDemo: false,
          hybrid: hybrid,
          createCoordinator: () => cook,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> frame(WidgetTester tester) async {
    media.timed.add(CapturedFrame(bytes: _png, capturedAt: DateTime.now()));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  Future<void> stop(WidgetTester tester) async {
    cook.stopWatch();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('a local watch overlays the preview with this watch\'s chip', (
    tester,
  ) async {
    await pumpScreen(tester);
    // An earlier watch in this session sent one consented photo.
    hybrid.ledger.record(
      const InferenceLeg(
        requestId: 'earlier-cloud-check',
        feature: kWatchCloudCheckFeature,
        mode: HybridMode.onlyInCloud,
        kinds: {DataKind.image, DataKind.text},
        transferPermitted: true,
        provenance: Provenance.cloudAdapter,
      ),
    );
    inference.enqueueText(_verdict('unsure'));
    await cook.startWatch();
    await tester.pump();
    expect(find.byKey(const ValueKey('local-watch-overlay')), findsNothing);

    await frame(tester);
    expect(find.byKey(const ValueKey('local-watch-overlay')), findsOneWidget);
    // This watch uploaded nothing, whatever the earlier one did.
    expect(find.text('On this device · nothing uploaded'), findsOneWidget);
    // Overlay prompt and the styled notice under the preview.
    expect(find.text('Move the pan or bowl into view'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('watch-notice-unsure')), findsOneWidget);
    await stop(tester);
  });

  testWidgets('Live off without a watch: no overlay', (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('local-watch-overlay')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a Coach Lite answer shows its footer and Start timer', (
    tester,
  ) async {
    await pumpScreen(tester);
    inference.enqueueText(
      jsonEncode({
        'components': [
          {
            'id': 'root',
            'component': 'CookingColumn',
            'children': ['tip'],
          },
          {
            'id': 'tip',
            'component': 'stepCue',
            'title': 'Keep some texture',
            'body': 'Stop when a few small chunks remain.',
          },
        ],
        'timerSuggestion': {'label': 'Rest the mash', 'seconds': 120},
      }),
    );
    await cook.say('How chunky should it be?');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('coach-lite-footer')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-lite-source')), findsOneWidget);
    final start = find.byKey(const ValueKey('timer-suggestion-start'));
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(cook.ui.timers.single.label, 'Rest the mash');
    await tester.pumpWidget(const SizedBox());
  });
}
