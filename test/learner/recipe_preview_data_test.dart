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
      expect(result.total, 6);
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

    test('no match still says check labels, not "safe"', () {
      final a = PreviewAllergens(_salsa, const {'milk', 'egg'});
      expect(
        a.householdLine,
        'The recipe doesn’t mention your household allergens (egg and milk) '
        '— check labels yourself.',
      );
      expect(a.householdLine, isNot(contains('safe')));
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
    });
  });

  test('preview data bundles counts, draft flag and trimmed equipment', () {
    final data = RecipePreviewData(_salsa, confirmedItems: const ['corn']);
    expect(data.isDraft, isFalse);
    expect(data.stepCount, 3);
    expect(data.equipment, ['Bowl', 'Spoon']);
    expect(data.allergens.householdSaved, isFalse);
  });

  group('swap question', () {
    test('uses a short, lower-cased ingredient name and the title', () {
      expect(
        swapQuestion(_salsa.ingredients.first, _salsa),
        'What can I use instead of canned black beans in Black Bean & Corn '
        'Salsa?',
      );
      expect(
        swapQuestion(_salsa.ingredients[4], _salsa),
        'What can I use instead of tortilla chips in Black Bean & Corn Salsa?',
      );
    });

    test('keeps acronyms and falls back to the full name', () {
      expect(
        shortIngredientName(
          const Ingredient(id: 'bbq', name: 'BBQ sauce', qty: ''),
        ),
        'BBQ sauce',
      );
      expect(
        shortIngredientName(const Ingredient(id: 'x', name: '(salt)', qty: '')),
        '(salt)',
      );
    });
  });
}
