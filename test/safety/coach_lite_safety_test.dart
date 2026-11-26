// Coach Lite through the shared safety gate (SS-106): timer labels, and
// Spanish safety and substitution questions classified as factual.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/core/models.dart';

String _answer({String body = 'Stir gently.', Object? timer}) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['tip'],
    },
    {'id': 'tip', 'component': 'stepCue', 'title': 'Tip', 'body': body},
  ],
  'timerSuggestion': ?timer,
});

void main() {
  test('a certifying timer label rejects the answer', () {
    expect(
      () => parseCoachLiteResponse(
        _answer(timer: {'label': 'Chicken is safe to eat', 'seconds': 120}),
      ),
      throwsFormatException,
    );
    expect(
      validateCoachLiteResponse(
        _answer(timer: {'label': 'Ya está listo para comer', 'seconds': 120}),
      ),
      isNotNull,
    );
    final ok = parseCoachLiteResponse(
      _answer(timer: {'label': 'Simmer', 'seconds': 120}),
    );
    expect(ok.timer?.label, 'Simmer');
  });

  test('an empty root with no reachable card is malformed', () {
    for (final root in [
      {'id': 'root', 'component': 'CookingColumn', 'children': <String>[]},
      {
        'id': 'root',
        'component': 'CookingColumn',
        'children': ['missing'],
      },
    ]) {
      final text = jsonEncode({
        'components': [
          root,
          {'id': 'orphan', 'component': 'stepCue', 'title': 'T', 'body': 'B'},
        ],
      });
      expect(validateCoachLiteResponse(text), isNotNull, reason: '$root');
    }
    expect(validateCoachLiteResponse(_answer()), isNull);
  });

  test('a card nested under a column counts (validated tree)', () {
    final nested = jsonEncode({
      'components': [
        {
          'id': 'root',
          'component': 'CookingColumn',
          'children': ['col'],
        },
        {
          'id': 'col',
          'component': 'CookingColumn',
          'children': ['tip'],
        },
        {'id': 'tip', 'component': 'stepCue', 'title': 'T', 'body': 'Stir.'},
      ],
    });
    expect(validateCoachLiteResponse(nested), isNull);
    final columnsOnly = jsonEncode({
      'components': [
        {
          'id': 'root',
          'component': 'CookingColumn',
          'children': ['col'],
        },
        {'id': 'col', 'component': 'CookingColumn', 'children': <String>[]},
      ],
    });
    expect(validateCoachLiteResponse(columnsOnly), isNotNull);
  });

  group('Spanish questions are classified', () {
    const cases = {
      '¿Contiene maní?': CoachLiteQuestionKind.safety,
      '¿Ya está cocido el pollo?': CoachLiteQuestionKind.safety,
      '¿Es seguro comerlo crudo?': CoachLiteQuestionKind.safety,
      '¿A qué temperatura lo cocino?': CoachLiteQuestionKind.safety,
      '¿Cuánto duran las sobras en la nevera?': CoachLiteQuestionKind.safety,
      '¿Tiene gluten?': CoachLiteQuestionKind.safety,
      '¿Puedo usar yogur en vez de mayonesa?':
          CoachLiteQuestionKind.substitution,
      'No tengo mostaza, ¿qué hago?': CoachLiteQuestionKind.substitution,
      '¿Puedo reemplazar el apio?': CoachLiteQuestionKind.substitution,
      '¿Cómo unto la mantequilla?': CoachLiteQuestionKind.stepHelp,
      // Second Codex round: intent, not the food named.
      '¿Cómo bato los huevos?': CoachLiteQuestionKind.stepHelp,
      '¿Cuánto maní le pongo?': CoachLiteQuestionKind.stepHelp,
      '¿Está fresca la leche?': CoachLiteQuestionKind.safety,
      '¿Ya está?': CoachLiteQuestionKind.safety,
      '¿Lleva huevo esta salsa?': CoachLiteQuestionKind.safety,
      '¿Qué tan finas corto las rodajas?': CoachLiteQuestionKind.stepHelp,
    };
    for (final MapEntry(key: q, value: kind) in cases.entries) {
      test(q, () => expect(classifyCoachLiteQuestion(q), kind));
    }
  });

  test('English classification is unchanged', () {
    expect(
      classifyCoachLiteQuestion('Is it safe?'),
      CoachLiteQuestionKind.safety,
    );
    expect(
      classifyCoachLiteQuestion('Can I use yogurt instead?'),
      CoachLiteQuestionKind.substitution,
    );
    expect(
      classifyCoachLiteQuestion('How thin should I slice it?'),
      CoachLiteQuestionKind.stepHelp,
    );
  });

  group('research hand-off follows the question', () {
    Future<CoachLiteAnswer> ask(String q, FakeHybridDispatcher d) =>
        CoachLite(
          dispatcher: d,
          privacy: _Privacy(),
          cloudRoutes: const CloudRoutes({CloudRoute.research}),
          isOnline: () => true,
        ).ask(
          question: q,
          step: const RecipeStep(
            id: 's',
            title: 'Beat',
            instruction: 'Beat the eggs.',
            cue: 'Frothy.',
          ),
          recipe: const Recipe(
            id: 'r',
            version: 1,
            title: 'Eggs',
            summary: '',
            ingredients: [],
            equipment: [],
            steps: [
              RecipeStep(
                id: 's',
                title: 'Beat',
                instruction: 'Beat the eggs.',
                cue: 'Frothy.',
              ),
            ],
            checkpoints: [],
            reviewedSubstitutions: [],
            adjustmentLabels: {},
          ),
          sessionId: 'session',
          epoch: 1,
        );

    test('technique stays local; a freshness question hands off', () async {
      final d = FakeHybridDispatcher()
        ..enqueue(_answer(body: 'Bate con un tenedor.'))
        ..enqueue(_answer(body: 'Huele la leche.'));
      final technique = await ask('¿Cómo bato los huevos?', d);
      expect(technique.kind, CoachLiteQuestionKind.stepHelp);
      expect(technique.handOffToResearch, isFalse);
      final fresh = await ask('¿Está fresca la leche?', d);
      expect(fresh.kind, CoachLiteQuestionKind.safety);
      expect(fresh.handOffToResearch, isTrue);
    });
  });
}

class _Privacy implements PrivacySettings {
  @override
  bool localOnly(String feature) => false;
}
