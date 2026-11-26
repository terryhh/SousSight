// Kitchen mode wired into the cooking screen (SS-107), with a fake wake lock
// and in-memory preferences. No browser or device wake lock is exercised here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/data/dinner_status.dart';
import 'package:soussight/kitchen/kitchen_mode.dart';
import 'package:soussight/kitchen/kitchen_preferences.dart';
import 'package:soussight/kitchen/kitchen_text.dart';
import 'package:soussight/kitchen/screen_wake_lock.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';

void main() {
  late FakeScreenWakeLock lock;
  late InMemoryKitchenPreferences prefs;
  late CookingCoordinator cook;

  final toggle = find.byKey(const ValueKey('kitchen-big-text'));
  final workspaceTitle = find.text('Your cooking space');

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
    double systemScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = systemScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final services = (await tester.runAsync(() async {
      final recipe = await loadBundledRecipe();
      return AppServices(
        auth: FakeAuthService(),
        recipes: FakeRecipeRepository(recipe),
        sessions: FakeSessionRepository(),
        bundledRecipe: recipe,
      );
    }))!;
    cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: DemoLiveTransport.new,
      media: DemoLiveMedia(),
      isDemo: true,
    );
    await tester.pumpWidget(
      KitchenModeScope(
        create: () => KitchenMode(wakeLock: lock, preferences: prefs),
        child: MaterialApp(
          theme: cookingTheme,
          home: CookingScreen(
            services: services,
            isDemo: true,
            createCoordinator: () => cook,
            dinnerStatus: FakeDinnerBackend(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextScaler workspaceScaler(WidgetTester tester) =>
      MediaQuery.textScalerOf(tester.element(workspaceTitle));

  setUp(() {
    lock = FakeScreenWakeLock();
    prefs = InMemoryKitchenPreferences();
  });

  testWidgets('the screen stays on while the session is active', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(cook.session, isNotNull);
    expect(lock.calls, [true]);

    // Away from the app: released. Back: taken again.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(lock.calls, [true, false]);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(lock.calls, [true, false, true]);

    // Leaving the cooking screen releases it.
    await tester.pumpWidget(const SizedBox());
    expect(lock.calls, [true, false, true, false]);
  });

  testWidgets('finishing the cook releases the wake lock', (tester) async {
    await pumpScreen(tester);
    expect(lock.held, isTrue);
    final total = cook.recipe.steps.length;
    for (var i = 0; i < total; i++) {
      final label = i == total - 1 ? 'Finish cooking' : 'Next step →';
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(cook.complete, isTrue);
    expect(lock.calls, [true, false]);
    await tester.pumpWidget(const SizedBox());
    expect(lock.calls, [true, false]);
  });

  testWidgets('Big text enlarges the cooking space and is saved', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(toggle, findsOneWidget);
    expect(workspaceScaler(tester), TextScaler.noScaling);

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.bigText, isTrue);
    expect(workspaceScaler(tester), isA<KitchenTextScaler>());
    expect(workspaceScaler(tester).scale(42), 63, reason: 'the timer digits');
    // The camera column is not enlarged.
    expect(
      MediaQuery.textScalerOf(tester.element(find.text(cook.recipe.title))),
      TextScaler.noScaling,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a saved Big text choice applies when the screen opens', (
    tester,
  ) async {
    prefs.bigText = true;
    await pumpScreen(tester);
    expect(workspaceScaler(tester), isA<KitchenTextScaler>());
  });

  testWidgets('Big text sits on top of the system text scale', (
    tester,
  ) async {
    prefs.bigText = true;
    await pumpScreen(tester, systemScale: 1.3);
    expect(workspaceScaler(tester).scale(10), closeTo(19.5, 1e-9));
  });

  testWidgets('Big text fits a phone without overflow', (tester) async {
    prefs.bigText = true;
    await pumpScreen(tester, size: const Size(360, 780));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(workspaceScaler(tester), isA<KitchenTextScaler>());
    expect(tester.takeException(), isNull);
  });
}
