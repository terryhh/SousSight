// Pre-existing (Codex, other PR reviews): a pantry scan made before choosing
// meal B used to be recorded under meal A's ledger and then cleared when
// meal B started. A new pantry flow now starts a fresh ledger, and the meal
// chosen from it carries those legs. Fakes only; no model or network.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/pantry/pantry_flow.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

HybridRuntime _runtime() => HybridRuntime.create(
  inference: FakeHybridInference(),
  cloudRoutes: const CloudRoutes({}),
  cloudFallback: _NoCloud(),
  isOnline: () => true,
  cloudModel: 'test-model',
);

/// Stands in for a pantry scan's cloud leg.
void _scanLeg(HybridRuntime hybrid) =>
    hybrid.cloudSends.begin('pantry_scan', const {DataKind.text}).confirmed();

/// Cooking stand-in: "ready" binds the meal's session, "back" returns.
Widget _cooking(HybridRuntime hybrid, Recipe recipe, VoidCallback back) =>
    Scaffold(
      body: Column(
        children: [
          Text('Cooking ${recipe.id}'),
          TextButton(
            key: const ValueKey('ready'),
            onPressed: () => hybrid.bindCookingSession('meal-${recipe.id}'),
            child: const Text('ready'),
          ),
          TextButton(
            key: const ValueKey('back'),
            onPressed: back,
            child: const Text('back'),
          ),
        ],
      ),
    );

void main() {
  test('beginPantry starts a fresh ledger once per pantry flow', () {
    final hybrid = _runtime();
    final first = hybrid.sessionId;
    hybrid.beginPantry(); // already in a pantry flow: no change
    expect(hybrid.sessionId, first);
    _scanLeg(hybrid);
    hybrid.bindCookingSession('meal-a');
    expect(hybrid.ledgerSource.legs, hasLength(1), reason: 'carried');
    final generation = hybrid.ledger.generation;
    hybrid.beginPantry();
    expect(hybrid.sessionId, startsWith('run-'));
    expect(hybrid.ledgerSource.legs, isEmpty);
    expect(hybrid.ledger.generation, generation + 1);
    _scanLeg(hybrid);
    hybrid.bindCookingSession('meal-b');
    expect(hybrid.sessionId, 'meal-b');
    expect(
      hybrid.ledgerSource.legs,
      hasLength(1),
      reason: 'B carries its scan',
    );
  });

  // Codex #224 (71/100) P2: a pop during session initialization must not
  // undo the pantry reset.
  test('a session load finishing after the pop is ignored', () {
    final hybrid = _runtime();
    _scanLeg(hybrid);
    hybrid.bindCookingSession('meal-a');
    hybrid.beginPantry(); // back to the pantry
    final pantryId = hybrid.sessionId;
    // Meal B's screen opens; its session is still loading when it is popped.
    final bindB = hybrid.cookingSessionBinder();
    hybrid.beginPantry();
    _scanLeg(hybrid); // a scan in the new pantry flow
    bindB('meal-b'); // the load finishes late
    expect(hybrid.sessionId, pantryId, reason: 'still the pantry flow');
    expect(hybrid.ledgerSource.legs, hasLength(1));
    // A binder from a screen opened after the reset still works.
    hybrid.cookingSessionBinder()('meal-c');
    expect(hybrid.sessionId, 'meal-c');
    expect(hybrid.ledgerSource.legs, hasLength(1), reason: 'carried');
  });

  testWidgets('back to the pantry, scan, choose meal B: the scan is in meal '
      'B\'s ledger, not lost with meal A\'s', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final List<Recipe> recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final AppServices services = (await tester.runAsync(fakeServices))!;
    final hybrid = _runtime();
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        navigatorKey: hybrid.navigatorKey,
        home: PantryFlow(
          services: services,
          isDemo: false,
          hybrid: hybrid,
          loadRecipes: () => SynchronousFuture(recipes),
          cookingBuilder: (recipe, back) => _cooking(hybrid, recipe, back),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> choose(String recipeId) async {
      final skip = find.byKey(ValueKey('skip-$recipeId'));
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(find.text('Cooking $recipeId'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ready')));
      await tester.pump();
    }

    // Meal A: its pantry scan is carried in.
    _scanLeg(hybrid);
    await choose('chickpea_wrap_v1');
    expect(hybrid.sessionId, 'meal-chickpea_wrap_v1');
    expect(hybrid.ledgerSource.legs, hasLength(1));

    // Back to the pantry: a new flow with an empty ledger of its own.
    await tester.tap(find.byKey(const ValueKey('back')));
    await tester.pumpAndSettle();
    expect(hybrid.sessionId, startsWith('run-'));
    expect(hybrid.ledgerSource.legs, isEmpty);

    // A scan before choosing meal B is meal B's.
    _scanLeg(hybrid);
    await choose('black_bean_corn_salsa_v1');
    expect(hybrid.sessionId, 'meal-black_bean_corn_salsa_v1');
    expect(hybrid.ledgerSource.legs, hasLength(1));
    expect(hybrid.ledgerSource.legs.single.feature, 'pantry_scan');
  });
}
