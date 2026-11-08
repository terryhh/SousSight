import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/live/live_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default sandwich session preserves separate chickpea progress',
    () async {
      final sandwich = await loadBundledRecipe();
      final chickpea = await loadBundledRecipe('chickpea_wrap_v1');
      expect(sandwich.id, 'peanut_butter_sandwich_v1');
      final sessions = FakeSessionRepository();
      final old = await sessions.createOrResume('returning-cook', chickpea);
      await sessions.update(
        old.id,
        (session) => session.copyWith(
          currentStepId: chickpea.steps[1].id,
          completedStepIds: [chickpea.steps.first.id],
          confirmedFacts: ['Keep the original recipe notes.'],
        ),
      );
      final current = await sessions.createOrResume('returning-cook', sandwich);
      expect(current.id, isNot(old.id));
      expect(current.recipeId, sandwich.id);
      expect(current.currentStepId, sandwich.steps.first.id);
      expect(current.completedStepIds, isEmpty);
      expect(current.confirmedFacts, isEmpty);
      expect(
        (await sessions.createOrResume('returning-cook', sandwich)).id,
        current.id,
      );
      final preserved = await sessions.createOrResume(
        'returning-cook',
        chickpea,
      );
      expect(preserved.id, old.id);
      expect(preserved.currentStepId, chickpea.steps[1].id);
      expect(preserved.confirmedFacts, ['Keep the original recipe notes.']);
    },
  );

  test('sandwich advances through untimed steps without fabricated waits or images', () async {
    final services = await fakeServices();
    final cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: DemoLiveTransport.new,
      media: DemoLiveMedia(),
      isDemo: true,
    );
    addTearDown(cook.dispose);
    await cook.initialize();
    expect(cook.error, isNull);
    expect(cook.recipe.steps.map((s) => s.id), [
      'prep',
      'spread',
      'optional_jam',
      'close',
    ]);
    expect(
      cook.recipe.checkpoints.every((cp) => cp.targetImageAsset.isEmpty),
      isTrue,
    );
    for (var i = 0; i < cook.recipe.steps.length; i++) {
      expect(cook.stepIndex, i);
      expect(cook.complete, isFalse);
      expect(cook.step.timerSeconds, isNull);
      await cook.startStepTimer();
      expect(cook.ui.timers, isEmpty);
      expect(cook.session!.timerDeadline, isNull);
      await cook.advanceStep();
    }
    expect(cook.complete, isTrue);
    expect(cook.step.id, 'close');
    final revision = cook.session!.revision;
    await cook.advanceStep();
    expect(cook.session!.revision, revision);
    // Explicit cook-requested timers remain available for either recipe.
    await cook.startTimer('requested-timer', 'My reminder', 30);
    expect(cook.ui.timers.single.label, 'My reminder');
  });

  testWidgets(
    'default narrow workspace and simulated panels use sandwich context',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 740);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final services = (await tester.runAsync(fakeServices))!;
      final transport = DemoLiveTransport();
      final cook = CookingCoordinator(
        services: services,
        research: FakeCookingResearchClient(),
        transportFactory: () => transport,
        media: DemoLiveMedia(),
        isDemo: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: CookingScreen(
            services: services,
            isDemo: true,
            createCoordinator: () => cook,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(services.bundledRecipe.title), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Check my food').last,
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('minute timer'), findsNothing);
      expect(find.textContaining('bowl'), findsNothing);
      expect(find.textContaining('chickpea'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
      await cook.connect();
      await tester.pumpAndSettle();
      expect(jsonEncode(cook.ui.components), contains(cook.step.instruction));
      await cook.advanceStep();
      await tester.pumpAndSettle();
      await cook.checkNow();
      await tester.pumpAndSettle();
      final panels = jsonEncode(cook.ui.components);
      expect(panels, contains(cook.step.cue));
      expect(panels, isNot(contains('chickpea')));
      expect(panels, isNot(contains('bowl')));
      expect(
        find.byKey(const ValueKey('live-session-toggle')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
