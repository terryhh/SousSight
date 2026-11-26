// SS-099 wiring: the preview sits between choosing a recipe (the recipe list
// or a pantry draft) and cooking. Runs on fakes only (FakeHybridInference,
// in-memory services); no model, network or device is used.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/core/analytics.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/recipe_preview_swap.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_flow.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/pantry/recipe_draft.dart';
import 'package:soussight/pantry/recipe_draft_client.dart';

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

class _StarchClient implements PantryClient {
  const _StarchClient();
  @override
  Future<PantryResult> identify(
    PantryInput input,
    List<Recipe> recipes,
  ) async => const PantryResult(
    items: [PantryItem(name: 'corn starch', confidence: PantryConfidence.high)],
    meals: [
      PantryMeal(
        recipeId: 'black_bean_corn_salsa_v1',
        why: 'Test.',
        matched: [],
        missing: ['corn'],
      ),
    ],
    simulated: true,
  );
}

class _NoMealsClient implements PantryClient {
  const _NoMealsClient();
  @override
  Future<PantryResult> identify(
    PantryInput input,
    List<Recipe> recipes,
  ) async => const PantryResult(
    items: [
      PantryItem(name: 'bread', confidence: PantryConfidence.high),
      PantryItem(name: 'tomato sauce', confidence: PantryConfidence.high),
    ],
    meals: [],
    simulated: true,
  );
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
      'missing': ['corn'],
    },
  ],
});

String _liteAnswer() => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['swap', 'more'],
    },
    {
      'id': 'swap',
      'component': 'stepCue',
      'title': 'Try frozen corn',
      'body': 'Thaw it first.',
    },
    {
      'id': 'more',
      'component': 'stepCue',
      'title': 'Or skip it',
      'body': 'Use more beans.',
    },
  ],
});

