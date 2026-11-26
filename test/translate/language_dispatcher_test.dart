// Coach Lite in the cook's language (SS-106). Fakes only.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/language_dispatcher.dart';

import 'translate_fixtures.dart';

class _Recording implements HybridDispatcher {
  _Recording(this.inner);
  final FakeHybridDispatcher inner;
  final validators = <ResultValidator?>[];

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    validators.add(validate);
    return inner.start(
      task,
      sessionId: sessionId,
      validate: validate,
      grant: grant,
    );
  }
}

class _Privacy implements PrivacySettings {
  @override
  bool localOnly(String feature) => false;
}

String _coachAnswer(String body) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['tip'],
    },
    {'id': 'tip', 'component': 'stepCue', 'title': 'Consejo', 'body': body},
  ],
});

HybridTask _task(String feature) => HybridTask(
  feature: feature,
  systemInstruction: 'Base instruction.',
  parts: const [HybridText('question')],
  maxOutputTokens: 100,
  timeout: const Duration(seconds: 5),
);

void main() {
  late FakeHybridDispatcher fake;
  late _Recording recording;
  var language = spanish;
  late LanguageAwareDispatcher dispatcher;

  setUp(() {
    fake = FakeHybridDispatcher();
    recording = _Recording(fake);
    language = spanish;
    dispatcher = LanguageAwareDispatcher(recording, language: () => language);
  });

  test('adds the Spanish directive to Coach Lite only', () async {
    fake
      ..enqueue('{}')
      ..enqueue('{}');
    await dispatcher.start(_task('coach_lite'), sessionId: 's').result;
    await dispatcher.start(_task('pantry_scan'), sessionId: 's').result;
    expect(
      fake.tasks[0].systemInstruction,
      withAnswerLanguage('Base instruction.', spanish),
    );
    expect(fake.tasks[0].parts, _task('coach_lite').parts);
    expect(fake.tasks[0].maxOutputTokens, 100);
    expect(fake.tasks[1].systemInstruction, 'Base instruction.');
  });

  test('English passes every task through untouched', () async {
    language = sourceLanguage;
    fake.enqueue('{}');
    String? validate(String _) => null;
    await dispatcher
        .start(_task('coach_lite'), sessionId: 's', validate: validate)
        .result;
    expect(fake.tasks.single.systemInstruction, 'Base instruction.');
    expect(recording.validators.single, same(validate));
  });

  test('the language is read when the question starts', () async {
    fake.delay = const Duration(milliseconds: 5);
    fake.enqueue('{}');
    final op = dispatcher.start(_task('coach_lite'), sessionId: 's');
    language = sourceLanguage;
    await op.result;
    expect(fake.tasks.single.systemInstruction, contains(spanish.modelName));
  });

  test('a Spanish certification never reaches the cook', () async {
    fake.enqueue(_coachAnswer('El pollo está cocido y es seguro para comer.'));
    final r = await dispatcher
        .start(_task('coach_lite'), sessionId: 's')
        .result;
    expect(r.text, isNull);
    expect(r.legs, hasLength(1)); // the leg is still reported
  });

  test('the validator chains the feature check, then the language check', () {
    fake.enqueue('{}');
    dispatcher.start(
      _task('coach_lite'),
      sessionId: 's',
      validate: (t) => t == 'bad' ? 'feature says no' : null,
    );
    final check = recording.validators.single!;
    expect(check('bad'), 'feature says no');
    expect(check('Está listo para comer.'), isNotNull);
    expect(check('Revuelve hasta que esté dorado.'), isNull);
  });

  test('a plain Spanish answer passes; cancel reaches the inner op', () async {
    fake.enqueue(_coachAnswer('Revuelve hasta que esté dorado.'));
    final op = dispatcher.start(_task('coach_lite'), sessionId: 's');
    expect((await op.result).text, contains('dorado'));
    fake.delay = const Duration(milliseconds: 5);
    fake.enqueue('{}');
    final second = dispatcher.start(_task('coach_lite'), sessionId: 's');
    second.cancel();
    expect(fake.cancelledOperations, [second.operationId]);
    expect((await second.result).blocked, RouteReason.cancelled);
  });

  test('CoachLite asks in Spanish through the wrapper', () async {
    fake.enqueue(_coachAnswer('Unta con cuidado la mantequilla (butter).'));
    final coach = CoachLite(
      dispatcher: dispatcher,
      privacy: _Privacy(),
      cloudRoutes: const CloudRoutes({}),
      isOnline: () => true,
    );
    final recipe = testRecipe();
    final RecipeStep step = recipe.steps.first;
    final answer = await coach.ask(
      question: 'How thick?',
      step: step,
      recipe: recipe,
      sessionId: 's',
      epoch: 1,
    );
    expect(answer.status, CoachLiteStatus.answered);
    expect(
      fake.tasks.single.systemInstruction,
      endsWith(answerLanguageDirective(spanish)),
    );
    expect(jsonEncode(answer.components), contains('Unta con cuidado'));
  });

  test('CoachLite falls back to the recipe step on a Spanish claim', () async {
    fake.enqueue(_coachAnswer('Ya está cocido.'));
    final coach = CoachLite(
      dispatcher: dispatcher,
      privacy: _Privacy(),
      cloudRoutes: const CloudRoutes({}),
      isOnline: () => true,
    );
    final recipe = testRecipe();
    final answer = await coach.ask(
      question: 'Is it ready?',
      step: recipe.steps.first,
      recipe: recipe,
      sessionId: 's',
      epoch: 1,
    );
    expect(answer.status, CoachLiteStatus.failed);
    expect(jsonEncode(answer.components), isNot(contains('cocido')));
  });
}
