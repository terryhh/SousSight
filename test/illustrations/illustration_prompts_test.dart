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

  test('safety notes never reach a prompt, but keep the heat note on', () {
    final cue = 'Golden at the edges. $kHeatDisclaimer The camera cannot tell.';
    expect(visibleCue(cue), 'Golden at the edges.');
    final r = recipe(
      steps: [
        RecipeStep(
          id: 'warm',
          title: 'Warm',
          instruction: 'Warm the tortilla.', // no heat word the regex knows
          cue: cue,
        ),
      ],
    );
    final p = illustrationPrompt(r, const StepTarget('warm'))!;
    // The drafter's heat note marks the step as heated for the panel.
    expect(p.heated, isTrue);
    expect(p.subject, IllustrationSubject.stepLook);
    expect(p.text, isNot(contains('camera')));
    expect(illustrationPrompt(r, const PlateTarget())!.heated, isTrue);
  });

  test('a doneness assertion means no picture, step or plate', () {
    for (final cue in [
      'It is fully cooked when golden.',
      'Cook until done.',
      'The flesh turns opaque.',
      'It flakes easily with a fork.',
      'Juices run clear.',
      'No longer pink inside.',
    ]) {
      final r = recipe(
        steps: [
          RecipeStep(id: 's', title: 'S', instruction: 'Bake it.', cue: cue),
        ],
      );
      expect(illustrationPrompt(r, const StepTarget('s')), isNull, reason: cue);
      expect(illustrationPrompt(r, const PlateTarget()), isNull, reason: cue);
    }
  });

  test("the drafter's thermometer note marks a protein recipe", () {
    final r = recipe(
      steps: [
        const RecipeStep(
          id: 'prep',
          title: 'Prep',
          instruction: 'Stir the yogurt.',
          cue: 'Smooth.',
        ),
        RecipeStep(
          id: 'cook',
          title: 'Cook',
          instruction: 'Cook it through.',
          cue: 'Golden. $kThermometerDisclaimer',
        ),
      ],
    );
    expect(recipeHasAnimalProtein(r), isTrue);
    expect(illustrationPrompt(r, const StepTarget('cook')), isNull);
    expect(illustrationPrompt(r, const PlateTarget()), isNull);
  });

  test('structured fish, shellfish and egg tags count (hake, gravlax)', () {
    for (final (name, tag) in [
      ('Hake', 'fish'),
      ('Gravlax', 'fish'),
      ('Langoustines', 'shellfish'),
      ('Kedgeree base', 'egg'),
    ]) {
      final r = recipe(
        ingredients: [
          Ingredient(id: 'p', name: name, qty: '1', allergens: [tag]),
        ],
        steps: const [
          RecipeStep(
            id: 'cook',
            title: 'Cook',
            instruction: 'Pan-fry for 4 minutes.',
            cue: 'Golden.',
          ),
        ],
      );
      expect(recipeHasAnimalProtein(r), isTrue, reason: name);
      expect(
        illustrationPrompt(r, const StepTarget('cook')),
        isNull,
        reason: name,
      );
      expect(illustrationPrompt(r, const PlateTarget()), isNull, reason: name);
    }
    // A shelf-stable product's tag says nothing about doneness.
    for (final name in ['Mayonnaise', 'Worcestershire sauce', 'Egg noodles']) {
      expect(
        isAnimalProtein(
          Ingredient(
            id: 'x',
            name: name,
            qty: '',
            allergens: const ['egg', 'fish'],
          ),
        ),
        name == 'Egg noodles', // "egg" in the name still counts
        reason: name,
      );
    }
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

  testWidgets('the reviewed recipes have no animal protein; only warming '
      'the tortilla is heat', (tester) async {
    final recipes = await tester.runAsync(loadRecipeCatalog);
    for (final r in recipes!) {
      expect(recipeHasAnimalProtein(r), isFalse, reason: r.id);
      final plate = illustrationPrompt(r, const PlateTarget());
      expect(plate, isNotNull, reason: r.id);
      expect(plate!.heated, r.id == 'chickpea_wrap_v1', reason: r.id);
      for (final s in r.steps) {
        final p = illustrationPrompt(r, StepTarget(s.id));
        expect(p?.subject, IllustrationSubject.stepLook, reason: s.id);
        expect(
          p!.heated,
          r.id == 'chickpea_wrap_v1' && s.id == 'roll',
          reason: '${r.id}/${s.id}',
        );
      }
    }
  });

  test(
    'a shellfish-tagged composite counts; a "safe to serve" cue abstains',
    () {
      final r = recipe(
        ingredients: const [
          Ingredient(
            id: 'l',
            name: 'Langoustines in garlic sauce',
            qty: '300 g',
            allergens: ['shellfish'],
          ),
        ],
        steps: const [
          RecipeStep(
            id: 'warm',
            title: 'Warm',
            instruction: 'Warm them through.',
            cue: 'Once golden, they are safe to serve.',
          ),
        ],
      );
      expect(isAnimalProtein(r.ingredients.single), isTrue);
      expect(illustrationPrompt(r, const StepTarget('warm')), isNull);
      expect(illustrationPrompt(r, const PlateTarget()), isNull);
      // Even without protein, a safety claim from appearance abstains.
      final veg = recipe(
        steps: const [
          RecipeStep(
            id: 's',
            title: 'S',
            instruction: 'Stir the yogurt.',
            cue: 'Smooth, so it is safe to eat.',
          ),
        ],
      );
      expect(illustrationPrompt(veg, const StepTarget('s')), isNull);
      expect(illustrationPrompt(veg, const PlateTarget()), isNull);
      // Identified shelf-stable products stay exempt from their tags.
      for (final name in ['Mayonnaise', 'Worcestershire sauce', 'Bread']) {
        expect(
          isAnimalProtein(
            Ingredient(id: 'x', name: name, qty: '', allergens: const ['egg']),
          ),
          isFalse,
          reason: name,
        );
      }
      for (final name in ['Garlic sauce', 'Aioli', 'Fresh pasta']) {
        expect(
          isAnimalProtein(
            Ingredient(id: 'x', name: name, qty: '', allergens: const ['egg']),
          ),
          isTrue,
          reason: name,
        );
      }
    },
  );

  test('"raw" is not protein: raw carrots keep their pictures', () {
    final r = recipe(
      ingredients: const [
        Ingredient(id: 'c', name: 'Carrots', qty: '3'),
        Ingredient(id: 'w', name: 'Water', qty: '1 cup'),
      ],
      steps: const [
        RecipeStep(
          id: 'arrange',
          title: 'Arrange',
          instruction: 'Arrange raw carrots on a board.',
          cue: 'Carrot sticks in a neat row.',
        ),
      ],
    );
    expect(recipeHasAnimalProtein(r), isFalse);
    expect(
      illustrationPrompt(r, const StepTarget('arrange'))!.subject,
      IllustrationSubject.stepLook,
    );
    expect(illustrationPrompt(r, const PlateTarget()), isNotNull);
  });

  test('ingredients match as whole words, not prefixes', () {
    final r = recipe(
      ingredients: const [
        Ingredient(id: 's', name: 'Salt', qty: 'pinch'),
        Ingredient(id: 'c', name: 'Saltine crackers', qty: '8'),
        Ingredient(id: 'm', name: 'Mayonnaise', qty: '2 tbsp'),
        Ingredient(id: 't', name: 'Tomatoes', qty: '2'),
      ],
      steps: const [
        RecipeStep(
          id: 'season',
          title: 'Season',
          instruction: 'Add salt and the mayo, then one tomato.',
          cue: 'Evenly seasoned.',
        ),
        RecipeStep(
          id: 'serve',
          title: 'Serve',
          instruction: 'Serve with saltines.',
          cue: 'Crackers on the side.',
        ),
      ],
    );
    final p = illustrationPrompt(r, const StepTarget('season'))!.text;
    expect(
      p,
      contains('Ingredients in this step: Salt; Mayonnaise; Tomatoes.'),
    );
    expect(p, isNot(contains('Saltine')));
    expect(
      illustrationPrompt(r, const StepTarget('serve'))!.text,
      contains('Saltine crackers'),
    );
  });

  test('the revision changes with content, not with identity alone', () {
    final a = recipe();
    final b = recipe();
    expect(illustrationRevision(a), illustrationRevision(b));
    final edited = recipe(
      steps: const [
        RecipeStep(
          id: 'stir',
          title: 'Stir',
          instruction: 'Stir the yogurt and cilantro; set the tortillas aside.',
          cue: 'Thick and smooth.',
        ),
      ],
    );
    expect(illustrationRevision(edited), isNot(illustrationRevision(a)));
  });

  group('on-demand allowlist (AI drafts)', () {
    RecipeStep st(String id, String instruction, String cue) =>
        RecipeStep(id: id, title: 'Step', instruction: instruction, cue: cue);

    test(
      'rabbit with a temperature claim: no step, no plate, either builder',
      () {
        final r = recipe(
          ingredients: const [
            Ingredient(id: 'r', name: 'Rabbit legs', qty: '2'),
          ],
          steps: [
            st(
              'crust',
              'Brown in a pan.',
              'A brown crust means the center has reached 165°F.',
            ),
          ],
        );
        expect(recipeHasAnimalProtein(r), isTrue);
        expect(assertsDoneness('the center has reached 165°F'), isTrue);
        for (final build in [illustrationPrompt, onDemandIllustrationPrompt]) {
          expect(build(r, const StepTarget('crust')), isNull);
          expect(build(r, const PlateTarget()), isNull);
        }
      },
    );

    test('the shelf-stable exemption reads the full name', () {
      expect(
        isAnimalProtein(
          const Ingredient(
            id: 'c',
            name: 'Crackers (langoustines)',
            qty: '',
            allergens: ['shellfish'],
          ),
        ),
        isTrue,
      );
      expect(
        isAnimalProtein(
          const Ingredient(
            id: 'm',
            name: 'Mayonnaise',
            qty: '',
            allergens: ['egg'],
          ),
        ),
        isFalse,
        reason: 'reviewed builder only',
      );
    });

    test('drafts get no exemption: any fish, shellfish or egg tag blocks', () {
      final r = recipe(
        ingredients: const [
          Ingredient(id: 'm', name: 'Mayonnaise', qty: '', allergens: ['egg']),
          Ingredient(id: 'c', name: 'Cucumber', qty: '1'),
        ],
        steps: [st('mix', 'Stir the cucumber into the mayonnaise.', 'Even.')],
      );
      expect(draftHasAnimalProtein(r), isTrue);
      expect(onDemandIllustrationPrompt(r, const StepTarget('mix')), isNull);
      expect(onDemandIllustrationPrompt(r, const PlateTarget()), isNull);
    });

    test('minced garlic is not protein', () {
      final r = recipe(
        ingredients: const [
          Ingredient(id: 'g', name: 'Garlic, minced', qty: '2 cloves'),
          Ingredient(id: 'w', name: 'Water', qty: '1 cup'),
        ],
        steps: [
          st('stir', 'Stir the garlic into the water.', 'Flecks of garlic.'),
        ],
      );
      expect(recipeHasAnimalProtein(r), isFalse);
      expect(draftHasAnimalProtein(r), isFalse);
      expect(
        onDemandIllustrationPrompt(r, const StepTarget('stir'))!.subject,
        IllustrationSubject.stepLook,
      );
      expect(onDemandIllustrationPrompt(r, const PlateTarget()), isNotNull);
    });

    test('any heat blocks the step; any heated step blocks the plate', () {
      for (final instruction in [
        'Warm the tortilla.',
        'Microwave for 20 seconds.',
        'Put it in the oven.',
        'Cook gently.',
        'Bring to a boil.',
        'Sauté the onions.',
        'Grill the peppers.',
        'Toast the bread.',
      ]) {
        final r = recipe(
          steps: [
            st('prep', 'Stir the yogurt.', 'Smooth.'),
            st('hot', instruction, 'Soft.'),
          ],
        );
        expect(
          onDemandIllustrationPrompt(r, const StepTarget('hot')),
          isNull,
          reason: instruction,
        );
        expect(
          onDemandIllustrationPrompt(r, const PlateTarget()),
          isNull,
          reason: instruction,
        );
        expect(
          onDemandIllustrationPrompt(r, const StepTarget('prep')),
          isNotNull,
          reason: 'a no-heat step of a cooked recipe may still be shown',
        );
      }
    });

    test('the step prompt carries only its cue and its own ingredients', () {
      final r = recipe(
        ingredients: const [
          Ingredient(id: 'l', name: 'Lemon juice', qty: '1 tbsp'),
          Ingredient(id: 'o', name: 'Red onion', qty: '1'),
          Ingredient(id: 'c', name: 'Chickpeas', qty: '1 can'),
        ],
        steps: [
          st('pickle', 'Put the onion in lemon juice.', 'Bright pink.'),
          st('mash', 'Mash the chickpeas.', 'Chunky, not a paste.'),
        ],
      );
      final p = onDemandIllustrationPrompt(r, const StepTarget('mash'))!.text;
      expect(p, contains('Chunky, not a paste.'));
      expect(p, contains('Ingredients in this step: Chickpeas.'));
      expect(p, isNot(contains('Lemon')));
      expect(p, isNot(contains('onion')));
      expect(p, isNot(contains('earlier')));
      expect(
        p,
        isNot(contains('Mash the chickpeas')),
        reason: 'no instruction',
      );
    });

    test('doneness and safety text never reaches an on-demand prompt', () {
      final r = recipe(
        steps: [st('s', 'Stir the yogurt.', 'Smooth and safe to eat.')],
      );
      expect(onDemandIllustrationPrompt(r, const StepTarget('s')), isNull);
      expect(onDemandIllustrationPrompt(r, const PlateTarget()), isNull);
      expect(onDemandIllustrationPrompt(r, const StepTarget('nope')), isNull);
      final empty = recipe(steps: [st('e', 'Stir the yogurt.', '')]);
      expect(onDemandIllustrationPrompt(empty, const StepTarget('e')), isNull);
    });
  });
}
