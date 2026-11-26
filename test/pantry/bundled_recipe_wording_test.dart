// Chef review (SS-094): the bundled recipes read as instructions to a cook,
// never as internal notes, and never certify allergen safety.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/ingredient_label.dart';

const _ids = [
  'peanut_butter_sandwich_v1',
  'black_bean_corn_salsa_v1',
  'chickpea_wrap_v1',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Recipe> recipes;
  late Map<String, String> raw;
  setUpAll(() async {
    recipes = {for (final id in _ids) id: await loadBundledRecipe(id)};
    raw = {
      for (final id in _ids)
        id: await rootBundle.loadString('assets/recipes/$id.json'),
    };
  });

  test('no recipe certifies allergen safety or leaks internal notes', () {
    for (final id in _ids) {
      final text = raw[id]!.toLowerCase();
      for (final banned in [
        'gluten-free',
        'gluten free',
        'allergen-free',
        'allergen free',
        'safe for',
        'for the demo',
        'only if the cook',
        'cook choice',
        'intended result',
        'pre-diced',
      ]) {
        expect(text, isNot(contains(banned)), reason: '$id: $banned');
      }
    }
  });

  test('every reviewed swap points at a real ingredient', () {
    for (final recipe in recipes.values) {
      final ids = {for (final i in recipe.ingredients) i.id};
      for (final swap in recipe.reviewedSubstitutions) {
        expect(ids, contains(swap.ingredientId), reason: recipe.id);
        expect(swap.note.trim(), isNotEmpty, reason: swap.substitute);
      }
    }
  });

  test('peanut butter sandwich reads plainly and has a peanut swap', () {
    final r = recipes['peanut_butter_sandwich_v1']!;
    expect(r.ingredients.map(ingredientRowLabel), [
      'Bread · 2 slices',
      'Peanut butter · about 2 tbsp',
      'Jam (optional) · about 1 tbsp',
    ]);
    expect(r.steps.first.cue, 'Both slices lie flat with room to spread.');
    expect(r.steps.last.instruction, endsWith('Cut in half if you like.'));
    final swap = r.reviewedSubstitutions.single;
    expect(swap.ingredientId, 'peanut_butter');
    expect(swap.substitute, 'Sunflower seed butter');
    expect(
      swap.note,
      'Use a clean knife and plate. Some brands are made alongside peanuts '
      '— check the label.',
    );
  });

  test('salsa has reviewed swaps, plain optional wording and a claw grip', () {
    final r = recipes['black_bean_corn_salsa_v1']!;
    final cilantro = r.ingredients.firstWhere((i) => i.id == 'cilantro');
    expect(
      ingredientRowLabel(cilantro),
      'Cilantro, chopped (optional) · 2 tbsp',
    );
    expect(
      {for (final s in r.reviewedSubstitutions) s.ingredientId: s.substitute},
      {
        'lime': 'Bottled lime juice',
        'tomato': 'Canned diced tomatoes, drained',
      },
    );
    final dice = r.steps.firstWhere((s) => s.id == 'dice');
    expect(dice.instruction, contains('like a claw'));
    expect(dice.instruction, contains('against your knuckles'));
  });

  test('chickpea wrap is realistic for a pantry cook', () {
    final r = recipes['chickpea_wrap_v1']!;
    Ingredient ing(String id) => r.ingredients.firstWhere((i) => i.id == id);
    expect(ing('celery').optional, isTrue);
    expect(ing('bell_pepper').optional, isTrue);
    expect(ing('lemon').name, contains('bottled'));
    final swaps = {for (final s in r.reviewedSubstitutions) s.ingredientId: s};
    expect(swaps['celery']!.substitute, 'Shredded carrot');
    expect(swaps['bell_pepper']!.substitute, 'Canned corn, drained');
    expect(
      swaps['tortillas']!.note,
      'Lettuce leaves replace the wheat tortilla. If you avoid gluten, check '
      'every label, including mustard and mayo.',
    );
    final roll = r.steps.firstWhere((s) => s.id == 'roll');
    expect(
      roll.instruction,
      startsWith(
        'Warm the tortilla 15–20 seconds in the microwave or a dry pan so it '
        'bends without cracking.',
      ),
    );
    final mix = r.steps.firstWhere((s) => s.id == 'mix');
    expect(mix.instruction, contains('shredded carrot'));
    expect(r.equipment, contains(startsWith('Microwave or a dry pan')));
    // The JSON stays valid for the asset loader and the catalog.
    expect(jsonDecode(raw['chickpea_wrap_v1']!), isA<Map>());
  });
}
