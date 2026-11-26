// Coach Lite runs against FakeHybridDispatcher only. No model or network call
// is made; these tests do not show how a real on-device model answers.

import 'dart:async';
import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/coach_lite/timer_suggestion_card.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/genui/cooking_ui.dart';

const _simmer = RecipeStep(
  id: 'simmer',
  title: 'Simmer the sauce',
  instruction: 'Lower the heat and simmer the tomato sauce, stirring often.',
  cue: 'Thick enough to coat the back of a spoon.',
  timerSeconds: 600,
);

const _recipe = Recipe(
  id: 'pasta',
  version: 1,
  title: 'Weeknight tomato pasta',
  summary: 'Pasta with a quick tomato sauce.',
  ingredients: [
    Ingredient(id: 'tomatoes', name: 'Crushed tomatoes', qty: '1 can'),
    Ingredient(
      id: 'pasta',
      name: 'Spaghetti',
      qty: '200 g',
      allergens: ['wheat'],
    ),
  ],
  equipment: ['pan'],
  steps: [_simmer],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

class _Privacy implements PrivacySettings {
  final Set<String> localOnlyFeatures = {};
  @override
  bool localOnly(String feature) => localOnlyFeatures.contains(feature);
}

/// Records the validator CoachLite hands the dispatcher.
class _RecordingDispatcher extends FakeHybridDispatcher {
  final List<ResultValidator?> validators = [];
  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
  }) {
    validators.add(validate);
    return super.start(task, sessionId: sessionId, validate: validate);
  }
}

/// Completes each operation only when the test says so, in any order.
class _GatedDispatcher implements HybridDispatcher {
  final List<Completer<DispatchResult>> gates = [];
  final List<bool> cancelled = [];
  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
  }) {
    final gate = Completer<DispatchResult>();
    final index = gates.length;
    gates.add(gate);
    cancelled.add(false);
    return HybridOperation('gated-$index', gate.future, () {
      cancelled[index] = true;
    });
  }

  void answer(int index, String text) => gates[index].complete(
    DispatchResult(
      text: text,
      legs: [
        InferenceLeg(
          requestId: 'gated-$index',
          feature: coachLiteFeature,
          mode: HybridMode.onlyOnDevice,
          kinds: const {DataKind.text},
          transferPermitted: false,
          provenance: Provenance.sdkOnDevice,
        ),
      ],
    ),
  );
}

String answerJson({
  String body = 'Keep the heat low and stir so the bottom does not catch.',
  Map<String, Object?>? timer,
  List<Map<String, Object?>>? extra,
}) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['tip', 'next', for (final e in extra ?? const []) e['id']],
    },
    {
      'id': 'tip',
      'component': 'stepCue',
      'title': 'Low and slow',
      'body': body,
    },
    {
      'id': 'next',
      'component': 'stepCue',
      'title': 'When it coats a spoon',
      'body': 'Move on once the sauce coats the back of a spoon.',
      'action': 'next_step',
      'actionLabel': 'Next step',
    },
    ...?extra,
  ],
  'timerSuggestion': ?timer,
});