void main() {
  late List<Recipe> recipes;
  late AppServices services;
  late RecordingAnalytics analytics;

  Future<void> setUp360(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final base = (await tester.runAsync(fakeServices))!;
    analytics = RecordingAnalytics();
    services = AppServices(
      auth: base.auth,
      recipes: base.recipes,
      sessions: base.sessions,
      bundledRecipe: base.bundledRecipe,
      analytics: analytics,
    );
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Widget flow({
    bool preview = true,
    bool isDemo = false,
    HybridRuntime? hybrid,
    PantryClient? client,
  }) => MaterialApp(
    theme: cookingTheme,
    navigatorKey: hybrid?.navigatorKey,
    home: PantryFlow(
      services: services,
      isDemo: isDemo,
      hybrid: hybrid,
      client: client ?? (hybrid == null ? const FakePantryClient() : null),
      draftClient: const FakeRecipeDraftClient(delay: Duration.zero),
      loadRecipes: () => SynchronousFuture(recipes),
      previewBeforeCooking: preview,
      cookingBuilder: (recipe, back) => Scaffold(
        body: Column(
          children: [
            Text('Cooking ${recipe.id}'),
            TextButton(onPressed: back, child: const Text('Back')),
          ],
        ),
      ),
    ),
  );

  testWidgets('recipe list: back returns to the pantry without starting; '
      'Start cooking opens cooking and logs the choice once', (tester) async {
    await setUp360(tester);
    await tester.pumpWidget(flow());
    await tester.pumpAndSettle();
    final skip = find.byKey(const ValueKey('skip-chickpea_wrap_v1'));
    await tapVisible(tester, skip);

    expect(find.byKey(const ValueKey('recipe-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-no-pantry')), findsOneWidget);
    expect(find.byKey(const ValueKey('reviewed-recipe-chip')), findsOneWidget);
    expect(analytics.events, isEmpty);

    await tester.tap(find.byKey(const ValueKey('preview-back-to-pantry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-preview')), findsNothing);
    expect(find.textContaining('Cooking '), findsNothing);
    expect(analytics.events, isEmpty);

    // The guard was released: the cook can open it again.
    await tapVisible(tester, skip);
    await tester.tap(find.byKey(const ValueKey('preview-start-cooking')));
    await tester.pumpAndSettle();
    expect(find.text('Cooking chickpea_wrap_v1'), findsOneWidget);
    expect(analytics.names, [AnalyticsEvents.recipeChosen]);
  });

  testWidgets('a pantry check with nothing ticked is not a skip: the meal '
      'preview lists what is missing with Find a swap', (tester) async {
    await setUp360(tester);
    await tester.pumpWidget(flow(isDemo: true));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pantry-text')),
      'beans and corn',
    );
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    // Choose the suggested meal without ticking any candidate item.
    await tapVisible(
      tester,
      find.byKey(const ValueKey('cook-black_bean_corn_salsa_v1')),
    );

    expect(find.byKey(const ValueKey('recipe-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-no-pantry')), findsNothing);
    expect(find.text('You have 0 of 7 ingredients'), findsOneWidget);
    expect(find.byKey(const ValueKey('find-swap-corn')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-swap-black_beans')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-swap-cilantro')), findsNothing);

    // The skip list is still a skip.
    await tester.tap(find.byKey(const ValueKey('preview-back-to-pantry')));
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.byKey(const ValueKey('skip-black_bean_corn_salsa_v1')),
    );
    expect(find.byKey(const ValueKey('preview-no-pantry')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-swap-corn')), findsNothing);
  });

  testWidgets('"corn starch" is not corn on the preview or in the saved '
      'session', (tester) async {
    await setUp360(tester);
    await tester.pumpWidget(flow(isDemo: true, client: const _StarchClient()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'x');
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    await tapVisible(tester, find.bySemanticsLabel(RegExp('^corn starch, ')));
    await tapVisible(
      tester,
      find.byKey(const ValueKey('cook-black_bean_corn_salsa_v1')),
    );
    expect(find.byKey(const ValueKey('preview-missing-corn')), findsOneWidget);
    expect(find.text('You have 0 of 7 ingredients'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preview-start-cooking')));
    await tester.pumpAndSettle();
    expect(find.text('Cooking black_bean_corn_salsa_v1'), findsOneWidget);

    final salsa = recipes.firstWhere((r) => r.id == 'black_bean_corn_salsa_v1');
    final session = (await tester.runAsync(() async {
      final uid = await services.auth.signInLearner();
      return services.sessions.createOrResume(uid, salsa);
    }))!;
    expect(session.ingredients, isEmpty);
    expect(
      session.confirmedFacts.first,
      'Pantry has (confirmed by the cook): corn starch.',
    );
  });

  testWidgets('without the flag, choosing opens cooking directly', (
    tester,
  ) async {
    await setUp360(tester);
    await tester.pumpWidget(flow(preview: false));
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.byKey(const ValueKey('skip-chickpea_wrap_v1')),
    );
    expect(find.byKey(const ValueKey('recipe-preview')), findsNothing);
    expect(find.text('Cooking chickpea_wrap_v1'), findsOneWidget);
  });

  testWidgets('pantry draft: the preview labels the AI draft and compares '
      'it with the confirmed items', (tester) async {
    await setUp360(tester);
    await tester.pumpWidget(flow(isDemo: true, client: const _NoMealsClient()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'toast');
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    await tapVisible(tester, find.bySemanticsLabel(RegExp('^bread, ')));
    await tapVisible(tester, find.byKey(const ValueKey('draft-recipe')));

    expect(find.byKey(const ValueKey('recipe-preview')), findsOneWidget);
    expect(find.text(kDraftRecipeLabel), findsOneWidget);
    expect(find.byKey(const ValueKey('reviewed-recipe-chip')), findsNothing);
    // The draft's legs ride along: its source is on the preview itself.
    final source = find.byKey(const ValueKey('preview-draft-source'));
    expect(source, findsOneWidget);
    expect(
      find.descendant(of: source, matching: find.textContaining('imulat')),
      findsWidgets,
    );
    expect(find.text('You have 1 of 3 ingredients'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-have-bread')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('preview-missing-shredded_cheese')),
      findsOneWidget,
    );
    // Rehearsal: no Coach Lite, so a swap shows the question to ask later.
    await tapVisible(
      tester,
      find.byKey(const ValueKey('find-swap-shredded_cheese')),
    );
    expect(find.byKey(const ValueKey('swap-offline')), findsOneWidget);
    await tester.tapAt(const Offset(180, 20));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('preview-start-cooking')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cooking draft_'), findsOneWidget);
    expect(analytics.events, isEmpty); // rehearsal logs nothing
  });

  testWidgets('real build: household allergens from this device and a swap '
      'through the runtime Coach Lite', (tester) async {
    await setUp360(tester);
    final inference = FakeHybridInference()
      ..enqueueText(_scan())
      ..enqueueText(_liteAnswer());
    final hybrid = HybridRuntime.create(
      inference: inference,
      cloudRoutes: const CloudRoutes({}),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-model',
    );
    hybrid.household.setAllergen('wheat', true);
    await tester.pumpWidget(flow(hybrid: hybrid));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pantry-text')),
      'a can of black beans',
    );
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    await tapVisible(
      tester,
      find.bySemanticsLabel(RegExp('^canned black beans, ')),
    );
    await tapVisible(
      tester,
      find.byKey(const ValueKey('cook-black_bean_corn_salsa_v1')),
    );

    expect(find.byKey(const ValueKey('recipe-preview')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('preview-have-black_beans')),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('preview-allergens')));
    expect(
      find.text(
        'The recipe mentions wheat, which is on your household list — '
        'check labels yourself.',
      ),
      findsOneWidget,
    );

    await tapVisible(tester, find.byKey(const ValueKey('find-swap-corn')));
    const question =
        'What can I use instead of canned corn in Black Bean & Corn Salsa?';
    expect(find.text(question), findsOneWidget);
    final request = inference.requests.last;
    expect(request.task.feature, coachLiteFeature);
    expect(request.mode, HybridMode.onlyOnDevice);
    final prompt = jsonEncode(request.toMap());
    expect(
      [
        for (final p in request.task.parts)
          if (p is HybridText) p.text,
      ].join().contains(jsonEncode(question)),
      isTrue,
    );
    // The household list stays on this device.
    expect(prompt.toLowerCase(), isNot(contains('household')));
    expect(find.text('Try frozen corn'), findsOneWidget);
    expect(find.text(kSwapAllergenCaution), findsOneWidget);
    expect(hybrid.ledgerSource.legs.last.feature, coachLiteFeature);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pantry-first app turns the preview on', (tester) async {
    final base = (await tester.runAsync(fakeServices))!;
    await tester.pumpWidget(
      CookingApp(services: base, isDemo: true, pantryFirst: true),
    );
    final pantry = tester.widget<PantryFlow>(find.byType(PantryFlow));
    expect(pantry.previewBeforeCooking, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
