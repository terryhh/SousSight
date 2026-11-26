import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';

class _Sessions extends FakeSessionRepository {
  bool failCreation = false;
  int creations = 0;
  Completer<void>? gate;
  @override
  Future<CookingSession> createNew(String learnerId, Recipe recipe) async {
    creations++;
    await gate?.future;
    if (failCreation) throw StateError('Controlled failure');
    return super.createNew(learnerId, recipe);
  }
}

class _Media extends DemoLiveMedia {
  bool active = false;
  int stops = 0;
  @override
  Future<void> start() async {
    active = true;
  }

  @override
  Future<void> stop() async {
    active = false;
    stops++;
  }
}

class _Research implements CookingResearchClient {
  final pending = Completer<CookingResearchResult>();
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) =>
      pending.future;
}

class _Fixture {
  final sessions = _Sessions();
  final research = _Research();
  final cooks = <CookingCoordinator>[];
  final media = <_Media>[];
  late AppServices services;
  late CookingSession original;

  Future<void> initialize() async {
    final recipe = await loadBundledRecipe();
    final auth = FakeAuthService();
    final uid = await auth.signInLearner();
    original = await sessions.createNew(uid, recipe);
    original = await sessions.update(
      original.id,
      (s) => s.copyWith(
        currentStepId: 'spread',
        completedStepIds: ['prep'],
        ingredients: {recipe.ingredients.first.id: IngredientStatus.have},
        confirmedFacts: ['Use whole wheat bread.'],
        timerId: 'old-reminder',
        timerLabel: 'Old reminder',
        timerDeadline: DateTime.now().add(const Duration(minutes: 5)),
      ),
    );
    services = AppServices(
      auth: auth,
      recipes: FakeRecipeRepository(recipe),
      sessions: sessions,
      bundledRecipe: recipe,
    );
  }

  CookingCoordinator createCoordinator() {
    final capture = _Media();
    media.add(capture);
    final cook = CookingCoordinator(
      services: services,
      research: research,
      media: capture,
      transportFactory: DemoLiveTransport.new,
      isDemo: true,
    );
    cooks.add(cook);
    return cook;
  }
}

