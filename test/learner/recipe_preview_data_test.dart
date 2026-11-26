// SS-099 recipe preview data. Pure functions over on-device data; no model.

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/recipe_preview_data.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

const _salsa = Recipe(
  id: 'black_bean_corn_salsa_v1',
  version: 1,
  title: 'Black Bean & Corn Salsa',
  summary: 'A no-cook salsa.',
  ingredients: [
    Ingredient(
      id: 'black_beans',
      name: 'Canned black beans, drained and rinsed',
      qty: '1 can',
    ),
    Ingredient(id: 'corn', name: 'Canned corn, drained', qty: '1 can'),
    Ingredient(id: 'red_onion', name: 'Red onion, finely diced', qty: '1/4'),
    Ingredient(id: 'cilantro', name: 'Cilantro', qty: '2 tbsp', optional: true),
    Ingredient(
      id: 'tortillas',
      name: 'Tortilla chips (check labels)',
      qty: 'a handful',
      allergens: ['wheat'],
    ),
    Ingredient(
      id: 'peanuts',
      name: 'Peanuts',
      qty: 'a few',
      optional: true,
      allergens: ['Peanuts'],
    ),
  ],
  equipment: ['Bowl', ' ', 'Spoon '],
  steps: [
    RecipeStep(id: 'a', title: 'A', instruction: 'a', cue: ''),
    RecipeStep(id: 'b', title: 'B', instruction: 'b', cue: ''),
    RecipeStep(
      id: 'c',
      title: 'C',
      instruction: 'c',
      cue: '',
      timerSeconds: 290,
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

Recipe _withAllergens(List<List<String>> tags) => Recipe(
  id: 'r',
  version: 1,
  title: 'R',
  summary: '',
  ingredients: [
    for (var i = 0; i < tags.length; i++)
      Ingredient(id: 'i$i', name: 'I$i', qty: '', allergens: tags[i]),
  ],
  equipment: const [],
  steps: const [],
  checkpoints: const [],
  reviewedSubstitutions: const [],
  adjustmentLabels: const {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ingredient identity against the bundled recipes', () {
    late Map<String, Recipe> byId;
    setUpAll(() async {
      byId = {for (final r in await loadRecipeCatalog()) r.id: r};
    });

    Ingredient ingredient(String recipe, String id) =>
        byId[recipe]!.ingredients.firstWhere((i) => i.id == id);

    List<String> have(String recipe, List<String> items) => [
      for (final i in previewIngredients(
        byId[recipe]!,
        items,
        pantryChecked: true,
      ).have)
        i.id,
    ];

    test('a different food never ticks an ingredient', () {
      expect(have('black_bean_corn_salsa_v1', ['corn starch']), isEmpty);
      expect(have('black_bean_corn_salsa_v1', ['corn chips']), isEmpty);
      expect(have('black_bean_corn_salsa_v1', ['onion']), isEmpty);
      expect(have('black_bean_corn_salsa_v1', ['lime soda']), isEmpty);
      expect(have('chickpea_wrap_v1', ['tortillas']), isEmpty); // flour
      expect(have('chickpea_wrap_v1', ['mustard']), isEmpty); // Dijon
      expect(have('chickpea_wrap_v1', ['salt']), isEmpty);
      expect(have('peanut_butter_sandwich_v1', ['peanuts']), isEmpty);
    });

    test('an optional item never moves the required count', () {
      final salsa = byId['black_bean_corn_salsa_v1']!;
      final none = previewIngredients(salsa, const [], pantryChecked: true);
      final cilantro = previewIngredients(salsa, const [
        'cilantro',
      ], pantryChecked: true);
      expect((none.requiredHave, none.requiredTotal), (0, 7));
      expect((cilantro.requiredHave, cilantro.requiredTotal), (0, 7));
      expect([for (final i in cilantro.have) i.id], ['cilantro']);
    });

    test('a reviewed substitute is its own item, never the fresh '
        'ingredient', () {
      final salsa = byId['black_bean_corn_salsa_v1']!;
      final result = previewIngredients(salsa, const [
        'Canned diced tomatoes, drained',
        'bottled lime juice',
      ], pantryChecked: true);
      expect(result.have, isEmpty);
      expect(
        [for (final s in result.substituted) s.ingredient.id],
        ['tomato', 'lime'],
      );
      expect(
        result.substituted.first.substitution.note,
        contains('no dicing needed'),
      );
      expect([for (final i in result.missing) i.id], isNot(contains('tomato')));
      expect((result.requiredHave, result.requiredTotal), (0, 7));
      // Fresh tomatoes and plain lime juice are the ingredient itself.
      expect(have('black_bean_corn_salsa_v1', ['fresh tomatoes']), ['tomato']);
      expect(have('black_bean_corn_salsa_v1', ['lime juice']), ['lime']);
      // A form the recipe allows still matches ("fresh or bottled").
      expect(have('chickpea_wrap_v1', ['bottled lemon juice']), ['lemon']);
    });

    test('a draft keeps its validated fromConfirmed association', () {
      const draft = Recipe(
        id: 'draft_soup',
        version: 1,
        title: 'Chicken soup',
        summary: '',
        ingredients: [
          Ingredient(id: 'milk_coconut', name: 'Milk (coconut)', qty: ''),
        ],
        equipment: [],
        steps: [],
        checkpoints: [],
        reviewedSubstitutions: [],
        adjustmentLabels: {},
      );
      final milk = draft.ingredients.single;
      expect(previewHasIngredient(draft, milk, ['1 cup coconut milk']), isTrue);
      expect(previewHasIngredient(draft, milk, ['milk']), isFalse);
      // A reviewed recipe gets no draft-key match.
      final reviewed = Recipe(
        id: 'soup_v1',
        version: 1,
        title: draft.title,
        summary: '',
        ingredients: draft.ingredients,
        equipment: const [],
        steps: const [],
        checkpoints: const [],
        reviewedSubstitutions: const [],
        adjustmentLabels: const {},
      );
      expect(
        previewHasIngredient(reviewed, milk, ['1 cup coconut milk']),
        isFalse,
      );
      expect(previewHasIngredient(reviewed, milk, ['coconut milk']), isTrue);
    });

    test('bundled names suggest no allergen their tags miss', () {
      for (final recipe in byId.values) {
        expect(
          PreviewAllergens(recipe, const {}).nameHints,
          isEmpty,
          reason: recipe.id,
        );
      }
    });

    test('real names, plurals, packaging words and aliases match', () {
      expect(have('chickpea_wrap_v1', ['Mayonnaise']), ['mayo']);
      expect(have('chickpea_wrap_v1', ['a jar of mayo']), ['mayo']);
      expect(have('chickpea_wrap_v1', ['garbanzo beans']), ['chickpeas']);
      expect(have('chickpea_wrap_v1', ['lemons']), ['lemon']);
      expect(have('chickpea_wrap_v1', ['salt and pepper']), ['salt_pepper']);
      expect(have('chickpea_wrap_v1', ['flour tortillas']), ['tortillas']);
      expect(have('black_bean_corn_salsa_v1', ['canned corn']), ['corn']);
      expect(have('black_bean_corn_salsa_v1', ['tomatoes']), ['tomato']);
      expect(have('black_bean_corn_salsa_v1', ['lime']), ['lime']);
      expect(have('black_bean_corn_salsa_v1', ['tortilla chips']), [
        'tortillas',
      ]);
      expect(have('black_bean_corn_salsa_v1', ['2 cans black beans']), [
        'black_beans',
      ]);
      expect(have('peanut_butter_sandwich_v1', ['PB', 'sliced bread']), [
        'bread',
        'peanut_butter',
      ]);
    });

    test('a qualifier that names the food is kept', () {
      const coconutMilk = Ingredient(id: 'm', name: 'Milk (coconut)', qty: '');
      expect(previewItemMatches('milk', coconutMilk), isFalse);
      expect(previewItemMatches('coconut milk', coconutMilk), isTrue);
      expect(previewItemMatches('Milk (coconut)', coconutMilk), isTrue);
      const oats = Ingredient(
        id: 'o',
        name: 'Oats, rolled (about 1 cup, if needed)',
        qty: '',
      );
      expect(previewItemMatches('rolled oats', oats), isTrue);
      expect(previewItemMatches('oats', oats), isFalse);
      const note = Ingredient(
        id: 'n',
        name: 'Jam, only if the cook chooses it',
        qty: '',
      );
      expect(previewItemMatches('jam', note), isTrue);
    });

    test('plurals reduce to one food word', () {
      expect(previewFoodWords('Berries'), {'berry'});
      expect(previewFoodWords('peaches and radishes'), {'peach', 'radish'});
      expect(previewFoodWords('glasses'), {'glass'});
      expect(previewFoodWords('glass'), {'glass'});
    });

    test('every bundled ingredient matches its verbatim display name', () {
      for (final recipe in byId.values) {
        for (final i in recipe.ingredients) {
          expect(previewItemMatches(i.name, i), isTrue, reason: i.name);
        }
      }
      // Size, serving and preparation qualifiers do not change the food.
      final wrapTortillas = ingredient('chickpea_wrap_v1', 'tortillas');
      expect(wrapTortillas.name, 'Flour tortillas (10 inch)');
      expect(previewItemMatches('flour tortillas', wrapTortillas), isTrue);
      expect(
        previewItemMatches('Flour tortillas (10 inch)', wrapTortillas),
        isTrue,
      );
      final onion = ingredient('chickpea_wrap_v1', 'red_onion');
      expect(previewItemMatches('red onion', onion), isTrue);
      expect(previewItemMatches('red onions', onion), isTrue);
      expect(
        previewItemMatches('  ', ingredient('chickpea_wrap_v1', 'mayo')),
        isFalse,
      );
    });
  });

  group('previewIngredients', () {
    test('splits have, missing and optional with the hand-off matcher', () {
      final result = previewIngredients(_salsa, [
        'canned black beans',
        'corn',
        'onion', // "red onion" is a different food: "red" is kept
        '  ',
      ], pantryChecked: true);
      expect(result.pantryChecked, isTrue);
      expect([for (final i in result.have) i.id], ['black_beans', 'corn']);
      expect(
        [for (final i in result.missing) i.id],
        ['red_onion', 'tortillas'],
      );
      expect(
        [for (final i in result.optionalMissing) i.id],
        ['cilantro', 'peanuts'],
      );
      // Required only, on both sides: black beans and corn of four.
      expect(result.requiredHave, 2);
      expect(result.requiredTotal, 4);
    });

    test('a skipped check makes no have claims', () {
      final result = previewIngredients(_salsa, const [
        '',
        ' ',
      ], pantryChecked: false);
      expect(result.pantryChecked, isFalse);
      expect(result.have, isEmpty);
      expect(result.missing, hasLength(4));
    });

    test('a check with nothing confirmed is not a skip', () {
      final result = previewIngredients(_salsa, const [], pantryChecked: true);
      expect(result.pantryChecked, isTrue);
      expect(result.have, isEmpty);
      expect(result.missing, hasLength(4));
    });

    test('confirmed items always count as a check', () {
      final result = previewIngredients(_salsa, const [
        'corn',
      ], pantryChecked: false);
      expect(result.pantryChecked, isTrue);
    });
  });

  group('time', () {
    test('hands-on per step plus timer waits, rounded up', () {
      final time = previewTime(_salsa);
      expect(
        time.activeMinutes,
        2 * kPreviewMinutesPerStep + kPreviewMinutesPerTimedStep,
      );
      expect(time.totalMinutes, time.activeMinutes + 5);
    });

    test('formats minutes and hours', () {
      expect(formatPreviewMinutes(7), '7 min');
      expect(formatPreviewMinutes(60), '1 hr');
      expect(formatPreviewMinutes(65), '1 hr 5 min');
    });
  });

  group('allergen wording never certifies safety', () {
    test('mentions with no household list saved', () {
      final a = PreviewAllergens(_salsa, const {});
      expect(a.householdSaved, isFalse);
      expect(a.householdLine, isNull);
      expect(
        a.mentionLine,
        'The recipe mentions wheat and Peanuts (optional ingredient) '
        '— check labels yourself.',
      );
    });

    test('a household match is named, plural tags normalised', () {
      final a = PreviewAllergens(_salsa, const {'peanut', 'milk'});
      expect([for (final m in a.householdMatches) m.name], ['Peanuts']);
      expect(
        a.householdLine,
        'The recipe mentions Peanuts, which is on your household list '
        '— check labels yourself.',
      );
    });

    test('several matches use "are"', () {
      final a = PreviewAllergens(_salsa, const {'peanut', 'wheat'});
      expect(
        a.householdLine,
        'The recipe mentions wheat and Peanuts, which are on your household '
        'list — check labels yourself.',
      );
    });

    test('no match never reads as absence', () {
      final a = PreviewAllergens(_salsa, const {'milk', 'egg'});
      expect(
        a.householdLine,
        'The app found no match for your household allergens (egg and milk) '
        'in this recipe. That doesn’t rule them out — check the ingredients '
        'and labels yourself.',
      );
      expect(a.householdLine, isNot(contains('safe')));
      expect(a.householdLine, isNot(contains('doesn’t mention')));
    });

    test('an untagged ingredient name still warns the household', () {
      const toast = Recipe(
        id: 'draft_peanut',
        version: 1,
        title: 'Peanut toast',
        summary: '',
        ingredients: [
          Ingredient(id: 'peanuts', name: 'Peanuts, chopped', qty: ''),
          Ingredient(id: 'toast', name: 'Toast', qty: ''),
        ],
        equipment: [],
        steps: [],
        checkpoints: [],
        reviewedSubstitutions: [],
        adjustmentLabels: {},
      );
      final a = PreviewAllergens(toast, const {'peanut'});
      expect(a.mentioned, isEmpty);
      expect(a.nameHints, ['peanut']);
      expect(a.householdWarning, isTrue);
      expect(
        a.householdLine,
        'An ingredient name suggests peanut, which is on your household list '
        '— check the ingredients and labels yourself.',
      );
      expect(a.hintLine, contains('Ingredient names suggest peanut'));
      expect(
        PreviewAllergens(toast, const {'peanut', 'milk'}).householdLine,
        contains('suggests peanut, which is'),
      );
    });

    test('name hints: plant milks and nut butters are not dairy; tagged '
        'allergens are not repeated', () {
      Recipe named(List<String> names, {List<String> tags = const []}) =>
          Recipe(
            id: 'r',
            version: 1,
            title: 'R',
            summary: '',
            ingredients: [
              for (final n in names)
                Ingredient(id: n, name: n, qty: '', allergens: tags),
            ],
            equipment: const [],
            steps: const [],
            checkpoints: const [],
            reviewedSubstitutions: const [],
            adjustmentLabels: const {},
          );
      expect(previewAllergenHints(named(['Coconut milk', 'Peanut butter'])), [
        'peanut',
      ]);
      expect(previewAllergenHints(named(['Butter', 'Tahini', 'Shrimp'])), [
        'milk',
        'shellfish',
        'sesame',
      ]);
      expect(
        PreviewAllergens(named(['Bread'], tags: ['wheat']), const {
          'wheat',
        }).nameHints,
        isEmpty,
      );
      expect(
        PreviewAllergens(named(['Bread']), const {}).householdLine,
        isNull,
      );
    });

    test('a recipe with no tags', () {
      final a = PreviewAllergens(_withAllergens([[], []]), const {'soy'});
      expect(
        a.mentionLine,
        'The recipe doesn’t list any allergens — check labels yourself.',
      );
    });

    test('three or more are listed with commas', () {
      final a = PreviewAllergens(
        _withAllergens([
          ['egg'],
          ['soy', 'fish'],
        ]),
        const {'shellfish', 'sesame', 'tree nut'},
      );
      expect(
        a.mentionLine,
        'The recipe mentions egg, soy and fish — check labels yourself.',
      );
      expect(a.householdLine, contains('(sesame, shellfish and tree nut)'));
      expect(a.hintLine, isNull);
    });
  });

  test('preview data bundles counts, draft flag and trimmed equipment', () {
    final data = RecipePreviewData(_salsa, confirmedItems: const ['corn']);
    expect(data.isDraft, isFalse);
    expect(data.stepCount, 3);
    expect(data.equipment, ['Bowl', 'Spoon']);
    expect(data.allergens.householdSaved, isFalse);
  });

  test('the swap question quotes the full display name', () {
    expect(
      swapQuestion(_salsa.ingredients.first, _salsa),
      'What can I use instead of "Canned black beans, drained and rinsed" in '
      'Black Bean & Corn Salsa?',
    );
    const milk = Ingredient(id: 'm', name: 'Milk (coconut)', qty: '');
    expect(
      swapQuestion(milk, _salsa),
      'What can I use instead of "Milk (coconut)" in Black Bean & Corn Salsa?',
    );
  });
}
