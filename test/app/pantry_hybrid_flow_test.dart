// The real (non-rehearsal) pantry flow with the hybrid runtime wired in:
// typed list → HybridPantryClient → DefaultHybridDispatcher → fake bridge.
// Fakes only; no model or network is used.

import 'dart:convert';

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

void main() {
  testWidgets('a typed scan runs on this device and shows its leg, the '
      'readiness panel and the trust buttons', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final List<Recipe> recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final AppServices services = (await tester.runAsync(fakeServices))!;
    final inference = FakeHybridInference()..enqueueText(_scan());
    final hybrid = HybridRuntime.create(
      inference: inference,
      cloudRoutes: const CloudRoutes({}),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-model',
    );
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
    // SS-089: a ready device gets no warning stack and no calm line.
    expect(find.byKey(const ValueKey('readiness-panel')), findsNothing);
    expect(find.byKey(const ValueKey('readiness-line')), findsNothing);
    expect(find.byKey(const ValueKey('open-on-device-ai')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-ledger')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-label-check')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('pantry-text')),
      'a can of black beans',
    );
    final find0 = find.byKey(const ValueKey('find-meal'));
    await tester.ensureVisible(find0);
    await tester.tap(find0);
    await tester.pumpAndSettle();

    // No cloud route: the ranking ran on this device only.
    expect(inference.requests.single.mode, HybridMode.onlyOnDevice);
    final legs = find.byKey(const ValueKey('pantry-legs'));
    expect(legs, findsOneWidget);
    expect(
      find.descendant(of: legs, matching: find.text('On this device')),
      findsOneWidget,
    );
    expect(hybrid.ledgerSource.legs.single.provenance, Provenance.sdkOnDevice);
    expect(hybrid.ledgerSource.legs.single.transferPermitted, isFalse);
  });
}
