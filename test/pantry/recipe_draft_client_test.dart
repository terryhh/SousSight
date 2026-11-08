import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/pantry/recipe_draft.dart';
import 'package:soussight/pantry/recipe_draft_client.dart';

Map<String, dynamic> _draft({List<Map<String, dynamic>>? steps}) => {
  'title': 'Bean and Corn Toast',
  'summary': 'Warm beans and corn on toast.',
  'ingredients': [
    {
      'name': 'Bread',
      'qty': '2 slices',
      'optional': false,
      'allergens': ['wheat', 'Gluten', 'MILK'],
    },
    {'name': 'Black beans', 'qty': '1 can', 'allergens': <String>[]},
    {'name': 'Salt', 'qty': 'a pinch', 'optional': true},
    {'name': 'black beans', 'qty': 'extra'},
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
      final recipe = await _client(() => jsonEncode(_draft())).draft(_request);
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
    final recipe = await _client(() => jsonEncode(draft)).draft(_request);
    expect(recipe.steps[1].cue, endsWith(kThermometerDisclaimer));
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
    final recipe = await fake.draft(_request);
    expect(isDraftRecipe(recipe), isTrue);
    expect(recipe.title, contains('(simulated)'));
    expect(recipe.steps, hasLength(4));
    expect(recipe.steps.last.timerSeconds, 600);
    expect(recipe.steps.last.cue, endsWith(kHeatDisclaimer));
    final again = await fake.draft(_request);
    expect(again.id, recipe.id);
  });
}
