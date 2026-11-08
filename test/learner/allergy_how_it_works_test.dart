import 'package:flutter/semantics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/how_it_works.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/allergen_chip.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/recipe_allergens.dart';
import 'package:soussight/pantry/pantry_flow.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

const _allergenFree = Recipe(
  id: 'plain-salad',
  version: 1,
  title: 'Plain salad',
  summary: 'Beans and corn.',
  ingredients: [
    Ingredient(id: 'beans', name: 'Beans', qty: '1 can'),
    Ingredient(id: 'corn', name: 'Corn', qty: '1 can'),
  ],
  equipment: ['bowl'],
  steps: [
    RecipeStep(id: 'mix', title: 'Mix', instruction: 'Mix.', cue: 'Mixed.'),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

const _optionalOnly = Recipe(
  id: 'optional',
  version: 1,
  title: 'Toast',
  summary: 'Toast with optional butter.',
  ingredients: [
    Ingredient(
      id: 'bread',
      name: 'Bread',
      qty: '1 slice',
      allergens: ['wheat'],
    ),
    Ingredient(
      id: 'butter',
      name: 'Butter',
      qty: '1 tsp',
      optional: true,
      allergens: ['milk', 'Wheat'],
    ),
  ],
  equipment: [],
  steps: [
    RecipeStep(
      id: 'toast',
      title: 'Toast',
      instruction: 'Toast.',
      cue: 'Brown.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recipe allergens', () {
    test('union keeps recipe order and marks optional-only allergens', () {
      final allergens = recipeAllergens(_optionalOnly);
      expect(allergens.map((a) => a.name), ['wheat', 'milk']);
      expect(allergens.first.optionalOnly, isFalse);
      expect(allergens.last.optionalOnly, isTrue);
      expect(recipeAllergens(_allergenFree), isEmpty);
    });

    test('recognises a saved allergy answer', () {
      expect(hasAllergyAnswer(['Pan is hot. Answer from cook: yes']), isFalse);
      expect(
        hasAllergyAnswer([
          '$allergyQuestionPrefix any peanut allergy? Answer from cook: no',
        ]),
        isTrue,
      );
      expect(
        hasAllergyAnswer([
          'Does anyone have allergies? Answer from cook: none',
        ]),
        isTrue,
      );
    });
  });

  group('coordinator cooking context', () {
    late AppServices services;
    late Recipe sandwich;
    setUp(() async {
      services = await fakeServices(recipeId: 'peanut_butter_sandwich_v1');
      sandwich = await loadBundledRecipe('peanut_butter_sandwich_v1');
    });

    test('peanut butter sandwich asks about allergens before guidance', () {
      final cook = _coordinator(services, sandwich);
      addTearDown(cook.dispose);
      final context = cook.cookingContext;
      expect(context, contains('Recipe allergens: wheat, peanut.'));
      expect(context, contains('use ask_cook once'));
      expect(context, contains('research_cooking for a safe substitution'));
      expect(
        context,
        contains('Never claim the camera can verify allergen absence'),
      );
      // The opening workspace instruction is still present.
      expect(context, contains('call show_cooking_ui'));
    });

    test('allergen-free recipe has no allergy question', () {
      final cook = _coordinator(services, _allergenFree);
      addTearDown(cook.dispose);
      expect(cook.cookingContext, isNot(contains('Recipe allergens')));
    });

    test('an answered allergy question is not asked again', () async {
      final cook = _coordinator(services, sandwich);
      addTearDown(cook.dispose);
      await cook.initialize();
      expect(cook.cookingContext, contains('Recipe allergens'));
      cook.session = cook.session!.copyWith(
        confirmedFacts: [
          '$allergyQuestionPrefix Does anyone eating have a wheat or peanut '
              'allergy? Answer from cook: No allergies here.',
        ],
      );
      expect(cook.cookingContext, isNot(contains('Recipe allergens')));
      expect(cook.cookingContext, contains('No allergies here.'));
    });
  });

  testWidgets('allergen chip shows contents and a label reminder', (
    tester,
  ) async {
    final sandwich = (await tester.runAsync(
      () => loadBundledRecipe('peanut_butter_sandwich_v1'),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AllergenChip(recipe: sandwich),
              const AllergenChip(recipe: _allergenFree),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Contains: wheat, peanut'), findsOneWidget);
    expect(find.byKey(const ValueKey('allergen-chip')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Allergens. Contains: wheat, peanut')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('allergen-chip')));
    await tester.pumpAndSettle();
    expect(find.text(allergenLabelNote), findsOneWidget);
  });

  testWidgets('screen-reader activation of the allergen chip opens advice', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final sandwich = (await tester.runAsync(
      () => loadBundledRecipe('peanut_butter_sandwich_v1'),
    ))!;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AllergenChip(recipe: sandwich))),
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Allergens. Contains: wheat, peanut')),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.tap(
      find.semantics.byLabel(RegExp('Allergens. Contains: wheat, peanut')),
    );
    await tester.pumpAndSettle();
    expect(find.text(allergenLabelNote), findsOneWidget);
    handle.dispose();
  });

  Future<void> phone(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> expectSheet(WidgetTester tester, {required bool demo}) async {
    final button = find.byKey(const ValueKey('how-it-works-button'));
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('how-it-works-sheet')), findsOneWidget);
    expect(find.text('From pantry to plate'), findsOneWidget);
    expect(
      find.textContaining('Simulated mode'),
      demo ? findsOneWidget : findsNothing,
    );
    final sheet = find.byKey(const ValueKey('how-it-works-sheet'));
    final scrollable = find
        .descendant(of: sheet, matching: find.byType(Scrollable))
        .first;
    Future<void> expectListed(Finder item) async {
      await tester.scrollUntilVisible(item, 120, scrollable: scrollable);
      expect(item, findsOneWidget);
    }

    for (final (title, _) in howItWorksSteps) {
      await expectListed(
        find.descendant(of: sheet, matching: find.textContaining(title)),
      );
    }
    for (final tech in howItWorksTechnologies) {
      await expectListed(find.descendant(of: sheet, matching: find.text(tech)));
    }
    await expectListed(find.text('Your privacy'));
    await expectListed(find.textContaining('Pantry photos, voice clips'));
    await expectListed(find.text('Safety'));
    await expectListed(find.text('Under the hood'));
    await expectListed(find.byKey(const ValueKey('devfest-x-ray-card')));
  }

  testWidgets('How it works opens from the pantry header', (tester) async {
    await phone(tester);
    final services = (await tester.runAsync(fakeServices))!;
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryFlow(
          services: services,
          isDemo: true,
          loadRecipes: () => SynchronousFuture(recipes),
          cookingBuilder: (recipe, back) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectSheet(tester, demo: true);
  });

  testWidgets('How it works and allergen chip appear on the cooking header', (
    tester,
  ) async {
    await phone(tester);
    final services = (await tester.runAsync(
      () => fakeServices(recipeId: 'peanut_butter_sandwich_v1'),
    ))!;
    await tester.pumpWidget(CookingApp(services: services, isDemo: true));
    await tester.pumpAndSettle();
    expect(find.text('Contains: wheat, peanut'), findsOneWidget);
    await expectSheet(tester, demo: true);
  });
}