void main() {
  late FakeHybridDispatcher dispatcher;
  late _Privacy privacy;
  late bool online;
  late CloudRoutes routes;

  CoachLite coach([HybridDispatcher? d]) => CoachLite(
    dispatcher: d ?? dispatcher,
    privacy: privacy,
    cloudRoutes: routes,
    isOnline: () => online,
  );

  Future<CoachLiteAnswer> ask(
    CoachLite lite,
    String question, {
    String sessionId = 'session-1',
    int epoch = 0,
  }) => lite.ask(
    question: question,
    step: _simmer,
    recipe: _recipe,
    confirmedFacts: const ['The cook is using a non-stick pan.'],
    sessionId: sessionId,
    epoch: epoch,
  );

  setUp(() {
    dispatcher = FakeHybridDispatcher();
    privacy = _Privacy();
    online = true;
    routes = const CloudRoutes({CloudRoute.research});
  });

  testWidgets(
    'model JSON becomes a lite workspace and one tap starts a ticking timer',
    (tester) async {
      dispatcher.enqueue(
        answerJson(timer: {'label': 'Simmer sauce', 'seconds': 9000}),
      );
      final lite = coach();
      final answer = await ask(lite, 'How often should I stir?');

      expect(answer.status, CoachLiteStatus.answered);
      expect(answer.kind, CoachLiteQuestionKind.stepHelp);
      expect(answer.handOffToResearch, isFalse);
      expect(answer.legs.single.provenance, Provenance.sdkOnDevice);
      expect(answer.timerSuggestion!.label, 'Simmer sauce');
      expect(answer.timerSuggestion!.seconds, coachLiteMaxTimerSeconds);
      expect(
        lite.isCurrent(
          answer.stamp,
          sessionId: 'session-1',
          epoch: 0,
          stepId: 'simmer',
        ),
        isTrue,
      );

      final task = dispatcher.tasks.single;
      expect(task.feature, coachLiteFeature);
      expect(task.jsonSchema, coachLiteResponseSchema);
      final prompt = (task.parts.single as HybridText).text;
      for (final expected in [
        'Simmer the sauce',
        'simmer the tomato sauce',
        'coat the back of a spoon',
        'Crushed tomatoes',
        'allergens: wheat',
        'non-stick pan',
        'How often should I stir?',
      ]) {
        expect(prompt, contains(expected));
      }

      var now = DateTime(2026, 11, 25, 18);
      final ui = CookingUiController(clock: () => now);
      ui.applyToolPayload(answer.payload);
      final started = <(String, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  CookingSurface(controller: ui),
                  TimerSuggestionCard(
                    suggestion: answer.timerSuggestion!,
                    onStart: (label, seconds) {
                      started.add((label, seconds));
                      ui.startTimer(
                        id: 'lite-${answer.stamp.sequence}',
                        label: label,
                        seconds: seconds,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Low and slow'), findsOneWidget);
      expect(find.text('Suggested timer · 60 min'), findsOneWidget);
      expect(ui.timers, isEmpty, reason: 'a suggestion never starts itself');

      await tester.tap(find.text('Start timer'));
      await tester.pump();
      expect(started, [('Simmer sauce', 3600)]);
      expect(find.text('Timer started'), findsOneWidget);
      // The control is now disabled, so a second tap cannot start a duplicate.
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Timer started'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(button.enabled, isFalse);

      final timer = ui.timers.single;
      expect(timer.remaining(now), const Duration(hours: 1));
      now = now.add(const Duration(minutes: 5));
      ui.refreshTimers();
      expect(timer.remaining(now), const Duration(minutes: 55));

      await tester.pumpWidget(const SizedBox());
      ui.dispose();
    },
  );

  test('timer suggestions are clamped to 60-3600 seconds or dropped', () {
    expect(
      CoachLiteTimerSuggestion.fromModel({'label': 'Rest', 'seconds': 5})!
          .seconds,
      60,
    );
    expect(
      CoachLiteTimerSuggestion.fromModel({'label': 'Rest', 'seconds': 90.4})!
          .seconds,
      90,
    );
    expect(
      CoachLiteTimerSuggestion.fromModel({'label': ' ', 'seconds': 90}),
      isNull,
    );
    expect(
      CoachLiteTimerSuggestion.fromModel({'label': 'x', 'seconds': '9'}),
      isNull,
    );
    expect(CoachLiteTimerSuggestion.fromModel(null), isNull);
  });

  test('a component outside the lite allowlist is rejected', () async {
    final recording = _RecordingDispatcher();
    final invalid = answerJson(
      extra: [
        {
          'id': 'watch',
          'component': 'watchStatus',
          'title': 'Watching',
          'body': 'I will tell you when it is ready.',
          'status': 'watching',
        },
      ],
    );
    recording.enqueue(invalid);
    final answer = await ask(coach(recording), 'Is the heat right?');

    // The dispatcher got the lite validator, so an on-device answer like this
    // can earn one cloud retry where policy allows.
    final validate = recording.validators.single!;
    expect(validate(invalid), contains('Not available in Coach Lite'));
    expect(validate(answerJson()), isNull);

    expect(answer.status, CoachLiteStatus.invalid);
    expect(answer.timerSuggestion, isNull);
    // The fallback is app-authored from the recipe and is itself lite-valid.
    expect(validateLiteCookingUi(answer.payload), hasLength(2));
    final body = answer.components.last['body'] as String;
    expect(body, contains("answer could not be shown"));
    expect(body, contains('simmer the tomato sauce'));
  });

  test('answers that certify doneness or safety are rejected', () {
    for (final claim in [
      'The sauce is done.',
      "It's safe to eat now.",
      'The chicken is safe.',
      'Your eggs are now done!',
      'It’s safe now.',
      'The chicken is fully cooked.',
      'This is gluten-free.',
      'It has reached a safe temperature.',
    ]) {
      expect(
        validateCoachLiteResponse(answerJson(body: claim)),
        contains('must not certify'),
        reason: claim,
      );
    }
    for (final conditional in [
      "It's done when it coats a spoon.",
      'Stir until the sauce is done, then taste.',
      'Check whether it is cooked through with a thermometer.',
    ]) {
      expect(
        validateCoachLiteResponse(answerJson(body: conditional)),
        isNull,
        reason: conditional,
      );
    }
    expect(validateCoachLiteResponse('not json'), isNotNull);
    expect(validateCoachLiteResponse('```json\n${answerJson()}\n```'), isNull);
  });

  test('overlapping questions: only the newest answer applies', () async {
    final gated = _GatedDispatcher();
    final lite = coach(gated);
    final first = ask(lite, 'How often should I stir?');
    final second = ask(lite, 'Should I cover the pan?');
    expect(gated.cancelled, [true, false], reason: 'newer question cancels');

    // The newer answer arrives first, then the older one arrives late.
    gated.answer(1, answerJson(body: 'Leave the lid off so it thickens.'));
    gated.answer(0, answerJson(body: 'Stir every minute.'));
    final newer = await second;
    final older = await first;

    bool current(CoachLiteAnswer a) => lite.isCurrent(
      a.stamp,
      sessionId: 'session-1',
      epoch: 0,
      stepId: 'simmer',
    );
    expect(newer.status, CoachLiteStatus.answered);
    expect(current(newer), isTrue);
    expect(older.status, CoachLiteStatus.cancelled);
    expect(current(older), isFalse);
    expect(older.stamp.sequence, lessThan(newer.stamp.sequence));
  });

  test('a cancelled fake operation reports cancelled, not an answer', () async {
    dispatcher.delay = const Duration(milliseconds: 5);
    dispatcher.enqueue(answerJson());
    dispatcher.enqueue(answerJson());
    final lite = coach();
    final first = ask(lite, 'First?');
    final second = ask(lite, 'Second?');
    expect((await first).status, CoachLiteStatus.cancelled);
    expect((await second).status, CoachLiteStatus.answered);
    expect(dispatcher.cancelledOperations, ['op-1']);
  });

  test(
    'a session change with the same step id makes an answer stale',
    () async {
      dispatcher.enqueue(answerJson());
      final lite = coach();
      final answer = await ask(lite, 'How often should I stir?');
      expect(answer.stamp.stepId, 'simmer');
      expect(
        lite.isCurrent(
          answer.stamp,
          sessionId: 'session-2',
          epoch: 0,
          stepId: 'simmer',
        ),
        isFalse,
      );
      expect(
        lite.isCurrent(
          answer.stamp,
          sessionId: 'session-1',
          epoch: 1,
          stepId: 'simmer',
        ),
        isFalse,
        reason: 'the coordinator bumped its epoch (e.g. Live connected)',
      );
      lite.cancel();
      expect(
        lite.isCurrent(
          answer.stamp,
          sessionId: 'session-1',
          epoch: 0,
          stepId: 'simmer',
        ),
        isFalse,
      );
    },
  );

  test(
    'factual questions are flagged for grounded research when allowed',
    () async {
      dispatcher.enqueue(answerJson());
      final answer = await ask(
        coach(),
        'Can I substitute passata instead of crushed tomatoes?',
      );
      expect(answer.kind, CoachLiteQuestionKind.substitution);
      expect(answer.isFactual, isTrue);
      expect(answer.researchAllowed, isTrue);
      expect(answer.handOffToResearch, isTrue);
      expect(answer.sourcesUnavailable, isNull);
      final root = answer.components.first;
      expect((root['children'] as List).first, 'app_sources');
      expect(validateLiteCookingUi(answer.payload), isNotEmpty);
    },
  );

  test(
    'safety questions get the app safety notice and never certify',
    () async {
      dispatcher.enqueue(answerJson());
      final answer = await ask(coach(), 'Is it safe to leave the sauce out?');
      expect(answer.kind, CoachLiteQuestionKind.safety);
      final safety = answer.components.firstWhere(
        (c) => c['id'] == 'app_safety',
      );
      expect(safety['body'], coachLiteSafetyNotice);
      expect(safety['body'], contains('food thermometer'));
    },
  );

  group('without sources the answer says it cannot check them', () {
    Future<CoachLiteAnswer> factual() {
      dispatcher.enqueue(answerJson());
      return ask(coach(), 'Can I use butter instead of oil?');
    }

    test('offline', () async {
      online = false;
      final answer = await factual();
      expect(answer.handOffToResearch, isFalse);
      expect(answer.sourcesUnavailable, CoachLiteSourcesUnavailable.offline);
      final notice = answer.components.firstWhere(
        (c) => c['id'] == 'app_sources',
      );
      expect(notice['title'], "Can't check sources");
      expect(
        notice['body'],
        startsWith("You're offline, so I can't check sources for this."),
      );
    });

    test('on-device only', () async {
      privacy.localOnlyFeatures.add(coachLiteFeature);
      final answer = await factual();
      expect(answer.handOffToResearch, isFalse);
      expect(answer.sourcesUnavailable, CoachLiteSourcesUnavailable.localOnly);
      expect(
        answer.components.firstWhere((c) => c['id'] == 'app_sources')['body'],
        contains("On-device only is on, so I can't check sources"),
      );
    });

    test('research route not approved for this build', () async {
      routes = const CloudRoutes({});
      final answer = await factual();
      expect(answer.handOffToResearch, isFalse);
      expect(
        answer.sourcesUnavailable,
        CoachLiteSourcesUnavailable.notApproved,
      );
    });
  });

  test('a blocked dispatch shows the recipe step, labelled with why', () async {
    dispatcher.enqueueBlocked(RouteReason.noLocalModel);
    final answer = await ask(coach(), 'How often should I stir?');
    expect(answer.status, CoachLiteStatus.blocked);
    expect(answer.blocked, RouteReason.noLocalModel);
    expect(answer.legs, isEmpty);
    expect(validateLiteCookingUi(answer.payload), hasLength(2));
    expect(
      answer.components.last['body'],
      startsWith("This device can't run the on-device coach right now."),
    );
  });

  test('classifier', () {
    for (final (q, kind) in [
      ('How do I know when to flip it?', CoachLiteQuestionKind.stepHelp),
      ('Take it out of the oven now?', CoachLiteQuestionKind.stepHelp),
      ('Can I swap honey for sugar?', CoachLiteQuestionKind.substitution),
      ("I don't have shallots", CoachLiteQuestionKind.substitution),
      ('Is the chicken cooked through?', CoachLiteQuestionKind.safety),
      ('Does this contain nuts?', CoachLiteQuestionKind.safety),
      ('What internal temperature for pork?', CoachLiteQuestionKind.safety),
      (
        'How long can leftovers stay in the fridge?',
        CoachLiteQuestionKind.safety,
      ),
    ]) {
      expect(classifyCoachLiteQuestion(q), kind, reason: q);
    }
  });

  test('the prompt stays inside the local budget with long context', () {
    final lite = coach();
    final prompt = buildCoachLitePrompt(
      question: 'Q${'?' * 2000}',
      step: _simmer,
      recipe: _recipe,
      confirmedFacts: [for (var i = 0; i < 200; i++) 'fact $i ${'x' * 300}'],
      maxChars: lite.promptCharBudget,
    );
    expect(prompt.length, lessThanOrEqualTo(lite.promptCharBudget));
    expect(prompt, contains('Simmer the sauce'));
    expect(prompt, contains('fact 199'), reason: 'newest facts are kept');
    expect(prompt, isNot(contains('fact 0 ')));
    final tokens =
        (coachLiteSystemInstruction.length +
                prompt.length +
                jsonEncode(coachLiteResponseSchema).length) /
            4 +
        coachLiteMaxOutputTokens;
    expect(tokens, lessThanOrEqualTo(coachLiteDefaultMaxTotalTokens));
  });
}
