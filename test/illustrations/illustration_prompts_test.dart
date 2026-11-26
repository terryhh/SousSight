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
      instruction: 'Stir the yogurt and cilantro; set the tortillas aside.',
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
    expect(p.text, isNot(contains('set the tortillas aside')));
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

  RecipeStep step(String id, String instruction, [String cue = 'Golden.']) =>
      RecipeStep(id: id, title: 'Step', instruction: instruction, cue: cue);

  test('ingredient context: "them" in the oven is still the chicken', () {
    final r = recipe(
      ingredients: const [
        Ingredient(id: 'c', name: 'Chicken thighs', qty: '4'),
        Ingredient(id: 'o', name: 'Olive oil', qty: '1 tbsp'),
      ],
      steps: [
        step('season', 'Rub the thighs with olive oil.', 'Evenly coated.'),
        step('roast', 'Roast them in the oven.', 'Golden on both sides.'),
        step('rest', 'Rest, then slice.', 'Juices settle.'),
      ],
    );
    final season = illustrationPrompt(r, const StepTarget('season'))!;
    expect(season.subject, IllustrationSubject.ingredientsLaidOut);
    expect(season.text, contains('Chicken thighs'));
    expect(season.text, contains('before any cooking'));
    expect(season.text, isNot(contains('Evenly coated')));
    // Heat on a protein recipe, and everything after it: no picture.
    expect(illustrationPrompt(r, const StepTarget('roast')), isNull);
    expect(illustrationPrompt(r, const StepTarget('rest')), isNull);
    expect(illustrationPrompt(r, const PlateTarget()), isNull);
  });

  test('every common animal protein abstains from look and plate', () {
    for (final name in [
      'Chicken breast',
      'Turkey mince',
      'Duck legs',
      'Pork chops',
      'Bacon',
      'Ground beef',
      'Sirloin steak',
      'Lamb shoulder',
      'Italian sausages',
      'Trout fillets',
      'Salmon',
      'Cod loin',
      'Tilapia',
      'Halibut',
      'Tuna',
      'Shrimp',
      'Prawns',
      'Scallops',
      'Mussels',
      'Crab',
      'Eggs',
      'Egg yolks',
    ]) {
      final r = recipe(
        ingredients: [Ingredient(id: 'p', name: name, qty: '1')],
        steps: [step('cook', 'Sear in a hot pan for 4 minutes.', 'Browned.')],
      );
      expect(recipeHasAnimalProtein(r), isTrue, reason: name);
      expect(
        illustrationPrompt(r, const StepTarget('cook')),
        isNull,
        reason: name,
      );
      expect(illustrationPrompt(r, const PlateTarget()), isNull, reason: name);
    }
  });

  test('protein named only in a step still counts', () {
    final r = recipe(
      steps: [
        step('mix', 'Stir the yogurt.', 'Smooth.'),
        step('top', 'Lay the smoked trout on top.', 'Neat flakes.'),
      ],
    );
    expect(recipeHasAnimalProtein(r), isTrue);
    expect(illustrationPrompt(r, const PlateTarget()), isNull);
    // Steps before the protein appears may still be shown.
    expect(
      illustrationPrompt(r, const StepTarget('mix'))!.subject,
      IllustrationSubject.stepLook,
    );
    expect(illustrationPrompt(r, const StepTarget('top')), isNull);
  });

  test('protein steps that name no ingredient get no picture', () {
    final r = recipe(
      ingredients: const [Ingredient(id: 'y', name: 'Yogurt', qty: '1')],
      steps: [step('beat', 'Beat the eggs.', 'Pale yellow.')],
    );
    // "eggs" is in the step but no listed ingredient: nothing to lay out.
    expect(illustrationPrompt(r, const StepTarget('beat')), isNull);
  });

  test('a step that names no ingredient gets no ingredient list', () {
    final r = recipe(
      steps: [
        step('bowl', 'Set out a clean bowl.', 'An empty, dry bowl.'),
        step('stir', 'Stir the yogurt.', 'Smooth.'),
      ],
    );
    final p = illustrationPrompt(r, const StepTarget('bowl'))!;
    expect(p.text, isNot(contains('Ingredients')));
    expect(p.text, isNot(contains('yogurt')));
    expect(p.text, isNot(contains('Tortillas')));
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
