import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/pantry/recipe_draft.dart';
import 'package:soussight/pantry/recipe_draft_client.dart';

Map<String, Object?> _ing(String name, String from, {bool optional = false}) =>
    {
      'name': name,
      'fromConfirmed': from,
      'qty': '1',
      'optional': optional,
      'allergens': <String>[],
    };

const _plainSteps = [
  {'title': 'Open', 'instruction': 'Open the can.', 'cue': 'Lid is off.'},
  {'title': 'Mix', 'instruction': 'Stir it together.', 'cue': 'Evenly mixed.'},
  {
    'title': 'Serve',
    'instruction': 'Spoon into a bowl.',
    'cue': 'In the bowl.',
  },
];

String _draft(
  List<Map<String, Object?>> ingredients, {
  List<Map<String, Object?>> steps = _plainSteps,
}) => jsonEncode({
  'title': 'Pantry Bowl',
  'summary': 'A quick bowl.',
  'ingredients': ingredients,
  'equipment': ['Bowl'],
  'steps': steps,
});

/// Emulates the dispatcher's semantic retry (DESIGN.md §5): the first answer
/// is "on device"; if `validate` rejects it, a second "cloud" answer is
/// validated too. Records every validator call.
class _RetryingDispatcher implements HybridDispatcher {
  _RetryingDispatcher(this.answers, {this.blocked});
  final List<String> answers;
  final RouteReason? blocked;
  final tasks = <HybridTask>[];
  final checked = <(String, String?)>[];

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
  }) {
    tasks.add(task);
    Future<DispatchResult> run() async {
      if (blocked case final reason?) {
        return DispatchResult(legs: const [], blocked: reason);
      }
      final legs = <InferenceLeg>[];
      String? text;
      for (final (i, answer) in answers.indexed) {
        final onDevice = i == 0;
        legs.add(
          InferenceLeg(
            requestId: 'r$i',
            feature: task.feature,
            mode: onDevice ? HybridMode.preferOnDevice : HybridMode.onlyInCloud,
            kinds: const {DataKind.text},
            transferPermitted: !onDevice,
            provenance: onDevice ? Provenance.sdkOnDevice : Provenance.sdkCloud,
          ),
        );
        final problem = validate?.call(answer);
        checked.add((answer, problem));
        text = answer;
        // Only an on-device rejection earns a retry; stop otherwise.
        if (problem == null || !onDevice) break;
      }
      return DispatchResult(text: text, legs: legs);
    }

    return HybridOperation('op-${tasks.length}', run(), () {});
  }
}

