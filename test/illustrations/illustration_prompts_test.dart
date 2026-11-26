import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/illustrations/illustration_prompts.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/pantry/recipe_draft_client.dart'
    show kHeatDisclaimer, kThermometerDisclaimer;

Recipe recipe({
  String id = 'draft_test',
  List<Ingredient> ingredients = const [
    Ingredient(id: 'a', name: 'Plain yogurt', qty: '1 cup'),
    Ingredient(
      id: 'b',
      name: 'Tortillas (flour tortillas contain wheat; check labels)',
      qty: '2',
    ),
    Ingredient(id: 'c', name: 'Cilantro, only if the cook likes it', qty: ''),
  ],
  List<RecipeStep> steps = const [
    RecipeStep(
      id: 'stir',
      title: 'Stir',
      instruction: 'Stir everything together.',
      cue: 'Evenly mixed with no streaks.',
    ),
  ],
}) => Recipe(
  id: id,
  version: 1,
  title: 'Test Dish',
  summary: '',
  ingredients: ingredients,
  equipment: const [],
  steps: steps,
  checkpoints: const [],
  reviewedSubstitutions: const [],
  adjustmentLabels: const {},
);

void main() {
  test('targets have distinct, stable keys and value equality', () {
    expect(const StepTarget('mash').key, 'step_mash');
    expect(const PlateTarget().key, 'plate');
    expect(const StepTarget('plate').key, isNot(const PlateTarget().key));
    expect(const StepTarget('a'), const StepTarget('a'));
    expect(const StepTarget('a').hashCode, const StepTarget('a').hashCode);
    expect(const StepTarget('a'), isNot(const StepTarget('b')));
    expect(const PlateTarget(), const PlateTarget());
    expect(const PlateTarget().hashCode, const PlateTarget().hashCode);
  });

  test('a step prompt uses only the visible cue and the ingredients', () {
    final p = illustrationPrompt(recipe(), const StepTarget('stir'))!;
    expect(p.subject, IllustrationSubject.stepLook);
    expect(p.heated, isFalse);
    expect(p.text, contains('Evenly mixed with no streaks.'));
    expect(p.text, contains('Plain yogurt; Tortillas; Cilantro'));
    // Not the title or instruction, and no bracketed or "only if" notes.
    expect(p.text, isNot(contains('Stir everything together')));
    expect(p.text, isNot(contains('check labels')));
    expect(p.text, isNot(contains('only if')));
    expect(p.text, contains('not photorealistic'));
    expect(p.text, contains('no text'));
  });

  test('safety and doneness sentences never reach a prompt', () {
    final cue =
        'Golden at the edges. $kHeatDisclaimer The camera cannot tell. '
        '$kThermometerDisclaimer';
    expect(visibleCue(cue), 'Golden at the edges.');
    final r = recipe(
      steps: [
        RecipeStep(
          id: 'toast',
          title: 'Toast',
          instruction: 'Toast the tortilla in a dry pan.',
          cue: cue,
        ),
      ],
    );
    final p = illustrationPrompt(r, const StepTarget('toast'))!;
    expect(p.heated, isTrue);
    expect(p.subject, IllustrationSubject.stepLook);
    expect(p.text, isNot(contains('thermometer')));
    expect(p.text, isNot(contains('safety')));
  });

  test('meat, poultry, fish and egg steps get ingredients laid out', () {
    for (final text in [
      'Cook the chicken until golden.',
      'Scramble the eggs.',
      'Brown the ground beef.',
      'Sear the salmon.',
    ]) {
      final r = recipe(
        steps: [
          RecipeStep(id: 's', title: 'Step', instruction: text, cue: 'Golden.'),
        ],
      );
      final p = illustrationPrompt(r, const StepTarget('s'))!;
      expect(p.subject, IllustrationSubject.ingredientsLaidOut, reason: text);
      expect(p.text, contains('before any cooking'));
      expect(p.text, contains('Show no cooked food'));
      expect(p.text, isNot(contains('Golden')), reason: 'no doneness cue');
    }
  });

  test('no finished plate for a recipe with animal protein', () {
    final byIngredient = recipe(
      ingredients: const [Ingredient(id: 'e', name: 'Eggs', qty: '2')],
    );
    expect(illustrationPrompt(byIngredient, const PlateTarget()), isNull);
    final byStep = recipe(
      steps: const [
        RecipeStep(
          id: 's',
          title: 'Add tuna',
          instruction: 'Fold in the tuna.',
          cue: 'Flaked.',
        ),
      ],
    );
    expect(illustrationPrompt(byStep, const PlateTarget()), isNull);
    expect(recipeHasAnimalProtein(byIngredient), isTrue);
    expect(recipeHasAnimalProtein(recipe()), isFalse);
  });

  test('a plate prompt names the dish and marks heat', () {
    final p = illustrationPrompt(recipe(), const PlateTarget())!;
    expect(p.subject, IllustrationSubject.finishedPlate);
    expect(p.text, contains('"Test Dish"'));
    expect(p.heated, isFalse);
    final heated = recipe(
      steps: const [
        RecipeStep(
          id: 'b',
          title: 'Bake',
          instruction: 'Bake for 10 minutes.',
          cue: 'Crisp.',
        ),
      ],
    );
    expect(illustrationPrompt(heated, const PlateTarget())!.heated, isTrue);
  });

  test('an unknown step or a step without a cue gets no prompt', () {
    expect(illustrationPrompt(recipe(), const StepTarget('nope')), isNull);
    final empty = recipe(
      steps: const [
        RecipeStep(id: 's', title: 'S', instruction: 'Wait.', cue: ''),
      ],
    );
    expect(illustrationPrompt(empty, const StepTarget('s')), isNull);
  });

  test('"the cook" is not heat; the verb is', () {
    expect(mentionsHeat("Taste is the cook's call."), isFalse);
    expect(mentionsHeat('Jam is a cook choice.'), isFalse);
    expect(mentionsHeat('Cook until soft.'), isTrue);
    expect(mentionsHeat('Toast the bread.'), isTrue);
  });

  test('ingredient names drop notes', () {
    expect(ingredientForPrompt('Salt'), 'Salt');
    expect(
      ingredientForPrompt('Tortilla chips (check labels), for serving'),
      'Tortilla chips',
    );
    expect(ingredientForPrompt('Jam, only if the cook chooses it'), 'Jam');
  });

  testWidgets('the reviewed recipes have no animal protein and no heat', (
    tester,
  ) async {
    final recipes = await tester.runAsync(loadRecipeCatalog);
    for (final r in recipes!) {
      expect(recipeHasAnimalProtein(r), isFalse, reason: r.id);
      final plate = illustrationPrompt(r, const PlateTarget());
      expect(plate, isNotNull, reason: r.id);
      expect(plate!.heated, isFalse, reason: r.id);
      for (final s in r.steps) {
        final p = illustrationPrompt(r, StepTarget(s.id));
        expect(p?.subject, IllustrationSubject.stepLook, reason: s.id);
      }
    }
  });
}
