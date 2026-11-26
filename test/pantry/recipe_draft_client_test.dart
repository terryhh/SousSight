import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/pantry/recipe_draft.dart';
import 'package:soussight/pantry/recipe_draft_client.dart';

Map<String, dynamic> _draft({List<Map<String, dynamic>>? steps}) => {
  'title': 'Bean and Corn Toast',
  'summary': 'Warm beans and corn on toast.',
  'ingredients': [
    {
      'name': 'Bread',
      'fromConfirmed': 'bread',
      'qty': '2 slices',
      'optional': false,
      'allergens': ['wheat', 'Gluten', 'MILK'],
    },
    {
      'name': 'Black beans',
      'fromConfirmed': 'black beans',
      'qty': '1 can',
      'allergens': <String>[],
    },
    {
      'name': 'Salt',
      'fromConfirmed': 'basic',
      'qty': 'a pinch',
      'optional': true,
    },
    {'name': 'black beans', 'fromConfirmed': 'black beans', 'qty': 'extra'},
  ],
  'equipment': ['Pan', 'Spoon'],
  'steps':
      steps ??
      [
        {
          'title': 'Open',
          'instruction': 'Drain the beans.',
          'cue': 'No liquid pools in the can.',
        },
        {
          'title': 'Warm',
          'instruction': 'Heat the beans in a pan.',
          'cue': 'Beans are glossy and steaming.',
          'timerSeconds': 5,
        },
        {
          'title': 'Serve',
          'instruction': 'Spoon onto the bread.',
          'cue': 'Beans cover the slice.',
          'timerSeconds': 99999,
        },
      ],
};

GeminiRecipeDraftClient _client(FutureOr<String?> Function() reply) =>
    GeminiRecipeDraftClient(
      generate: (_) async => reply(),
      now: () => DateTime.utc(2026, 11, 8),
    );

const _request = RecipeDraftRequest(confirmedItems: ['bread', 'black beans']);

