import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/draft_recipe_chip.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_flow.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/pantry/recipe_draft.dart';

const _draft = Recipe(
  id: 'draft_test',
  version: 1,
  title: 'Pantry Bean Bowl',
  summary: 'Beans and rice.',
  ingredients: [
    Ingredient(id: 'beans', name: 'canned black beans', qty: '1 can'),
    Ingredient(id: 'rice', name: 'rice', qty: '1 cup'),
  ],
  equipment: ['bowl'],
  steps: [
    RecipeStep(
      id: 'mix',
      title: 'Mix',
      instruction: 'Mix the beans and rice.',
      cue: 'Evenly mixed.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

class _FakeDraftClient implements RecipeDraftClient {
  _FakeDraftClient({this.error});
  final RecipeDraftException? error;
  RecipeDraftRequest? request;

  @override
  Future<Recipe> draft(RecipeDraftRequest request) async {
    this.request = request;
    if (error case final error?) throw error;
    return _draft;
  }
}

/// Spots items but no catalog meal fits.
class _NoMealsClient implements PantryClient {
  const _NoMealsClient();
  @override
  Future<PantryResult> identify(
    PantryInput input,
    List<Recipe> recipes,
  ) async => const PantryResult(
    items: [
      PantryItem(name: 'canned black beans', confidence: PantryConfidence.high),
      PantryItem(name: 'rice', confidence: PantryConfidence.high),
    ],
    meals: [],
    simulated: true,
  );
}

CookingCoordinator _coordinator(AppServices services, Recipe recipe) =>
    CookingCoordinator(
      services: services,
      recipe: recipe,
      research: const FakeCookingResearchClient(),
      transportFactory: DemoLiveTransport.new,
      media: DemoLiveMedia(),
      isDemo: true,
    );

void main() {
  late List<Recipe> recipes;
  late AppServices services;

  Future<void> setUp360(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    recipes = (await tester.runAsync(loadRecipeCatalog))!;
    services = (await tester.runAsync(fakeServices))!;
  }

  Widget app(PantryClient client, RecipeDraftClient draftClient) => MaterialApp(
    theme: cookingTheme,
    home: PantryFlow(
      services: services,
      isDemo: true,
      client: client,
      draftClient: draftClient,
      loadRecipes: () => SynchronousFuture(recipes),
    ),
  );

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  FilledButton draftButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.ancestor(
      of: find.text('Draft a recipe with these'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    ),
  );

  testWidgets('no fitting meal: draft from confirmed items opens cooking', (
    tester,
  ) async {
    await setUp360(tester);
    final drafts = _FakeDraftClient();
    await tester.pumpWidget(app(const _NoMealsClient(), drafts));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pantry-text')),
      'I want a bowl',
    );
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    expect(
      find.text('None of our reviewed recipes fit — want me to draft one?'),
      findsOneWidget,
    );
    // Disabled until the cook confirms at least one item.
    expect(draftButton(tester).onPressed, isNull);
    expect(find.text('Tap the items you have first'), findsOneWidget);

    await tapVisible(tester, find.bySemanticsLabel(RegExp('^rice, ')));
    expect(draftButton(tester).onPressed, isNotNull);
    expect(find.text('Tap the items you have first'), findsNothing);
    await tapVisible(tester, find.byKey(const ValueKey('draft-recipe')));

    expect(drafts.request!.confirmedItems, ['rice']);
    expect(drafts.request!.note, 'I want a bowl');
    expect(find.text('Pantry Bean Bowl'), findsWidgets);
    expect(find.text('Back to pantry'), findsOneWidget);
    expect(find.byKey(const ValueKey('draft-recipe-chip')), findsOneWidget);
    expect(find.text(kDraftRecipeLabel), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('draft-recipe-chip')));
    await tester.pumpAndSettle();
    expect(find.text(draftRecipeAdvice), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    // The pantry result keeps the labelled draft after returning.
    await tester.tap(find.text('Back to pantry'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('cook-drafted')));
    expect(find.text(kDraftRecipeLabel), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('draft errors are shown to the cook', (tester) async {
    await setUp360(tester);
    final drafts = _FakeDraftClient(
      error: const RecipeDraftException('Could not draft that safely.'),
    );
    await tester.pumpWidget(app(const _NoMealsClient(), drafts));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    await tapVisible(
      tester,
      find.bySemanticsLabel(RegExp('^canned black beans, ')),
    );
    await tapVisible(tester, find.byKey(const ValueKey('draft-recipe')));
    expect(find.text('Could not draft that safely.'), findsOneWidget);
    expect(find.text('Back to pantry'), findsNothing);
    expect(draftButton(tester).onPressed, isNotNull);
  });

  testWidgets('meals exist: a secondary draft action is offered', (
    tester,
  ) async {
    await setUp360(tester);
    final drafts = _FakeDraftClient();
    await tester.pumpWidget(
      app(const FakePantryClient(delay: Duration.zero), drafts),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    expect(find.byKey(const ValueKey('draft-card')), findsNothing);
    final secondary = find.byKey(const ValueKey('draft-something-else'));
    await tester.ensureVisible(secondary);
    expect(find.text('Draft something else with these'), findsOneWidget);
    await tapVisible(
      tester,
      find.bySemanticsLabel(RegExp('^canned black beans, ')),
    );
    await tapVisible(tester, secondary);
    expect(drafts.request!.confirmedItems, ['canned black beans']);
    expect(find.text('Pantry Bean Bowl'), findsWidgets);
    expect(find.byKey(const ValueKey('draft-recipe-chip')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('coach context', () {
    test(
      'draft recipes carry the unreviewed note; bundled ones do not',
      () async {
        final services = await fakeServices();
        final bundled = (await loadRecipeCatalog()).first;
        final draft = _coordinator(services, _draft);
        final reviewed = _coordinator(services, bundled);
        addTearDown(draft.dispose);
        addTearDown(reviewed.dispose);
        expect(draft.cookingContext, contains(draftRecipeContextLine));
        expect(draft.cookingContext, contains('food thermometer'));
        expect(
          reviewed.cookingContext,
          isNot(contains(draftRecipeContextLine)),
        );
        expect(reviewed.cookingContext, isNot(contains('AI-drafted')));
      },
    );
  });
}