void main() {
  group('quality gate', () {
    const confirmed = ['canned black beans', 'tomatoes', 'coconut milk'];
    String? check(List<Map<String, Object?>> ingredients) =>
        recipeDraftProblem(_draft(ingredients), confirmed);

    test('a canned item matches its confirmed name', () {
      expect(
        check([
          _ing('Black beans', 'canned black beans'),
          _ing('Tomato, diced', 'tomatoes'),
        ]),
        isNull,
      );
      expect(
        recipeDraftProblem(
          _draft([_ing('Tomatoes', '2 tomatoes'), _ing('Bread', 'bread')]),
          const ['2 tomatoes', 'bread'],
        ),
        isNull,
        reason: 'a count is not part of the food',
      );
    });

    test('a substitute that only shares a word is rejected', () {
      expect(
        check([
          _ing('Black beans', 'canned black beans'),
          _ing('Milk', 'coconut milk'),
        ]),
        contains('not the confirmed item'),
      );
      expect(
        recipeDraftProblem(
          _draft([_ing('Peanut butter', 'peanuts'), _ing('Bread', 'bread')]),
          const ['peanuts', 'bread'],
        ),
        isNotNull,
      );
    });

    test('a required ingredient the cook did not confirm is rejected', () {
      expect(
        check([
          _ing('Black beans', 'canned black beans'),
          _ing('Rice', 'basic'),
        ]),
        contains('not a confirmed item'),
      );
      expect(
        check([
          _ing('Black beans', 'canned black beans'),
          _ing('Rice', 'rice'),
        ]),
        contains('unknown source'),
      );
    });

    test('basics are optional unless the cook confirmed them', () {
      expect(
        check([
          _ing('Black beans', 'canned black beans'),
          _ing('Salt', 'basic', optional: true),
          _ing('Olive oil', 'basic', optional: true),
          _ing('Dried oregano', 'basic', optional: true),
        ]),
        isNull,
      );
      expect(
        check([
          _ing('Black beans', 'canned black beans'),
          _ing('Salt', 'basic'),
        ]),
        contains('must be optional'),
      );
      expect(
        recipeDraftProblem(
          _draft([_ing('Rice', 'rice'), _ing('Olive oil', 'olive oil')]),
          const ['rice', 'olive oil'],
        ),
        isNull,
        reason: 'a confirmed basic may be required',
      );
    });

    test('a draft of basics alone is rejected', () {
      expect(
        check([
          _ing('Water', 'basic', optional: true),
          _ing('Salt', 'basic', optional: true),
        ]),
        contains('no ingredient is a confirmed item'),
      );
    });

    test('the schema enum is the confirmed items plus basic', () {
      final schema = recipeDraftJsonSchema(const ['rice', 'Rice ', 'basic']);
      final ingredient =
          ((schema['properties']! as Map)['ingredients']! as Map)['items']!
              as Map;
      final from = (ingredient['properties']! as Map)['fromConfirmed']! as Map;
      expect(from['enum'], ['rice', 'Rice', kDraftBasicSource]);
      expect(ingredient['required'], contains('fromConfirmed'));
    });
  });

  group('HybridRecipeDraftClient', () {
    const request = RecipeDraftRequest(
      confirmedItems: ['canned black beans', 'coconut milk'],
      note: 'something warm',
    );
    final good = _draft([
      _ing('Black beans', 'canned black beans'),
      _ing('Coconut milk', 'coconut milk'),
      _ing('Salt', 'basic', optional: true),
    ]);
    final substitute = _draft([
      _ing('Black beans', 'canned black beans'),
      _ing('Milk', 'coconut milk'),
    ]);

    HybridRecipeDraftClient client(HybridDispatcher dispatcher) =>
        HybridRecipeDraftClient(
          dispatcher: dispatcher,
          sessionId: () => 's1',
          now: () => DateTime.utc(2026, 11, 25),
        );

    test('sends one recipe_draft task with the confirmed-item enum', () async {
      final dispatcher = _RetryingDispatcher([good]);
      final result = await client(dispatcher).draft(request);
      final task = dispatcher.tasks.single;
      expect(task.feature, kRecipeDraftFeature);
      expect(task.hasImage, isFalse);
      expect(jsonEncode(task.jsonSchema), contains('"coconut milk","basic"'));
      expect(
        (task.parts.single as HybridText).text,
        contains('"noteFromCook":"something warm"'),
      );
      expect(isDraftRecipe(result.recipe), isTrue);
      expect(result.legs.single.provenance, Provenance.sdkOnDevice);
    });

    test(
      'a rejected on-device draft is retried and the retry is validated',
      () async {
        final dispatcher = _RetryingDispatcher([substitute, good]);
        final result = await client(dispatcher).draft(request);
        expect(dispatcher.checked.map((c) => c.$2 == null), [false, true]);
        expect(result.legs.map((l) => l.provenance), [
          Provenance.sdkOnDevice,
          Provenance.sdkCloud,
        ]);
        expect(
          result.recipe.ingredients.map((i) => i.name),
          contains('Coconut milk'),
        );
      },
    );

    test('a retry that also fails the gate is never shown', () async {
      final dispatcher = _RetryingDispatcher([substitute, substitute]);
      await expectLater(
        client(dispatcher).draft(request),
        throwsA(
          isA<RecipeDraftException>().having(
            (e) => e.message,
            'message',
            startsWith('I could not draft a recipe'),
          ),
        ),
      );
      expect(dispatcher.checked.map((c) => c.$2 == null), [false, false]);
    });

    test('safety disclaimers apply to hybrid drafts too', () async {
      final risky = _draft(
        [_ing('Eggs', 'eggs'), _ing('Bread', 'bread')],
        steps: [
          {
            'title': 'Crack',
            'instruction': 'Crack the eggs into a bowl.',
            'cue': 'Yolks are whole.',
          },
          {
            'title': 'Scramble',
            'instruction': 'Cook the eggs in a pan, stirring.',
            'cue': 'Eggs are fully cooked and safe to eat.',
            'timerSeconds': 180,
          },
          {
            'title': 'Toast',
            'instruction': 'Serve on the bread.',
            'cue': 'Eggs sit on the slice.',
          },
        ],
      );
      final result = await client(_RetryingDispatcher([risky]))
          .draft(const RecipeDraftRequest(confirmedItems: ['eggs', 'bread']));
      expect(result.recipe.steps[1].cue, endsWith(kThermometerDisclaimer));
      expect(result.recipe.steps[0].cue, 'Yolks are whole.');
    });

    test('a blocked route is a cook-facing exception', () async {
      final dispatcher = _RetryingDispatcher(
        const [],
        blocked: RouteReason.localOnlySetting,
      );
      await expectLater(
        client(dispatcher).draft(request),
        throwsA(isA<RecipeDraftException>()),
      );
    });

    test('empty confirmed items never reach the dispatcher', () async {
      final dispatcher = _RetryingDispatcher([good]);
      await expectLater(
        client(dispatcher)
            .draft(const RecipeDraftRequest(confirmedItems: [' '])),
        throwsA(isA<RecipeDraftException>()),
      );
      expect(dispatcher.tasks, isEmpty);
    });
  });

  test('the direct Gemini client applies the same gate', () async {
    final client = GeminiRecipeDraftClient(
      generate: (_) async => _draft([
        _ing('Black beans', 'canned black beans'),
        _ing('Milk', 'coconut milk'),
      ]),
    );
    await expectLater(
      client.draft(
        const RecipeDraftRequest(
          confirmedItems: ['canned black beans', 'coconut milk'],
        ),
      ),
      throwsA(isA<RecipeDraftException>()),
    );
    final ok =
        await GeminiRecipeDraftClient(
          generate: (_) async => _draft([
            _ing('Black beans', 'canned black beans'),
            _ing('Coconut milk', 'coconut milk'),
          ]),
        ).draft(
          const RecipeDraftRequest(
            confirmedItems: ['canned black beans', 'coconut milk'],
          ),
        );
    expect(ok.legs.single.provenance, Provenance.cloudAdapter);
  });
}
