// SS-099: the recipe preview never shows a drafted summary, checks a
// drafted title minimally (the full drafted-text gate is SS-131), and
// compares draft ingredients with the household list by name as well as by
// tag. Built with buildDraftRecipe on fixed JSON; no model call.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/label/household_allergens.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/recipe_preview.dart';
import 'package:soussight/learner/recipe_preview_data.dart';
import 'package:soussight/pantry/recipe_draft_client.dart';

Map<String, dynamic> _draftJson({
  String summary = 'Warm toast with a crunchy topping.',
  String bakeInstruction = 'Toast the bread for about 3 minutes.',
  List<String> peanutAllergens = const [],
}) => {
  'title': 'Peanut toast',
  'summary': summary,
  'ingredients': [
    {
      'name': 'Bread',
      'fromConfirmed': 'bread',
      'qty': '2 slices',
      'optional': false,
      'allergens': ['wheat'],
    },
    {
      'name': 'Peanuts',
      'fromConfirmed': 'peanuts',
      'qty': '2 tbsp',
      'optional': false,
      'allergens': peanutAllergens,
    },
  ],
  'equipment': ['Toaster'],
  'steps': [
    {'title': 'Toast', 'instruction': bakeInstruction, 'cue': 'Golden.'},
    {'title': 'Chop', 'instruction': 'Chop the peanuts.', 'cue': 'Small.'},
    {'title': 'Top', 'instruction': 'Scatter them on.', 'cue': 'Even.'},
  ],
};

Recipe _build(Map<String, dynamic> json) => buildDraftRecipe(
  json,
  seed: 'test',
  confirmedItems: const ['bread', 'peanuts'],
);

void main() {
  group('previewTitle: a minimal check for drafted titles', () {
    Recipe titled(String title, {String id = 'draft_x'}) => Recipe(
      id: id,
      version: 1,
      title: title,
      summary: '',
      ingredients: const [],
      equipment: const [],
      steps: const [],
      checkpoints: const [],
      reviewedSubstitutions: const [],
      adjustmentLabels: const {},
    );
    for (final claim in [
      'Sesame-free tahini toast',
      'Zero peanuts toast',
      'Toast without peanuts',
      'Safe chicken salad',
      'Fully cooked chicken',
      'Fresh salsa',
      '165F chicken',
      'Camera-checked toast',
      'Allergen-friendly toast',
      'A very long title that goes on and on past what fits in the hero card',
      '   ',
    ]) {
      test('replaces "$claim"', () {
        expect(previewTitle(titled(claim)), kDraftTitleFallback);
      });
    }
    test('keeps a plain drafted title, and any reviewed title', () {
      expect(previewTitle(titled('Peanut toast')), 'Peanut toast');
      expect(
        previewTitle(titled('Fresh salsa', id: 'salsa_v1')),
        'Fresh salsa',
      );
    });
  });

  Future<void> pumpPreview(
    WidgetTester tester,
    Recipe recipe, {
    Set<String> household = const {},
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: RecipePreviewScreen(
          recipe: recipe,
          confirmedItems: const ['bread', 'peanuts'],
          household: InMemoryHouseholdAllergens(household),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a drafted summary is never shown; a reviewed one is', (
    tester,
  ) async {
    final built = _build(
      _draftJson(
        summary:
            'Serve the chicken as soon as the center is white. Zero peanuts.',
      ),
    );
    await pumpPreview(tester, built);
    expect(find.text('Peanut toast'), findsOneWidget);
    expect(find.textContaining('center is white'), findsNothing);
    expect(find.textContaining('Zero peanuts'), findsNothing);
    // The structured facts are still there.
    expect(find.byKey(const ValueKey('preview-ingredients')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-total-time')), findsOneWidget);

    final unsafeTitle = Recipe(
      id: built.id,
      version: 1,
      title: 'Sesame-free tahini toast',
      summary: '',
      ingredients: built.ingredients,
      equipment: built.equipment,
      steps: built.steps,
      checkpoints: const [],
      reviewedSubstitutions: const [],
      adjustmentLabels: const {},
    );
    await pumpPreview(tester, unsafeTitle);
    expect(find.textContaining('Sesame-free'), findsNothing);
    expect(find.text(kDraftTitleFallback), findsOneWidget);

    final reviewed = Recipe(
      id: 'toast_v1',
      version: 1,
      title: 'Peanut toast',
      summary: 'A reviewed summary.',
      ingredients: built.ingredients,
      equipment: built.equipment,
      steps: built.steps,
      checkpoints: const [],
      reviewedSubstitutions: const [],
      adjustmentLabels: const {},
    );
    await pumpPreview(tester, reviewed);
    expect(find.text('A reviewed summary.'), findsOneWidget);
  });

  testWidgets('an untagged peanut ingredient warns a peanut household', (
    tester,
  ) async {
    final recipe = _build(_draftJson());
    expect(recipe.ingredients[1].allergens, isEmpty);
    await pumpPreview(tester, recipe, household: {'peanut'});
    await tester.ensureVisible(find.byKey(const ValueKey('preview-allergens')));
    expect(
      find.text(
        'An ingredient name suggests peanut, which is on your household list '
        '— check the ingredients and labels yourself.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('preview-hint-line')), findsOneWidget);
    expect(find.textContaining('doesn’t mention'), findsNothing);
    expect(find.textContaining('found no match'), findsNothing);
  });

  testWidgets('a tagged peanut ingredient is a direct household match', (
    tester,
  ) async {
    final recipe = _build(_draftJson(peanutAllergens: ['peanut']));
    await pumpPreview(tester, recipe, household: {'peanut'});
    await tester.ensureVisible(find.byKey(const ValueKey('preview-allergens')));
    expect(
      find.text(
        'The recipe mentions peanut, which is on your household list — '
        'check labels yourself.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('preview-hint-line')), findsNothing);
  });
}
