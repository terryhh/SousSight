// The cooking screen's offline banner (SS-072) and its Coach Lite surface,
// driven by fakes only: FakeSessionRepository, FakeHybridDispatcher /
// FakeHybridInference and a fake media. No model, network or device is used.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/coach_lite/timer_suggestion_card.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/data/offline_ops_banner.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/live/live_types.dart';

const _recipe = Recipe(
  id: 'test-wrap',
  version: 1,
  title: 'Chickpea wrap',
  summary: 'A simple wrap.',
  ingredients: [Ingredient(id: 'chickpeas', name: 'Chickpeas', qty: '1 can')],
  equipment: ['bowl'],
  steps: [
    RecipeStep(
      id: 'prep',
      title: 'Prepare',
      instruction: 'Drain the chickpeas.',
      cue: 'No excess liquid.',
      timerSeconds: 90,
    ),
    RecipeStep(
      id: 'mash',
      title: 'Mash',
      instruction: 'Mash with a fork.',
      cue: 'Small chunks remain.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

class _Media implements LiveMedia {
  int chimes = 0;
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Stream<CapturedFrame> get timedFrames => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> startCameraOnly() async {}
  @override
  Future<void> stop() async {}
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void interruptPlayback() {}
  @override
  void playAudio(Uint8List pcm24khz) => chimes++;
}

class _Transport implements LiveTransport {
  final source = StreamController<LiveEvent>.broadcast();
  final texts = <String>[];
  @override
  Stream<LiveEvent> get events => source.stream;
  @override
  Future<void> connect({required String systemInstruction}) async {}
  @override
  Future<void> sendAudio(Uint8List pcm16khz) async {}
  @override
  Future<void> sendVideo(Uint8List jpeg) async {}
  @override
  Future<void> sendText(String text) async => texts.add(text);
  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async {}
  @override
  Future<void> close() async {}
}

class _Research implements CookingResearchClient {
  final queries = <CookingResearchQuery>[];
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) {
    queries.add(query);
    return Completer<CookingResearchResult>().future;
  }
}

class _Privacy implements PrivacySettings {
  @override
  bool localOnly(String feature) => false;
}

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) async =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

String _liteJson() => jsonEncode({
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
});

var _now = DateTime.utc(2026, 11, 25, 18);

AppServices _services() => AppServices(
  clock: () => _now,
  auth: FakeAuthService(),
  recipes: FakeRecipeRepository(_recipe),
  sessions: FakeSessionRepository(),
  bundledRecipe: _recipe,
);

void main() {
  late bool online;
  late StreamController<void> connectivity;
  late FakeHybridDispatcher dispatcher;
  late _Research research;
  late CookingCoordinator cook;
  late _Media media;
  late bool researchOk;

  setUp(() {
    online = true;
    connectivity = StreamController<void>.broadcast();
    dispatcher = FakeHybridDispatcher();
    research = _Research();
    media = _Media();
    researchOk = true;
  });
  tearDown(() => connectivity.close());

  Future<void> pumpScreen(WidgetTester tester, {_Transport? live}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    cook = CookingCoordinator(
      services: _services(),
      research: research,
      transportFactory: live == null ? null : () => live,
      media: media,
      researchAllowed: () => researchOk,
      coachLite: CoachLite(
        dispatcher: dispatcher,
        privacy: _Privacy(),
        cloudRoutes: const CloudRoutes({}),
        isOnline: () => online,
      ),
      isOnline: () => online,
      connectivityChanges: connectivity.stream,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CookingScreen(
          services: _services(),
          isDemo: false,
          createCoordinator: () => cook,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('the banner follows connectivity and counts unsaved steps', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(find.byType(OfflineBanner), findsNothing);

    online = false;
    connectivity.add(null);
    await tester.pumpAndSettle();
    expect(find.text(offlineBannerText), findsOneWidget);
    expect(find.textContaining('waiting to save'), findsNothing);

    await tester.ensureVisible(find.text('Next step →'));
    await tester.tap(find.text('Next step →'));
    await tester.pumpAndSettle();
    expect(cook.step.id, 'mash');
    expect(find.text('1 step change is waiting to save.'), findsOneWidget);
    // Offline the button stays usable: nothing is being saved right now.
    expect(cook.advancing, isFalse);

    online = true;
    connectivity.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(OfflineBanner), findsNothing);
    expect(cook.pendingStepSaves, 0);
    await unmount(tester);
  });

  testWidgets('offline, a typed question gets a Coach Lite answer on this '
      'device and its timer starts on the cook\'s tap', (tester) async {
    await pumpScreen(tester);
    online = false;
    connectivity.add(null);
    await tester.pumpAndSettle();

    dispatcher
      ..delay = const Duration(milliseconds: 10)
      ..enqueue(_liteJson());
    await tester.enterText(
      find.byKey(const ValueKey('cooking-message-input')),
      'How chunky should it be?',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(find.text('Coach Lite is thinking…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();
    expect(find.text('Coach Lite is thinking…'), findsNothing);
    expect(find.byKey(const ValueKey('coach-lite-source')), findsOneWidget);
    expect(find.byType(TimerSuggestionCard), findsOneWidget);
    expect(find.text(offlineBannerText), findsOneWidget);

    final start = find.descendant(
      of: find.byType(TimerSuggestionCard),
      matching: find.byType(FilledButton),
    );
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(cook.ui.timers.single.label, 'Rest the mash');
    // Saved later with its original deadline, not now.
    expect(cook.session!.timerId, cook.ui.timers.single.id);
    await unmount(tester);
  });

  testWidgets('prediction, step timer, research and lifecycle controls', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.ensureVisible(find.text('Ready'));
    await tester.tap(find.text('Ready'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Ready'))
          .selected,
      isTrue,
    );

    await tester.ensureVisible(find.text('Start 90-second timer'));
    await tester.tap(find.text('Start 90-second timer'));
    await tester.pumpAndSettle();
    expect(cook.ui.timers, hasLength(1));

    final researchButton = find.byTooltip('Research a cooking question');
    final input = find.byKey(const ValueKey('cooking-message-input'));
    await tester.ensureVisible(researchButton);
    await tester.tap(researchButton);
    await tester.pump();
    expect(
      tester.widget<TextField>(input).controller!.text,
      'What should I look for during this step?',
    );
    await tester.tap(researchButton);
    await tester.pump();
    expect(research.queries.single.question, contains('look for'));
    researchOk = false;
    await tester.tap(researchButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('Grounded research is off'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(cook.live.isActive, isFalse);
    expect(cook.ui.timers, hasLength(1));
    await unmount(tester);
  });

  testWidgets('the hybrid runtime\'s connectivity reaches the coordinator', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: const CloudRoutes({CloudRoute.hybridFallback}),
      cloudFallback: _NoCloud(),
      isOnline: () => online,
      cloudModel: 'test-cloud-model',
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: hybrid.navigatorKey,
        home: CookingScreen(
          services: _services(),
          isDemo: false,
          hybrid: hybrid,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineBanner), findsNothing);
    online = false;
    // No browser events in tests: any rebuild re-reads connectivity.
    await tester.ensureVisible(find.text('Not yet'));
    await tester.tap(find.text('Not yet'));
    await tester.pumpAndSettle();
    expect(find.text(offlineBannerText), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-label-check')));
    await tester.pumpAndSettle();
    hybrid.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-label-check')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('with Live on: status, microphone, a finished timer chimes, and '
      'Live hears about the step change', (tester) async {
    final transport = _Transport();
    addTearDown(transport.source.close);
    await pumpScreen(tester, live: transport);
    await tester.tap(find.byKey(const ValueKey('live-session-toggle')));
    await tester.pumpAndSettle();
    expect(cook.live.isActive, isTrue);
    expect(find.text('LISTENING & LOOKING'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('microphone-toggle')));
    await tester.pumpAndSettle();
    expect(cook.live.microphoneMuted, isTrue);
    expect(find.text('CAMERA ON · MIC MUTED'), findsWidgets);

    await tester.ensureVisible(find.text('Start 90-second timer'));
    await tester.tap(find.text('Start 90-second timer'));
    await tester.pumpAndSettle();
    _now = _now.add(const Duration(seconds: 91));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('time is up'), findsWidgets);
    expect(media.chimes, 1);

    await tester.ensureVisible(find.text('Next step →'));
    await tester.tap(find.text('Next step →'));
    await tester.pumpAndSettle();
    expect(cook.step.id, 'mash');
    expect(
      transport.texts.where((t) => t.contains('previous step is finished')),
      hasLength(1),
    );
    await tester.tap(find.byKey(const ValueKey('live-session-toggle')));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('the app opens the pantry first when asked', (tester) async {
    await tester.pumpWidget(
      CookingApp(services: _services(), isDemo: true, pantryFirst: true),
    );
    await tester.pump();
    expect(find.byType(CookingScreen), findsNothing);
    await unmount(tester);
  });
}
