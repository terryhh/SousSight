// Coach Lite through the shared safety gate (SS-106): timer labels, and
// Spanish safety and substitution questions classified as factual.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/coach_lite/coach_lite.dart';

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
}