void main() {
  Future<_Fixture> open(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 740);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _Fixture();
    await tester.runAsync(fixture.initialize);
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(
          services: fixture.services,
          isDemo: true,
          createCoordinator: fixture.createCoordinator,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  Future<void> review(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('new-cook'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Start a new cook?'), findsOneWidget);
  }

  testWidgets('cancel keeps the current cook and creates nothing', (
    tester,
  ) async {
    final f = await open(tester);
    final old = f.cooks.single;
    await old.connect();
    await tester.pumpAndSettle();
    await review(tester);
    await tester.tap(find.text('Keep cooking'));
    await tester.pumpAndSettle();
    expect(f.sessions.creations, 1);
    expect(f.cooks, hasLength(1));
    expect(old.session!.id, f.original.id);
    expect(old.live.isActive, isTrue);
    expect(f.media.single.active, isTrue);
    expect(old.ui.timers.single.id, 'old-reminder');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('duplicate New cook actions create one replacement while saving', (
    tester,
  ) async {
    final f = await open(tester);
    final old = f.cooks.single;
    await old.connect();
    await tester.pumpAndSettle();
    final gate = Completer<void>();
    f.sessions.gate = gate;
    final button = find.byKey(const ValueKey('new-cook'));
    final start = tester.widget<TextButton>(button).onPressed!;

    // Two events can use the same enabled callback before Flutter rebuilds.
    start();
    start();
    await tester.pumpAndSettle();
    expect(find.text('Start a new cook?'), findsOneWidget);
    expect(f.sessions.creations, 1, reason: 'review alone creates nothing');
    await tester.tap(find.text('Start new cook'));
    await tester.pumpAndSettle();

    expect(f.cooks, hasLength(2));
    expect(f.sessions.creations, 2);
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    // An already queued action must also be ignored while persistence waits.
    start();
    await tester.pump();
    expect(find.text('Start a new cook?'), findsNothing);
    expect(f.cooks, hasLength(2));
    expect(f.sessions.creations, 2);
    expect(old.live.isActive, isTrue);
    expect(f.media.first.active, isTrue);

    gate.complete();
    await tester.pumpAndSettle();
    final current = f.cooks.last;
    expect(current.session!.id, isNot(f.original.id));
    expect(current.step.id, 'prep');
    expect(current.ui.timers, isEmpty);
    expect(f.sessions.creations, 2, reason: 'exactly one replacement was saved');
    expect(f.media.first.active, isFalse);
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    final resumed = await f.sessions.createOrResume(
      current.session!.learnerId,
      current.recipe,
    );
    expect(resumed.id, current.session!.id);
    expect(
      (await f.sessions.watch(f.original.id).first).confirmedFacts,
      f.original.confirmedFacts,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'explicit new cook retires old async work and preserves saved history',
    (tester) async {
      final f = await open(tester);
      final old = f.cooks.single;
      await old.connect();
      old.live.startWatch('Spread coverage');
      final pendingResearch = old.researchQuestionNow('Old recipe question');
      await tester.pump(const Duration(milliseconds: 300));
      final input = find.byKey(const ValueKey('cooking-message-input'));
      await tester.enterText(input, 'Old unsent message');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump(const Duration(milliseconds: 300));
      await review(tester);
      expect(find.text('Start new cook').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Start new cook'));
      for (var i = 0; i < 8; i++) { await tester.pump(const Duration(milliseconds: 100)); }
      final current = f.cooks.last;
      expect(f.cooks, hasLength(2));
      expect(f.sessions.creations, 2);
      expect(current.session!.id, isNot(f.original.id));
      expect(current.step.id, 'prep');
      expect(current.session!.ingredients, isEmpty);
      expect(current.session!.confirmedFacts, isEmpty);
      expect(current.session!.completedStepIds, isEmpty);
      expect(current.ui.timers, isEmpty);
      expect(current.live.isActive, isFalse);
      expect(old.live.watchId, isNull);
      expect(f.media.first.active, isFalse);
      expect(f.media.first.stops, greaterThan(0));
      expect(f.media.last.active, isFalse);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      final before = jsonEncode(current.ui.components);
      f.research.pending.complete(
        const CookingResearchResult(answer: 'Late old answer'),
      );
      await tester.pumpAndSettle();
      expect(await pendingResearch, isNull);
      expect(jsonEncode(current.ui.components), before);
      expect(current.researchResult, isNull);
      final saved = await f.sessions.watch(f.original.id).first;
      expect(saved.confirmedFacts, ['Use whole wheat bread.']);
      expect(saved.currentStepId, 'spread');
      expect(saved.timerId, 'old-reminder');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed creation leaves old capture and workspace usable and can retry',
    (tester) async {
      final f = await open(tester);
      final old = f.cooks.single;
      await old.connect();
      await tester.pumpAndSettle();
      f.sessions.failCreation = true;
      await review(tester);
      await tester.tap(find.text('Start new cook'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your current cook is still available'),
        findsOneWidget,
      );
      expect(old.live.isActive, isTrue);
      expect(f.media.first.active, isTrue);
      expect(old.session!.id, f.original.id);
      expect(old.ui.timers.single.id, 'old-reminder');
      await old.advanceStep();
      await tester.pumpAndSettle();
      expect(old.step.id, 'optional_jam');
      f.sessions.failCreation = false;
      await review(tester);
      await tester.tap(find.text('Start new cook'));
      await tester.pumpAndSettle();
      expect(f.cooks.last.step.id, 'prep');
      expect(f.cooks.last.session!.id, isNot(f.original.id));
      expect(f.media.first.active, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
