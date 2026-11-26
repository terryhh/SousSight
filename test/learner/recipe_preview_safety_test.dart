// SS-099: the recipe preview is the first screen to show drafted text, so
// drafted summaries and step instructions pass the draft safety check, and
// draft ingredients are compared with the household list by name as well as
// by tag. Built with buildDraftRecipe on fixed JSON; no model call.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/label/household_allergens.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/recipe_preview.dart';
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
  group('draftTextCertifies (allowlist, no exceptions)', () {
    for (final claim in [
      'The camera can confirm the chicken is fully cooked.',
      'The camera  confirms the chicken has reached 165°F.',
      'The camera says the chicken is 165°F inside.',
      'The chicken is fully cooked without a thermometer.',
      'Contains no peanuts.',
      'No peanuts in this one.',
      'This tahini is sesame-free.',
      'Sesame-free tahini toast',
      'It is free of nuts.',
      'This dish has no allergens.',
      'It is safe to eat now.',
      'Do not serve until it is safe to eat.',
      'The chicken is cooked through.',
      'The chicken is fully cooked when it looks white.',
      'It is done once the edges turn golden.',
      'Cook until no longer pink.',
      'Juices run clear.',
      'It is done when a thermometer reads 165°F (74°C).',
      'Cook until a thermometer confirms the chicken is done, regardless of '
          'whether it looks pink.',
      'Cook until a food thermometer reads 165°F and it looks white.',
      // No thermometer exception: every temperature is the app's to give.
      'Cook until a food thermometer reads 165°F.',
      'Cook until a food thermometer reads 100°F.',
      'Cook until a thermometer reads 165°F (74°C).',
      'Heat the oven to 400F (200C).',
      'The photo shows the chicken is 165F inside.',
      'Made without peanuts.',
      'Serve once the chicken turns white.',
      'Cook the egg until it looks firm.',
      'Use fresh basil.',
      'Cooked chicken',
      'Heat to 180 degrees.',
      'Serve when ready.',
    ]) {
      test('rejects "$claim"', () => expect(draftTextCertifies(claim), isTrue));
    }
    for (final guidance in [
      'Toast the bread for about 3 minutes.',
      'Cook until golden brown on both sides.',
      'Toast until the bread turns golden.',
      'Heat the oven until hot.',
      'Squeeze the lime juice over the beans.',
      'Lime juice',
      'Check the label for sesame.',
    ]) {
      test(
        'allows "$guidance"',
        () => expect(draftTextCertifies(guidance), isFalse),
      );
    }
  });

  group('a draft is rejected whole, never edited', () {
    Map<String, dynamic> withStep(String field, String text) {
      final json = _draftJson();
      final steps = [
        for (final s in json['steps'] as List) Map<String, dynamic>.from(s),
      ];
      steps.first[field] = text;
      return {...json, 'steps': steps};
    }

    final cases = <String, Map<String, dynamic>>{
      'title': {..._draftJson(), 'title': 'Sesame-free tahini toast'},
      'summary': _draftJson(
        summary: 'The chicken is fully cooked when it looks white.',
      ),
      'instruction': withStep(
        'instruction',
        'Do not serve until it is safe to eat. Serve immediately.',
      ),
      'cue': withStep('cue', 'This tahini is sesame-free.'),
      'step title': withStep('title', 'Toast until safe to eat'),
      'equipment': {
        ..._draftJson(),
        'equipment': ['Camera can confirm doneness'],
      },
    };
    for (final MapEntry(key: field, value: json) in cases.entries) {
      test('a certifying $field rejects the draft', () {
        expect(draftCertifyingField(json), isNotNull);
        expect(() => _build(json), throwsFormatException);
      });
    }

    test('an ingredient quantity is checked too', () {
      final json = _draftJson();
      final ingredients = [
        for (final i in json['ingredients'] as List)
          Map<String, dynamic>.from(i),
      ];
      ingredients.last['qty'] = '2 tbsp, peanut-free';
      expect(
        draftCertifyingField({...json, 'ingredients': ingredients}),
        'ingredient',
      );
    });

    test('a safe draft passes unchanged; any temperature rejects it', () {
      final json = _draftJson(
        bakeInstruction: 'Toast until golden. Do not leave it unattended.',
      );
      expect(draftCertifyingField(json), isNull);
      final recipe = _build(json);
      expect(
        recipe.steps.first.instruction,
        'Toast until golden. Do not leave it unattended.',
      );
      expect(recipe.summary, 'Warm toast with a crunchy topping.');
      expect(
        () => _build(
          _draftJson(
            bakeInstruction:
                'Toast the bread. Cook until a food thermometer reads 100°F.',
          ),
        ),
        throwsFormatException,
      );
    });

    test('the builder-to-preview path: unsafe summaries never show', () {
      for (final summary in [
        'Contains no peanuts.',
        'The photo shows the chicken is 165F inside. Made without peanuts.',
        'Serve once the chicken turns white.',
      ]) {
        expect(
          () => _build(_draftJson(summary: summary)),
          throwsFormatException,
          reason: summary,
        );
      }
    });

    Map<String, dynamic> beans(String source) => {
      'title': 'Lime beans',
      'summary': 'Beans with lime.',
      'ingredients': [
        {
          'name': 'Lime juice',
          'fromConfirmed': 'lime juice',
          'qty': '1 tbsp',
          'optional': false,
          'allergens': <String>[],
        },
        {
          'name': 'Canned kidney beans',
          'fromConfirmed': source,
          'qty': '1 can',
          'optional': false,
          'allergens': <String>[],
        },
      ],
      'equipment': ['Bowl'],
      'steps': [
        {'title': 'Open', 'instruction': 'Open the can.', 'cue': 'Open.'},
        {'title': 'Mix', 'instruction': 'Add the lime juice.', 'cue': 'Mixed.'},
        {'title': 'Serve', 'instruction': 'Spoon out.', 'cue': 'Served.'},
      ],
    };

    test('a confirmed juice is a valid ingredient', () {
      final recipe = buildDraftRecipe(
        beans('canned kidney beans'),
        seed: 't',
        confirmedItems: const ['lime juice', 'canned kidney beans'],
      );
      expect(recipe.ingredients.first.name, 'Lime juice');
    });

    test('a draft source in a different state (dried for canned) is '
        'rejected', () {
      expect(
        () => buildDraftRecipe(
          beans('dried kidney beans'),
          seed: 't',
          confirmedItems: const ['lime juice', 'dried kidney beans'],
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('same state'),
          ),
        ),
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

  testWidgets('drafted text that certifies is never shown, even if a draft '
      'reaches the preview without the builder', (tester) async {
    final built = _build(_draftJson());
    final unsafe = Recipe(
      id: built.id,
      version: 1,
      title: built.title,
      summary: 'The camera can confirm the chicken is fully cooked.',
      ingredients: built.ingredients,
      equipment: built.equipment,
      steps: built.steps,
      checkpoints: const [],
      reviewedSubstitutions: const [],
      adjustmentLabels: const {},
    );
    await pumpPreview(tester, unsafe);
    expect(find.text('Peanut toast'), findsOneWidget);
    expect(find.textContaining('camera can confirm'), findsNothing);

    final unsafeTitle = Recipe(
      id: built.id,
      version: 1,
      title: 'Sesame-free tahini toast',
      summary: built.summary,
      ingredients: built.ingredients,
      equipment: built.equipment,
      steps: built.steps,
      checkpoints: const [],
      reviewedSubstitutions: const [],
      adjustmentLabels: const {},
    );
    await pumpPreview(tester, unsafeTitle);
    expect(find.textContaining('Sesame-free'), findsNothing);
    expect(find.text('AI-drafted recipe'), findsOneWidget);

    await pumpPreview(tester, built);
    expect(find.text('Warm toast with a crunchy topping.'), findsOneWidget);
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
