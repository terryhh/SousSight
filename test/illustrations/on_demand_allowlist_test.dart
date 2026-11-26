// On-demand eligibility for AI drafts is an allowlist at every level
// (SS-098, Codex round 5). Fakes and pure functions only.

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/illustrations/illustration_prompts.dart';
import 'package:soussight/illustrations/on_demand_allowlist.dart';
import 'package:soussight/pantry/recipe_draft_client.dart' show kHeatDisclaimer;

Recipe draft({
  String title = 'Draft',
  required List<Ingredient> ingredients,
  required List<RecipeStep> steps,
}) => Recipe(
  id: 'draft_x',
  version: 1,
  title: title,
  summary: '',
  ingredients: ingredients,
  equipment: const [],
  steps: steps,
  checkpoints: const [],
  reviewedSubstitutions: const [],
  adjustmentLabels: const {},
);

Ingredient ing(String name, [List<String> allergens = const []]) =>
    Ingredient(id: name, name: name, qty: '1', allergens: allergens);

RecipeStep step(String id, String instruction, String cue) =>
    RecipeStep(id: id, title: 'Step', instruction: instruction, cue: cue);

const _stepT = StepTarget('s');
const _plate = PlateTarget();

void main() {
  group('ingredients: every one must be known plant-based or shelf-stable', () {
    test('Codex probe: raw meatloaf gets nothing', () {
      final r = draft(
        ingredients: [ing('Raw meatloaf'), ing('Parsley')],
        steps: [
          step(
            's',
            'Arrange the parsley.',
            'Color alone proves it is ready to eat.',
          ),
        ],
      );
      expect(isAllowlistedIngredient(ing('Raw meatloaf')), isFalse);
      expect(onDemandIllustrationPrompt(r, _stepT), isNull);
      expect(onDemandIllustrationPrompt(r, _plate), isNull);
    });

    test('unknown foods, tags and qualifiers all block', () {
      for (final i in [
        ing('Rabbit'),
        ing('Mystery mix'),
        ing('Yogurt'),
        ing('Feta cheese'),
        ing('Crackers (langoustines)', ['shellfish']),
        ing('Crackers (langoustines)'),
        ing('Mayonnaise', ['egg']),
        ing('Worcestershire sauce'),
        ing('Kidney beans'),
        ing('Butter'),
        ing('Milk'),
      ]) {
        expect(isAllowlistedIngredient(i), isFalse, reason: i.name);
      }
    });

    test('plant and shelf-stable names pass, with qualifiers', () {
      for (final name in [
        'Cucumber',
        'Red bell pepper, diced',
        'Salt and black pepper',
        'Canned chickpeas, drained and rinsed',
        'Lemon juice, fresh or bottled',
        'Flour tortillas (10 inch)',
        'Peanut butter',
        'Oat milk',
        'Garlic, minced',
        'Extra virgin olive oil',
        'Cherry tomatoes',
        'Strawberries',
      ]) {
        expect(isAllowlistedIngredient(ing(name)), isTrue, reason: name);
      }
      expect(isAllowlistedIngredient(ing('Fresh')), isFalse, reason: 'no food');
    });
  });

  group('steps: every word must be a no-heat verb, ingredient or filler', () {
    final base = [ing('Carrots'), ing('Onion')];

    test('Codex probe: sous vide is not a no-heat preparation', () {
      final r = draft(
        ingredients: base,
        steps: [step('s', 'Sous vide the carrots for 2 hours.', 'Tender.')],
      );
      expect(onDemandIllustrationPrompt(r, _stepT), isNull);
      expect(onDemandIllustrationPrompt(r, _plate), isNull);
    });

    test('unknown or heated methods block step and plate', () {
      for (final instruction in [
        'Cure the carrots overnight.',
        'Ferment the onion for a week.',
        'Warm the carrots.',
        'Microwave the carrots.',
        'Put the carrots in the oven.',
        'Blitz the carrots.', // unknown verb
        'Toast the onion.',
      ]) {
        final r = draft(
          ingredients: base,
          steps: [step('s', instruction, 'Soft.')],
        );
        expect(
          onDemandIllustrationPrompt(r, _stepT),
          isNull,
          reason: instruction,
        );
        expect(
          onDemandIllustrationPrompt(r, _plate),
          isNull,
          reason: instruction,
        );
      }
    });

    test('allowlisted preparation passes, inflections included', () {
      for (final instruction in [
        'Chop the carrots and onion.',
        'Slice the carrots thinly, then toss them together.',
        'Grated carrots go into the bowl; stir well.',
        'Arrange the carrots on a plate and serve.',
        'Squeeze, drain and mash.',
        'Chopped carrots, then stirred onion.',
      ]) {
        final r = draft(
          ingredients: base,
          steps: [step('s', instruction, 'Even orange pieces.')],
        );
        expect(isNoHeatStep(r, r.steps.single), isTrue, reason: instruction);
        expect(
          onDemandIllustrationPrompt(r, _stepT),
          isNotNull,
          reason: instruction,
        );
      }
    });

    test("the drafter's heat note blocks the whole recipe", () {
      final r = draft(
        ingredients: base,
        steps: [
          step('s', 'Chop the carrots.', 'Even pieces.'),
          step('t', 'Chop the onion.', 'Fine. $kHeatDisclaimer'),
        ],
      );
      expect(onDemandIllustrationPrompt(r, _stepT), isNull);
      expect(onDemandIllustrationPrompt(r, _plate), isNull);
    });
  });

  group('payload: only the cue and exactly named ingredients', () {
    test('Codex probe: a safety claim in the title never goes out', () {
      final r = draft(
        title: 'Safe-to-eat when golden',
        ingredients: [ing('Carrots'), ing('Onion')],
        steps: [step('s', 'Chop the carrots and onion.', 'Even pieces.')],
      );
      final plate = onDemandIllustrationPrompt(r, _plate)!.text;
      expect(plate, isNot(contains('Safe')));
      expect(plate, isNot(contains('golden')));
      expect(plate, contains('Carrots; Onion'));
      final s = onDemandIllustrationPrompt(r, _stepT)!.text;
      expect(s, isNot(contains('Safe')));
    });

    test('a cue that claims doneness, safety or heat abstains', () {
      for (final cue in [
        'Ready to eat once it looks golden.',
        'It is safe now.',
        'Warm to the touch.',
        'The center has reached 70°.',
        'Like cooked chicken.',
        'The camera can tell.',
      ]) {
        final r = draft(
          ingredients: [ing('Carrots')],
          steps: [step('s', 'Chop the carrots.', cue)],
        );
        expect(onDemandIllustrationPrompt(r, _stepT), isNull, reason: cue);
        expect(onDemandIllustrationPrompt(r, _plate), isNull, reason: cue);
      }
    });

    test('Codex probe: "bell pepper" never pulls in black pepper', () {
      final r = draft(
        ingredients: [ing('Red bell pepper'), ing('Black pepper')],
        steps: [step('s', 'Slice the bell pepper.', 'Thin red strips.')],
      );
      final text = onDemandIllustrationPrompt(r, _stepT)!.text;
      expect(text, contains('Ingredients in this step: Red bell pepper.'));
      expect(text, isNot(contains('Black pepper')));
      // "pepper" alone is ambiguous: neither is claimed.
      final vague = draft(
        ingredients: [ing('Red bell pepper'), ing('Black pepper')],
        steps: [step('s', 'Add pepper.', 'Flecks.')],
      );
      expect(exactlyNamedIngredients(vague, vague.steps.single), isEmpty);
      final full = draft(
        ingredients: [ing('Red bell pepper'), ing('Black pepper')],
        steps: [step('s', 'Add black pepper.', 'Flecks.')],
      );
      expect(
        exactlyNamedIngredients(full, full.steps.single).map((i) => i.name),
        ['Black pepper'],
      );
    });

    test('no earlier-step ingredients, no instruction text', () {
      final r = draft(
        ingredients: [ing('Lemon juice'), ing('Red onion'), ing('Chickpeas')],
        steps: [
          step('p', 'Squeeze the lemon juice over the red onion.', 'Pink.'),
          step('s', 'Mash the chickpeas.', 'Chunky, not a paste.'),
        ],
      );
      final text = onDemandIllustrationPrompt(r, _stepT)!.text;
      expect(text, contains('Chunky, not a paste.'));
      expect(text, contains('Ingredients in this step: Chickpeas.'));
      expect(text, isNot(contains('Lemon')));
      expect(text, isNot(contains('Mash the chickpeas')));
      expect(text, endsWith(kIllustrationStyle));
    });

    test('an unknown step, an empty recipe or an empty cue: nothing', () {
      final r = draft(
        ingredients: [ing('Carrots')],
        steps: [step('s', 'Chop the carrots.', '')],
      );
      expect(onDemandIllustrationPrompt(r, _stepT), isNull);
      expect(onDemandIllustrationPrompt(r, const StepTarget('nope')), isNull);
      expect(
        onDemandIllustrationPrompt(
          draft(ingredients: const [], steps: const []),
          _plate,
        ),
        isNull,
      );
      expect(mentionsAnyHeat('Sous vide'), isTrue);
    });
  });
}