void main() {
  test(
    'valid JSON builds a draft recipe with ids, allergens, timers',
    () async {
      final recipe = (await _client(() => jsonEncode(_draft())).draft(_request))
          .recipe;
      expect(recipe.id, startsWith(kDraftRecipePrefix));
      expect(isDraftRecipe(recipe), isTrue);
      expect(recipe.version, 1);
      expect(recipe.ingredients.map((i) => i.id), [
        'bread',
        'black_beans',
        'salt',
        'black_beans_2',
      ]);
      expect(recipe.ingredients.first.allergens, ['wheat', 'milk']);
      expect(recipe.ingredients[2].optional, isTrue);
      expect(recipe.steps.map((s) => s.id), ['step_1', 'step_2', 'step_3']);
      expect(recipe.steps[0].timerSeconds, isNull);
      expect(recipe.steps[1].timerSeconds, 60);
      expect(recipe.steps[2].timerSeconds, 3600);
      // The 99999 s timer was capped, and the cook is told so.
      expect(recipe.steps[2].instruction, endsWith(kTimerCapNote));
      expect(recipe.steps[1].instruction, isNot(contains(kTimerCapNote)));
      expect(recipe.steps[1].cue, endsWith(kHeatDisclaimer));
      expect(recipe.steps[0].cue, 'No liquid pools in the can.');
      expect(recipe.checkpoints, isEmpty);
      expect(recipe.reviewedSubstitutions, isEmpty);
      expect(recipe.adjustmentLabels, isEmpty);
    },
  );

  test('sends structured-output config and confirmed items', () async {
    late RecipeDraftGenerationRequest seen;
    final client = GeminiRecipeDraftClient(
      generate: (request) async {
        seen = request;
        return jsonEncode(_draft());
      },
    );
    await client.draft(_request);
    expect(seen.model, kDraftModel);
    expect(seen.config.toJson()['responseMimeType'], 'application/json');
    expect(seen.config.toJson()['maxOutputTokens'], 8192);
  });

  test('meat step gets the thermometer disclaimer', () async {
    final draft = _draft(
      steps: [
        {
          'title': 'Prep',
          'instruction': 'Slice the chicken.',
          'cue': 'Even strips',
        },
        {
          'title': 'Cook',
          'instruction': 'Cook the chicken in a hot pan.',
          'cue': 'Strips are browned on all sides and fully cooked.',
          'timerSeconds': 480,
        },
        {'title': 'Serve', 'instruction': 'Plate it.', 'cue': 'On the plate.'},
      ],
    );
    final recipe = (await _client(() => jsonEncode(draft)).draft(_request))
        .recipe;
    // The model's "fully cooked" cue is dropped; colour is never the test.
    expect(recipe.steps[1].cue, draftThermometerNote('chicken'));
    expect(recipe.steps[1].cue, contains('poultry 165°F (74°C)'));
    expect(recipe.steps[1].cue, isNot(contains('fully cooked')));
    expect(recipe.steps[1].timerSeconds, 480);
    expect(recipe.steps[2].cue, 'On the plate.');
  });

  test('invalid JSON is a safe exception', () async {
    await expectLater(
      _client(() => 'not json').draft(_request),
      throwsA(
        isA<RecipeDraftException>().having(
          (e) => e.message,
          'message',
          startsWith('I could not draft a recipe'),
        ),
      ),
    );
  });

  test('too few steps is rejected', () async {
    final draft = _draft(
      steps: [
        {'title': 'Only', 'instruction': 'Eat it.', 'cue': 'Gone.'},
      ],
    );
    await expectLater(
      _client(() => jsonEncode(draft)).draft(_request),
      throwsA(isA<RecipeDraftException>()),
    );
  });

  test('empty items are rejected before any call', () async {
    var called = false;
    final client = GeminiRecipeDraftClient(
      generate: (_) async {
        called = true;
        return '{}';
      },
    );
    await expectLater(
      client.draft(const RecipeDraftRequest(confirmedItems: [' '])),
      throwsA(
        isA<RecipeDraftException>().having(
          (e) => e.message,
          'message',
          'Confirm at least one item you have, then try again.',
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('timeout and provider errors map to safe copy', () async {
    final slow = GeminiRecipeDraftClient(
      generate: (_) => Completer<String?>().future,
      timeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      slow.draft(_request),
      throwsA(
        isA<RecipeDraftException>().having(
          (e) => e.message,
          'message',
          'Drafting took too long. Please try again.',
        ),
      ),
    );
    final broken = GeminiRecipeDraftClient(
      generate: (_) async => throw StateError('key AIza${'x' * 30}'),
    );
    await expectLater(
      broken.draft(_request),
      throwsA(
        isA<RecipeDraftException>().having(
          (e) => e.message,
          'message',
          'Recipe drafting is unavailable right now. Pick a recipe below.',
        ),
      ),
    );
  });

  test('fake returns a labelled simulated draft', () async {
    const fake = FakeRecipeDraftClient(delay: Duration.zero);
    final result = await fake.draft(_request);
    final recipe = result.recipe;
    expect(result.legs.single.provenance, Provenance.simulated);
    expect(isDraftRecipe(recipe), isTrue);
    expect(recipe.title, contains('(simulated)'));
    expect(recipe.steps, hasLength(4));
    expect(recipe.steps.last.timerSeconds, 600);
    expect(recipe.steps.last.cue, endsWith(kHeatDisclaimer));
    final again = await fake.draft(_request);
    expect(again.recipe.id, recipe.id);
  });

  group('chef safety rules (SS-094)', () {
    Map<String, dynamic> withSteps(
      List<Map<String, dynamic>> steps, {
      List<Map<String, dynamic>>? ingredients,
    }) => {..._draft(steps: steps), 'ingredients': ?ingredients};

    Future<List<String>> cues(
      List<Map<String, dynamic>> steps, {
      List<Map<String, dynamic>>? ingredients,
      List<String> items = const ['bread', 'black beans'],
    }) async {
      final recipe = (await _client(
        () => jsonEncode(withSteps(steps, ingredients: ingredients)),
      ).draft(RecipeDraftRequest(confirmedItems: items))).recipe;
      return [for (final step in recipe.steps) step.cue];
    }

    Map<String, dynamic> step(
      String instruction, [
      String cue = 'Looks even.',
    ]) => {'title': 'Step', 'instruction': instruction, 'cue': cue};

    test('the prompt sets thermometer targets and the dried-bean rule', () {
      for (final text in [
        "never use colour or 'juices run clear' as the doneness test",
        'poultry 165°F/74°C',
        'ground meat 160°F/71°C',
        'fish 145°F/63°C',
        'egg dishes 160°F/71°C',
        'Dried beans: soak, drain, then boil in fresh water.',
      ]) {
        expect(
          recipeDraftInstruction.replaceAll('\n', ' '),
          contains(text),
          reason: text,
        );
      }
    });

    test('every chef heat word marks a step as heated', () async {
      const words = [
        'Brown',
        'Sear',
        'Toast',
        'Broil',
        'Poach',
        'Steam',
        'Warm',
        'Melt',
        'Use the stove for',
        'Use a burner for',
        'Use a pot for',
        'Use a saucepan for',
      ];
      for (final word in words) {
        final got = await cues([
          step('Drain the beans.'),
          step('$word the beans.'),
          step('Spoon onto the bread.'),
        ]);
        expect(got[1], endsWith(kHeatDisclaimer), reason: word);
        expect(got[0], 'Looks even.', reason: word);
      }
    });

    test('heat words match whole words only', () async {
      final got = await cues([
        step('Drain the beans into a potato bowl.'),
        step('Stir in the pottery dish.'),
        step('Spoon onto the warmth-free plate area, the pans aside.'),
      ]);
      expect(got[0], 'Looks even.');
      expect(got[1], 'Looks even.');
      // "pans" is a heat word in its own right.
      expect(got[2], endsWith(kHeatDisclaimer));
    });

    test('ground black pepper is a spice, ground meat is meat', () async {
      final spice = await cues([
        step('Drain the beans.'),
        step('Warm the beans and add ground black pepper.'),
        step('Add ground cumin and spoon onto the bread.'),
      ]);
      expect(spice[1], endsWith(kHeatDisclaimer));
      expect(spice[1], isNot(contains('thermometer')));
      expect(spice[2], 'Looks even.');

      for (final (meat, target) in [
        ('ground beef', 'ground meat 160°F (71°C)'),
        ('ground meat', 'ground meat 160°F (71°C)'),
        ('ground turkey', 'poultry 165°F (74°C)'),
      ]) {
        final got = await cues([
          step('Drain the beans.'),
          step('Brown the $meat in a pan.', 'No pink is left.'),
          step('Spoon onto the bread.'),
        ]);
        expect(got[1], contains(target), reason: meat);
        expect(got[1], startsWith('No pink is left. $kColourNotDoneness'));
      }
    });

    const general = '$kColourNotDoneness $kThermometerDisclaimer';

    test('thermometer notes name each protein and never certify', () {
      expect(
        draftThermometerNote('Sear the salmon'),
        "$kColourNotDoneness Check with a food thermometer: fish 145°F (63°C). "
        "The camera can't confirm it's safe.",
      );
      expect(
        draftThermometerNote('chicken and egg fried rice'),
        allOf(
          contains('poultry 165°F (74°C), egg dishes 160°F (71°C)'),
          startsWith(kColourNotDoneness),
        ),
      );
      expect(
        draftThermometerNote('pork chops'),
        '$kColourNotDoneness $kThermometerDisclaimer',
      );
      // Unknown meat: no number, the general line.
      expect(draftThermometerNote('meatballs'), general);
      expect(
        draftThermometerNote('beef meatballs'),
        contains('ground meat 160°F (71°C)'),
      );
    });

    test('poultry keeps its identity over burgers and sausages', () {
      // Codex P1: ground turkey recipe, "burgers" step -> poultry only.
      expect(
        draftThermometerNote('Brown the burgers', recipe: 'Ground turkey Buns'),
        allOf(contains('poultry 165°F (74°C)'), isNot(contains('160°F'))),
      );
      expect(
        draftThermometerNote('Brown the chicken sausages in a pan'),
        allOf(contains('poultry 165°F (74°C)'), isNot(contains('160°F'))),
      );
      expect(
        draftThermometerNote('Fry the turkey burgers'),
        allOf(contains('poultry 165°F (74°C)'), isNot(contains('160°F'))),
      );
      expect(
        draftThermometerNote('Brown the burgers', recipe: 'Ground beef Buns'),
        allOf(contains('ground meat 160°F (71°C)'), isNot(contains('165'))),
      );
      // Both kinds in the recipe and the step does not say which: no number.
      expect(
        draftThermometerNote(
          'Grill the sausages',
          recipe: 'Chicken thighs Pork sausages',
        ),
        general,
      );
      // Both named explicitly: each gets its own target.
      expect(
        draftThermometerNote('Fry the pork sausages and chicken'),
        contains('poultry 165°F (74°C), ground meat 160°F (71°C)'),
      );
    });

    group('burger, hamburger, patty and sausage identity', () {
      const poultry = 'poultry 165°F (74°C)';
      const ground = 'ground meat 160°F (71°C)';
      // Exactly one target: the right number, and never the other one.
      Matcher only(String target) => allOf(
        contains('Check with a food thermometer: $target.'),
        startsWith(kColourNotDoneness),
        endsWith("The camera can't confirm it's safe."),
      );
      // (step, recipe ingredients, expected)
      final cases = <(String, String, Matcher)>[
        // Codex probes on 649c1be.
        ('Brown the hamburgers in a pan', 'Ground turkey Bread', only(poultry)),
        ('Brown the turkey hamburgers', '', only(poultry)),
        // Plurals and casing.
        ('Brown the hamburger in a pan', 'Ground turkey Bread', only(poultry)),
        ('BROWN THE HAMBURGERS', 'GROUND TURKEY', only(poultry)),
        ('Fry the Turkey Hamburger', '', only(poultry)),
        ('Grill the TURKEY BURGERS', '', only(poultry)),
        ('Grill the turkey burger', '', only(poultry)),
        ('Grill the turkeyburgers', '', only(poultry)),
        ('Grill the turkey-burgers', '', only(poultry)),
        // Named meat before the shape.
        ('Fry the chicken hamburgers', '', only(poultry)),
        ('Fry the chicken hamburger patties', '', only(poultry)),
        ('Grill the beef hamburgers', '', only(ground)),
        ('Grill the Beef Hamburger', '', only(ground)),
        ('Grill the pork burger', '', only(ground)),
        // Unnamed hamburgers resolve from the recipe.
        ('Grill the hamburgers', 'Ground beef Buns', only(ground)),
        ('Grill the cheeseburgers', 'Ground beef Buns', only(ground)),
        ('Grill the cheeseburgers', 'Ground turkey Buns', only(poultry)),
        // Ground turkey, however it is worded.
        ('Brown the ground turkey in a pan', '', only(poultry)),
        ('Brown the Ground Turkey', '', only(poultry)),
        ('Brown the ground meat', 'Ground turkey Onion', only(poultry)),
        ('Brown the minced meat', 'Ground chicken', only(poultry)),
        ('Brown the ground meat', 'Onion', only(ground)),
        ('Cook the patties in a skillet', 'Ground turkey Buns', only(poultry)),
        ('Cook the patties in a skillet', 'Ground pork', only(ground)),
        // Sausage patties.
        ('Fry the sausage patties', 'Pork sausage Eggs', contains(ground)),
        ('Fry the sausage patties', 'Pork sausage', only(ground)),
        ('Fry the pork sausage patties', '', only(ground)),
        ('Fry the turkey sausage patties', '', only(poultry)),
        ('Fry the Chicken Sausage Patty', '', only(poultry)),
        ('Fry the sausage patties', 'Turkey sausage', only(poultry)),
      ];
      for (final (stepText, recipe, expected) in cases) {
        test('"$stepText" with "$recipe"', () {
          final note = draftThermometerNote(stepText, recipe: recipe);
          expect(note, expected);
          expect(note, isNot(contains('reached')));
        });
      }

      // Ambiguous or not meat: the general thermometer line, no number.
      final abstain = <(String, String)>[
        ('Grill the hamburgers', ''),
        ('Grill the hamburgers', 'Buns Cheese'),
        ('Grill the burgers', 'Ground turkey Ground beef'),
        ('Grill the HAMBURGERS', 'Chicken thighs Beef'),
        ('Fry the sausage patties', ''),
        ('Fry the sausage patties', 'Turkey sausage Pork sausage'),
        ('Brown the ground meat', 'Ground turkey Ground beef'),
        ('Grill the veggie burgers', ''),
        ('Grill the Veggie Burger', 'Ground beef'),
        ('Grill the veggieburgers', 'Ground turkey'),
        ('Fry the black bean patties', ''),
        ('Fry the vegan sausages', 'Pork sausage'),
        ('Fry the plant-based burgers', 'Ground beef'),
        ('Warm the hamburger buns in the oven', 'Ground beef'),
      ];
      for (final (stepText, recipe) in abstain) {
        test('"$stepText" with "$recipe" names no number', () {
          expect(draftThermometerNote(stepText, recipe: recipe), general);
        });
      }

      test('mince as a verb is not ground meat', () {
        expect(
          draftThermometerNote('Mince the garlic and saute in a pan'),
          general,
        );
      });
    });

    test('hamburger and veggie burger steps, end to end', () async {
      Map<String, Object> ingredient(String name, List<String> allergens) => {
        'name': name,
        'fromConfirmed': name.toLowerCase(),
        'qty': '1',
        'optional': false,
        'allergens': allergens,
      };
      final turkey = await cues(
        [
          step('Shape the ground turkey into patties.'),
          step('Brown the HAMBURGERS in a pan.', 'Both sides are browned.'),
          step('Serve on the bread.'),
        ],
        ingredients: [
          ingredient('Ground turkey', []),
          ingredient('Bread', ['wheat']),
        ],
        items: ['ground turkey', 'bread'],
      );
      expect(turkey[1], contains('poultry 165°F (74°C)'));
      expect(turkey[1], isNot(contains('160°F')));

      final veggie = await cues(
        [
          step('Unwrap the veggie burgers.'),
          step('Grill the veggie burgers.', 'Both sides are browned.'),
          step('Serve on the bread.'),
        ],
        ingredients: [
          ingredient('Veggie burgers', ['soy']),
          ingredient('Bread', ['wheat']),
        ],
        items: ['veggie burgers', 'bread'],
      );
      expect(veggie[1], endsWith(kHeatDisclaimer));
      expect(veggie[1], isNot(contains('°F')));
    });

    test(
      'reheated food is 165°F; warming food of unknown state names none',
      () {
        // Codex P1: leftover salmon is not 145°F.
        for (final text in [
          'Warm the leftover salmon in a pan',
          'Reheat the chicken in the microwave',
          'Heat the cooked salmon in a pan',
          'Warm the rice and eggs up in a pan',
          'Fry the rotisserie chicken pieces',
        ]) {
          expect(
            draftThermometerNote(text),
            allOf(
              contains('leftovers and reheated food 165°F (74°C)'),
              isNot(contains('145')),
              isNot(contains('160')),
            ),
            reason: text,
          );
        }
        // Leftover state from the recipe counts too.
        expect(
          draftThermometerNote(
            'Heat it in a pan',
            step: 'Heat it in a pan',
            recipe: 'Leftover chicken',
          ),
          contains('165°F'),
        );
        for (final text in [
          'Warm the salmon',
          'Melt the cheese over the tuna',
          'Toast the egg bread',
        ]) {
          expect(draftThermometerNote(text), general, reason: text);
        }
        // A real cooking word alongside "warm" still names the target.
        expect(
          draftThermometerNote('Warm the pan, then sear the salmon'),
          contains('fish 145°F (63°C)'),
        );
      },
    );

    test('a ground turkey recipe with a burger step, end to end', () async {
      final got = await cues(
        [
          step('Shape the ground turkey into patties.'),
          step('Brown the burgers in a hot pan.', 'Both sides are browned.'),
          step('Serve on the bread.'),
        ],
        ingredients: [
          {
            'name': 'Ground turkey',
            'fromConfirmed': 'ground turkey',
            'qty': '1 lb',
            'optional': false,
            'allergens': <String>[],
          },
          {
            'name': 'Bread',
            'fromConfirmed': 'bread',
            'qty': '2 slices',
            'optional': false,
            'allergens': ['wheat'],
          },
        ],
        items: ['ground turkey', 'bread'],
      );
      expect(got[1], contains('poultry 165°F (74°C)'));
      expect(got[1], isNot(contains('160°F')));
    });

    test('leftover salmon warmed in a pan, end to end', () async {
      final got = await cues(
        [
          step('Flake the leftover salmon.'),
          step('Warm the leftover salmon in a pan.', 'Steam rises.'),
          step('Serve on the bread.'),
        ],
        ingredients: [
          {
            'name': 'Leftover salmon',
            'fromConfirmed': 'leftover salmon',
            'qty': '1 fillet',
            'optional': false,
            'allergens': ['fish'],
          },
          {
            'name': 'Bread',
            'fromConfirmed': 'bread',
            'qty': '2 slices',
            'optional': false,
            'allergens': ['wheat'],
          },
        ],
        items: ['leftover salmon', 'bread'],
      );
      expect(got[1], contains('leftovers and reheated food 165°F (74°C)'));
      expect(got[1], isNot(contains('145')));
    });

    test('the recipe proteins set the note when the step names none', () async {
      final got = await cues(
        [
          step('Crack the eggs into a bowl.'),
          step('Pour into a hot pan and stir.', 'Curds form.'),
          step('Serve on the bread.'),
        ],
        ingredients: [
          {
            'name': 'Eggs',
            'fromConfirmed': 'eggs',
            'qty': '2',
            'optional': false,
            'allergens': ['egg'],
          },
          {
            'name': 'Bread',
            'fromConfirmed': 'bread',
            'qty': '1 slice',
            'optional': false,
            'allergens': ['wheat'],
          },
        ],
        items: ['eggs', 'bread'],
      );
      expect(got[0], 'Looks even.');
      expect(got[1], 'Curds form. ${draftThermometerNote('Eggs Bread')}');
      expect(got[1], contains('egg dishes 160°F (71°C)'));
    });

    test('a long cue is clipped but the thermometer note survives', () async {
      final got = await cues([
        step('Drain the beans.'),
        step('Sear the chicken and salmon with eggs.', 'Glossy ' * 80),
        step('Spoon onto the bread.'),
      ]);
      final note = draftThermometerNote('chicken salmon eggs');
      expect(got[1], endsWith(note));
      expect(got[1], startsWith('Glossy'));
    });

    test('a timer given as text is capped with a note too', () async {
      final recipe = (await _client(
        () => jsonEncode(
          withSteps([
            step('Drain the beans.'),
            {
              ...step('Soak the beans. ${'Wait. ' * 80}'),
              'timerSeconds': '7200',
            },
            {...step('Spoon onto the bread.'), 'timerSeconds': 'soon'},
          ]),
        ),
      ).draft(_request)).recipe;
      expect(recipe.steps[1].timerSeconds, 3600);
      expect(recipe.steps[1].instruction, endsWith('… $kTimerCapNote'));
      expect(recipe.steps[1].instruction.length, lessThanOrEqualTo(400));
      expect(recipe.steps[2].timerSeconds, isNull);
      expect(recipe.steps[2].instruction, 'Spoon onto the bread.');
    });
  });
}
