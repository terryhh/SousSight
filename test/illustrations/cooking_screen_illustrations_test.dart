// The cooking screen's illustration slot (SS-098), with fakes only: no model,
// network or device. The on-demand path stops at the consent prompt, where
// the test declines, so nothing could be sent.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/illustrations/illustration_controller.dart';
import 'package:soussight/illustrations/illustration_prompts.dart';
import 'package:soussight/illustrations/illustration_wiring.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

import 'fakes.dart';

class _Media implements LiveMedia {
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
  void playAudio(Uint8List pcm24khz) {}
}

class _Research implements CookingResearchClient {
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) =>
      Completer<CookingResearchResult>().future;
}

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) async =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

const _draft = Recipe(
  id: 'draft_dip123',
  version: 1,
  title: 'Cucumber Dip',
  summary: 'AI-drafted.',
  ingredients: [
    Ingredient(id: 'y', name: 'Lemon juice', qty: '1 tbsp'),
    Ingredient(id: 'c', name: 'Cucumber', qty: '1'),
  ],
  equipment: ['bowl'],
  steps: [
    RecipeStep(
      id: 'stir',
      title: 'Stir',
      instruction: 'Stir the lemon juice into the cucumber.',
      cue: 'Pale green shreds, evenly wet.',
    ),
    RecipeStep(
      id: 'serve',
      title: 'Serve',
      instruction: 'Spoon into a bowl.',
      cue: 'A smooth mound in the bowl.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

AppServices _services(Recipe recipe) => AppServices(
  clock: () => DateTime.utc(2026, 11, 26, 18),
  auth: FakeAuthService(),
  recipes: FakeRecipeRepository(recipe),
  sessions: FakeSessionRepository(),
  bundledRecipe: recipe,
);

Future<void> _pump(
  WidgetTester tester,
  Recipe recipe, {
  HybridRuntime? hybrid,
  double width = 1200,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 3000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: hybrid?.navigatorKey,
      home: CookingScreen(
        services: _services(recipe),
        isDemo: false,
        hybrid: hybrid,
        createCoordinator: () => CookingCoordinator(
          services: _services(recipe),
          research: _Research(),
          transportFactory: null,
          media: _Media(),
          recipe: recipe,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a reviewed recipe shows its pre-made, labelled image', (
    tester,
  ) async {
    final recipes = await tester.runAsync(loadRecipeCatalog);
    final wrap = recipes!.firstWhere((r) => r.id == 'chickpea_wrap_v1');
    await _pump(tester, wrap);
    expect(find.byKey(const ValueKey('step-illustrations')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('illustration-step_pickle_onion')),
      findsOneWidget,
    );
    expect(find.text(kIllustrationLabel), findsOneWidget);
    expect(find.text(kIllustrationCompareCopy), findsOneWidget);
    expect(find.text('Show me what it should look like'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a draft offers the cloud button; declining sends nothing', (
    tester,
  ) async {
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: const CloudRoutes({CloudRoute.images}),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    await _pump(tester, _draft, hybrid: hybrid);
    final ask = find.text('Show me what it should look like');
    expect(ask, findsOneWidget);
    await tester.ensureVisible(ask);
    await tester.tap(ask);
    // The waiting spinner never settles; pump the dialog in.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // The prompt names the image model.
    expect(find.byKey(const ValueKey('consent-dialog')), findsOneWidget);
    expect(find.textContaining('gemini-nano-banana-2.1'), findsOneWidget);
    await tester.tap(find.text('Keep it on my phone'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing was sent.'), findsOneWidget);
    expect(
      hybrid.ledger.legs.where((l) => l.feature == kIllustrationFeature),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without the images route a draft shows no button', (
    tester,
  ) async {
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: const CloudRoutes({CloudRoute.hybridFallback}),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
    );
    await _pump(tester, _draft, hybrid: hybrid);
    expect(find.text('Show me what it should look like'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the cap and cache survive a layout breakpoint change', (
    tester,
  ) async {
    final h = Harness(cap: 1);
    var built = 0;
    debugIllustrationControllerFactory = (_) {
      built++;
      return h.controller;
    };
    addTearDown(() => debugIllustrationControllerFactory = null);
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: const CloudRoutes({CloudRoute.images}),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
    );
    await _pump(tester, _draft, hybrid: hybrid);
    final ask = find.text('Show me what it should look like');
    await tester.ensureVisible(ask);
    await tester.tap(ask);
    await tester.pumpAndSettle();
    expect(find.text(kIllustrationLabel), findsOneWidget);
    expect(h.controller.remaining, 0);

    // Narrow (< 850 px) swaps the Row for a Column around the workspace.
    tester.view.physicalSize = const Size(600, 3000);
    await tester.pumpAndSettle();
    expect(find.text(kIllustrationLabel), findsOneWidget);
    expect(built, 1, reason: 'one controller for the whole cooking session');
    expect(h.controller.remaining, 0);
    expect(h.generator.prompts, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('advancing the cook while consent is open sends nothing, '
      'even before the next frame', (tester) async {
    final h = Harness()..consent.gate = Completer<void>();
    debugIllustrationControllerFactory = (_) => h.controller;
    addTearDown(() => debugIllustrationControllerFactory = null);
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: const CloudRoutes({CloudRoute.images}),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
    );
    final cook = CookingCoordinator(
      services: _services(_draft),
      research: _Research(),
      transportFactory: null,
      media: _Media(),
      recipe: _draft,
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 3000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: hybrid.navigatorKey,
        home: CookingScreen(
          services: _services(_draft),
          isDemo: false,
          hybrid: hybrid,
          createCoordinator: () => cook,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ask = find.text('Show me what it should look like');
    await tester.ensureVisible(ask);
    await tester.tap(ask);
    await tester.pump();
    expect(h.consent.asks, hasLength(1));

    // The cook moves on; the grant arrives before Flutter builds a frame.
    await cook.advanceStep();
    expect(cook.step.id, 'serve');
    h.consent.gate!.complete();
    for (var i = 0; i < 20; i++) {
      await Future<void>.value();
    }
    expect(
      h.generator.prompts,
      isEmpty,
      reason: 'the old step was invalidated',
    );
    expect(h.ledger.entries, isEmpty);
    await tester.pump();
    expect(
      h.controller.stateFor(const StepTarget('stir')),
      isA<IllustrationIdle>(),
    );
    await tester.pumpWidget(const SizedBox());
  });

  test('the paid-send count is shared per runtime and per session', () {
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: const CloudRoutes({CloudRoute.images}),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
    );
    final usage = illustrationUsageFor(hybrid);
    expect(identical(usage, illustrationUsageFor(hybrid)), isTrue);
    usage.charge('session-1');
    // A fresh controller for the same session (re-entering the cooking
    // screen) sees the earlier send.
    final controller = illustrationControllerFor(hybrid)
      ..bind(sessionId: 'session-1', recipe: _draft, stepId: 'stir');
    expect(controller.used, 1);
    expect(controller.remaining, controller.cap - 1);
    controller.bind(sessionId: 'session-2', recipe: _draft, stepId: 'stir');
    expect(controller.used, 0);
    controller.dispose();
    final other = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
    );
    expect(illustrationUsageFor(other).used('session-1'), 0);
  });

  test('native connectivity is declared unknown until #224 lands', () {
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
    );
    final controller = illustrationControllerFor(hybrid);
    // The test VM is not the web, so this is the native answer.
    expect(controller.connectivityKnown, isFalse);
    controller.dispose();
  });
}
