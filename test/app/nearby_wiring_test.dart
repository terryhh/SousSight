// SS-096 wiring: in real mode the nearby entry points follow CLOUD_ROUTES.
// Production approves only hybridFallback and research, so nearby must stay
// hidden there. Fakes only; no model, Maps or network call is made.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/pantry/pantry_flow.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

/// The routes Terry approved for production.
const _production = 'hybridFallback,research';

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

String _scan() => jsonEncode({
  'items': [
    {'name': 'canned black beans', 'confidence': 'high'},
  ],
  'meals': [
    {
      'recipeId': 'black_bean_corn_salsa_v1',
      'why': 'Beans and corn are most of it.',
      'matched': ['black beans'],
      'missing': ['lime'],
    },
  ],
});

HybridRuntime _runtime(String routes, FakeHybridInference inference) =>
    HybridRuntime.create(
      inference: inference,
      cloudRoutes: CloudRoutes.parse(routes),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-model',
    );

bool _nearbyMissingKey(Widget w) =>
    w.key is ValueKey<String> &&
    (w.key! as ValueKey<String>).value.startsWith('nearby-missing-');

void main() {
  void phone(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpPantry(WidgetTester tester, String routes) async {
    phone(tester);
    final List<Recipe> recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final AppServices services = (await tester.runAsync(fakeServices))!;
    final inference = FakeHybridInference()..enqueueText(_scan());
    final hybrid = _runtime(routes, inference);
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        navigatorKey: hybrid.navigatorKey,
        home: PantryFlow(
          services: services,
          isDemo: false,
          hybrid: hybrid,
          loadRecipes: () => SynchronousFuture(recipes),
          cookingBuilder: (recipe, back) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pantry-text')),
      'a can of black beans',
    );
    final findMeal = find.byKey(const ValueKey('find-meal'));
    await tester.ensureVisible(findMeal);
    await tester.tap(findMeal);
    await tester.pumpAndSettle();
    // The ranked meal is shown, with an item missing.
    expect(find.textContaining('lime'), findsWidgets);
  }

  testWidgets('production routes: no nearby entry points on the pantry', (
    tester,
  ) async {
    await pumpPantry(tester, _production);
    expect(find.byKey(const ValueKey('nearby-food-help')), findsNothing);
    expect(find.text('Find food help nearby'), findsNothing);
    expect(find.byWidgetPredicate(_nearbyMissingKey), findsNothing);
  });

  testWidgets('with the nearby route approved, the pantry offers it', (
    tester,
  ) async {
    await pumpPantry(tester, '$_production,nearby');
    expect(find.byKey(const ValueKey('nearby-food-help')), findsOneWidget);
    expect(find.byWidgetPredicate(_nearbyMissingKey), findsWidgets);
  });

  Future<void> finishCooking(WidgetTester tester, String routes) async {
    phone(tester);
    final services = (await tester.runAsync(fakeServices))!;
    final hybrid = _runtime(routes, FakeHybridInference());
    final cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: null,
      media: DemoLiveMedia(),
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
    final total = cook.recipe.steps.length;
    for (var i = 0; i < total; i++) {
      final label = i == total - 1 ? 'Finish cooking' : 'Next step →';
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('meal-complete')), findsOneWidget);
  }

  testWidgets('production routes: no nearby button when the meal is done', (
    tester,
  ) async {
    await finishCooking(tester, _production);
    expect(find.byKey(const ValueKey('meal-complete-nearby')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with the nearby route approved, meal complete offers it', (
    tester,
  ) async {
    await finishCooking(tester, '$_production,nearby');
    expect(find.byKey(const ValueKey('meal-complete-nearby')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
