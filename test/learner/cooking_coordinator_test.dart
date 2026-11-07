import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/live/live_controller.dart';
import 'package:soussight/live/live_types.dart';

const _recipe = Recipe(
  id: 'test-wrap',
  version: 1,
  title: 'Chickpea wrap',
  summary: 'A simple wrap.',
  ingredients: [
    Ingredient(id: 'chickpeas', name: 'Chickpeas', qty: '1 can'),
    Ingredient(id: 'yogurt', name: 'Plain yogurt', qty: '2 tbsp'),
  ],
  equipment: ['bowl', 'fork'],
  steps: [
    RecipeStep(
      id: 'prep',
      title: 'Prepare',
      instruction: 'Drain the chickpeas.',
      cue: 'No excess liquid.',
    ),
    RecipeStep(
      id: 'mash',
      title: 'Mash',
      instruction: 'Mash with a fork.',
      cue: 'Small chunks remain.',
      timerSeconds: 60,
    ),
    RecipeStep(
      id: 'mix',
      title: 'Mix',
      instruction: 'Add yogurt.',
      cue: 'Evenly coated.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

class _Sessions extends FakeSessionRepository {
  Completer<void>? updateGate;
  bool failNext = false;
  int updateCalls = 0;

  @override
  Future<CookingSession> update(
    String sessionId,
    CookingSession Function(CookingSession) mutate,
  ) async {
    updateCalls++;
    await updateGate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('Controlled persistence failure');
    }
    return super.update(sessionId, mutate);
  }
}

class _Media implements LiveMedia {
  final video = StreamController<Uint8List>.broadcast();
  final audio = StreamController<Uint8List>.broadcast();
  final failures = StreamController<String>.broadcast();
  int starts = 0;
  @override
  Stream<Uint8List> get frames => video.stream;
  @override
  Stream<Uint8List> get microphone => audio.stream;
  @override
  Stream<String> get errors => failures.stream;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {}
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void interruptPlayback() {}
  @override
  void playAudio(Uint8List pcm24khz) {}

  Future<void> dispose() async {
    await video.close();
    await audio.close();
    await failures.close();
  }
}

class _Transport implements LiveTransport {
  final source = StreamController<LiveEvent>.broadcast();
  final texts = <String>[];
  final responses = <Map<String, Object?>>[];
  String? instruction;
  bool failNextSend = false;
  @override
  Stream<LiveEvent> get events => source.stream;
  @override
  Future<void> connect({required String systemInstruction}) async {
    instruction = systemInstruction;
  }

  @override
  Future<void> sendAudio(Uint8List pcm16khz) async {}
  @override
  Future<void> sendVideo(Uint8List jpeg) async {}
  @override
  Future<void> sendText(String text) async {
    if (failNextSend) {
      failNextSend = false;
      throw StateError('Controlled transport failure');
    }
    texts.add(text);
  }

  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async {
    responses.add(response);
  }

  @override
  Future<void> close() async {}
}

class _Research implements CookingResearchClient {
  final queries = <CookingResearchQuery>[];
  final pending = <Completer<CookingResearchResult>>[];
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) {
    queries.add(query);
    final completer = Completer<CookingResearchResult>();
    pending.add(completer);
    return completer.future;
  }
}

class _Fixture {
  _Fixture() {
    cook = CookingCoordinator(
      services: AppServices(
        auth: FakeAuthService(),
        recipes: FakeRecipeRepository(_recipe),
        sessions: sessions,
        requests: FakeRequestRepository(),
        instructors: FakeInstructorRepository(),
        assessment: FakeAssessmentClient(),
        triage: FakeTriageClient(),
        bundledRecipe: _recipe,
        clock: () => now,
      ),
      research: research,
      transportFactory: () => transport,
      media: media,
    );
  }
  final sessions = _Sessions();
  final transport = _Transport();
  final media = _Media();
  final research = _Research();
  DateTime now = DateTime.utc(2026, 11, 7, 21);
  late final CookingCoordinator cook;
  bool _disposed = false;

  Future<void> initialize() async {
    await cook.initialize();
    await _flush();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cook.live.stop();
    cook.dispose();
    await _flush();
    await transport.source.close();
    await media.dispose();
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Fixture fixture;
  setUp(() {
    fixture = _Fixture();
  });
  tearDown(() async {
    await fixture.dispose();
  });

  test(
    'fresh ingredients stay unconfirmed and dated sessions can connect',
    () async {
      await fixture.initialize();
      expect(fixture.cook.error, isNull);
      expect(fixture.cook.session!.createdAt, isA<DateTime>());
      expect(fixture.cook.session!.ingredients, isEmpty);
      expect(fixture.cook.confirmedIngredients, isEmpty);
      expect(fixture.cook.ui.confirmedIngredients, isEmpty);
      expect(
        fixture.cook.cookingContext,
        contains('Ingredients the cook confirmed: []'),
      );
      await fixture.cook.connect();
      expect(fixture.media.starts, 1);
      expect(fixture.transport.instruction, contains('Current step: prep'));
      expect(fixture.cook.live.status, LiveCookingStatus.listening);
    },
  );

  test(
    'connection context explicitly requests a contextual generated workspace',
    () async {
      await fixture.initialize();
      await fixture.cook.connect();
      expect(fixture.transport.instruction, contains('call show_cooking_ui'));
      expect(
        fixture.transport.instruction,
        contains('initial checklist is a fallback'),
      );
      expect(
        fixture.transport.instruction,
        contains('Ingredients the cook confirmed: []'),
      );
    },
  );

  test(
    'completed research requests generated panels with actual evidence only',
    () async {
      await fixture.initialize();
      await fixture.cook.connect();
      fixture.transport.texts.clear();
      final pending = fixture.cook.researchQuestionNow('Can I use yogurt?');
      fixture.research.pending.single.complete(
        CookingResearchResult(
          answer: 'Plain yogurt is an option.',
          clarifyingQuestion: 'Is your yogurt unsweetened?',
          citations: [
            CookingCitation(
              title: 'Provider source',
              uri: Uri.parse('https://example.com/yogurt'),
            ),
          ],
          searchSuggestionsHtml: '<div>Provider attribution</div>',
        ),
      );
      await pending;
      final request = fixture.transport.texts.single;
      expect(request, contains('Call show_cooking_ui'));
      expect(request, contains('https://example.com/yogurt'));
      expect(request, contains('Is your yogurt unsweetened?'));
      expect(request, contains('research is not cook confirmation'));
      expect(request, isNot(contains('<div>')));
      expect(
        fixture.cook.researchResult!.searchSuggestionsHtml,
        '<div>Provider attribution</div>',
      );
      expect(fixture.cook.session!.confirmedFacts, isEmpty);
    },
  );

  test('successful research survives a workspace transport failure', () async {
    await fixture.initialize();
    await fixture.cook.connect();
    final pending = fixture.cook.researchQuestionNow('Can I use yogurt?');
    fixture.transport.failNextSend = true;
    const result = CookingResearchResult(answer: 'Keep this completed answer.');
    fixture.research.pending.single.complete(result);
    expect(await pending, same(result));
    expect(fixture.cook.researchResult, same(result));
    expect(fixture.cook.error, isNull);
    expect(fixture.cook.live.status, LiveCookingStatus.error);
    expect(fixture.cook.live.error, contains('could not reach the live coach'));
  });

  test('uncited research is forwarded without invented grounding', () async {
    await fixture.initialize();
    await fixture.cook.connect();
    fixture.transport.texts.clear();
    final pending = fixture.cook.researchQuestionNow('How much?');
    fixture.research.pending.single.complete(
      const CookingResearchResult(answer: 'No sourced answer available.'),
    );
    await pending;
    expect(fixture.transport.texts.single, contains('"sources":[]'));
    expect(
      fixture.transport.texts.single,
      contains('Do not invent sources or claim grounding'),
    );
  });

  test('Live research tool replies with evidence without creating a duplicate user turn', () async {
    await fixture.initialize();
    await fixture.cook.connect();
    fixture.transport.texts.clear();
    fixture.transport.source.add(
      const LiveToolCall(
        id: 'research',
        name: 'research_cooking',
        arguments: {'question': 'Can I use yogurt?'},
      ),
    );
    await _flush();
    fixture.research.pending.single.complete(
      const CookingResearchResult(
        answer: 'Ask about sweetness.',
        clarifyingQuestion: 'Is it plain?',
      ),
    );
    await _flush();
    expect(fixture.transport.texts, isEmpty);
    expect(
      fixture.transport.responses.single['clarifyingQuestion'],
      'Is it plain?',
    );
    expect(
      fixture.transport.responses.single['workspaceInstruction'],
      contains('show_cooking_ui'),
    );
  });

  test('model replaces fallback and can recompose while confirmed state and timer persist', () async {
    await fixture.initialize();
    await fixture.cook.connect();
    fixture.cook.ui.confirmIngredient('ingredients', 'yogurt', true);
    await _flush();
    await fixture.cook.startTimer('mash-timer', 'Mash', 60);
    final deadline = fixture.cook.ui.timers.single.deadline;
    for (final panel in [
      {
        'id': 'question',
        'component': 'cookQuestion',
        'title': 'Your yogurt',
        'question': 'Is it plain?',
        'options': [
          {'id': 'yes', 'label': 'Yes'},
          {'id': 'unsure', 'label': 'Not sure'},
        ],
      },
      {
        'id': 'comparison',
        'component': 'comparison',
        'title': 'Your bowl now',
        'observed': 'Large pieces',
        'target': 'Small chunks',
        'cue': 'Mash a little more',
      },
    ]) {
      fixture.transport.source.add(
        LiveToolCall(
          id: panel['id'] as String,
          name: 'show_cooking_ui',
          arguments: {
            'uiJson': jsonEncode({
              'components': [
                {
                  'id': 'root',
                  'component': 'CookingColumn',
                  'children': [panel['id']],
                },
                panel,
              ],
            }),
          },
        ),
      );
      await _flush();
      expect(fixture.cook.ui.components.map((c) => c['id']), [
        'root',
        panel['id'],
      ]);
      expect(fixture.cook.ui.confirmedIngredients, contains('yogurt'));
      expect(fixture.cook.ui.timers.single.deadline, deadline);
      fixture.transport.source.add(
        const LiveTranscript('Short coaching reply', isUser: false),
      );
      await _flush();
      expect(fixture.cook.ui.components.last['id'], panel['id']);
    }
  });

  test('two Next step clicks while saving complete exactly one step', () async {
    await fixture.initialize();
    fixture.sessions.updateGate = Completer<void>();
    final first = fixture.cook.advanceStep();
    await fixture.cook.advanceStep();
    expect(fixture.sessions.updateCalls, 1);
    expect(fixture.cook.advancing, isTrue);
    expect(fixture.cook.step.id, 'prep');
    fixture.sessions.updateGate!.complete();
    await first;
    expect(fixture.cook.step.id, 'mash');
    expect(fixture.cook.session!.completedStepIds, ['prep']);
    expect(fixture.cook.advancing, isFalse);
  });

  test(
    'failed step save leaves step, completion, and active watch unchanged',
    () async {
      await fixture.initialize();
      await fixture.cook.connect();
      fixture.cook.startWatch();
      final watchId = fixture.cook.live.watchId;
      fixture.sessions.failNext = true;
      await fixture.cook.advanceStep();
      expect(fixture.cook.step.id, 'prep');
      expect(fixture.cook.session!.completedStepIds, isEmpty);
      expect(fixture.cook.live.watchId, watchId);
      expect(fixture.cook.advancing, isFalse);
      expect(fixture.cook.error, contains('Could not save the next step'));
      expect(
        fixture.transport.texts.where(
          (text) => text.contains('previous step is finished'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'restored timer preserves ID and deadline when the step button is repeated',
    () async {
      final saved = await fixture.sessions.createOrResume('learner-1', _recipe);
      final deadline = fixture.now.add(const Duration(seconds: 300));
      await fixture.sessions.update(
        saved.id,
        (current) => current.copyWith(
          timerId: 'step-prep',
          timerLabel: 'Prep timer',
          timerDeadline: deadline,
        ),
      );
      await fixture.initialize();
      fixture.now = fixture.now.add(const Duration(seconds: 30));
      await fixture.cook.startStepTimer();
      expect(fixture.cook.ui.timers, hasLength(1));
      expect(fixture.cook.ui.timers.single.id, 'step-prep');
      expect(fixture.cook.ui.timers.single.deadline, deadline);
      expect(fixture.cook.session!.timerId, 'step-prep');
      expect(fixture.cook.session!.timerDeadline, deadline);
      expect(
        fixture.cook.ui.timers.single.remaining(fixture.now),
        const Duration(seconds: 270),
      );
    },
  );

  test('failed ingredient save rolls back its checkmark and never tells Live it was confirmed', () async {
    await fixture.initialize();
    await fixture.cook.connect();
    fixture.transport.texts.clear();
    fixture.sessions.failNext = true;
    fixture.cook.ui.confirmIngredient('ingredients', 'yogurt', true);
    expect(fixture.cook.ui.confirmedIngredients, contains('yogurt'));
    await _flush();
    expect(fixture.cook.ui.confirmedIngredients, isNot(contains('yogurt')));
    expect(fixture.cook.session!.ingredients.containsKey('yogurt'), isFalse);
    expect(fixture.cook.confirmedIngredients, isEmpty);
    expect(fixture.transport.texts, isEmpty);
    expect(fixture.cook.error, contains('could not be saved'));
  });

  test('failed clarification save keeps the question pending and sends no false fact', () async {
    await fixture.initialize();
    await fixture.cook.connect();
    fixture.transport.source.add(
      const LiveToolCall(
        id: 'question',
        name: 'ask_cook',
        arguments: {
          'question': 'Is your yogurt plain?',
          'reason': 'The recipe needs unsweetened yogurt.',
        },
      ),
    );
    await _flush();
    expect(fixture.cook.cookQuestion, 'Is your yogurt plain?');
    fixture.transport.texts.clear();
    fixture.sessions.failNext = true;
    await expectLater(
      fixture.cook.confirmCookAnswer('Is your yogurt plain?', 'Yes'),
      throwsStateError,
    );
    expect(fixture.cook.session!.confirmedFacts, isEmpty);
    expect(fixture.cook.cookQuestion, 'Is your yogurt plain?');
    expect(fixture.transport.texts, isEmpty);
  });

  test('an old research answer cannot replace a newer question', () async {
    await fixture.initialize();
    final old = fixture.cook.researchQuestionNow('Can I use vinegar?');
    final current = fixture.cook.researchQuestionNow('How much yogurt?');
    fixture.research.pending[1].complete(
      const CookingResearchResult(answer: 'New answer'),
    );
    expect((await current)!.answer, 'New answer');
    fixture.research.pending[0].complete(
      const CookingResearchResult(answer: 'Old answer'),
    );
    expect(await old, isNull);
    expect(fixture.cook.researchQuestion, 'How much yogurt?');
    expect(fixture.cook.researchResult!.answer, 'New answer');
    expect(fixture.cook.researching, isFalse);
  });

  test(
    'research based on a previous step cannot be applied after advancement',
    () async {
      await fixture.initialize();
      await fixture.cook.connect();
      final pending = fixture.cook.researchQuestionNow(
        'What should this look like?',
      );
      expect(
        fixture.research.queries.single.currentStep,
        startsWith('Prepare:'),
      );
      await fixture.cook.advanceStep();
      fixture.transport.texts.clear();
      fixture.research.pending.single.complete(
        const CookingResearchResult(answer: 'Old prep guidance'),
      );
      expect(await pending, isNull);
      expect(fixture.cook.researchResult, isNull);
      expect(fixture.cook.researching, isFalse);
      expect(fixture.transport.texts, isEmpty);
    },
  );

  test('research using unconfirmed ingredients is stale after cook confirms a new fact', () async {
    await fixture.initialize();
    final pending = fixture.cook.researchQuestionNow(
      'Which ingredients should I mix?',
    );
    expect(fixture.research.queries.single.confirmedIngredients, isEmpty);
    fixture.cook.ui.confirmIngredient('ingredients', 'yogurt', true);
    await _flush();
    expect(fixture.cook.confirmedIngredients, ['Plain yogurt']);
    fixture.research.pending.single.complete(
      const CookingResearchResult(answer: 'Old ingredient guidance'),
    );
    expect(await pending, isNull);
    expect(fixture.cook.researchResult, isNull);
  });

  test(
    'disconnect pauses the visible watch and late readiness cannot restore it',
    () async {
      await fixture.initialize();
      await fixture.cook.connect();
      fixture.cook.startWatch();
      final oldId = fixture.cook.live.watchId;
      await fixture.cook.live.stop();
      final watch = fixture.cook.ui.components.singleWhere(
        (component) => component['id'] == 'watch',
      );
      expect(watch['status'], 'paused');
      fixture.transport.source.add(
        LiveToolCall(
          id: 'late',
          name: 'report_readiness',
          arguments: {
            'watchId': oldId,
            'state': 'ready',
            'observation': 'Old frame looks ready.',
          },
        ),
      );
      await _flush();
      expect(fixture.cook.alert, isNull);
      expect(fixture.cook.live.watchId, isNull);
    },
  );

  test(
    'a cancelled step timer can restart with a new ID and one active deadline',
    () async {
      await fixture.initialize();
      await fixture.cook.startStepTimer();
      final original = fixture.cook.ui.timers.single;
      fixture.cook.ui.dismissTimer(original.id);
      await _flush();
      expect(fixture.cook.ui.timers, isEmpty);
      expect(fixture.cook.session!.timerId, isNull);
      expect(fixture.cook.session!.timerDeadline, isNull);
      fixture.now = fixture.now.add(const Duration(seconds: 10));
      await fixture.cook.startStepTimer();
      final restarted = fixture.cook.ui.timers.single;
      expect(restarted.id, isNot(original.id));
      expect(restarted.deadline, fixture.now.add(const Duration(minutes: 1)));
      expect(fixture.cook.session!.timerId, restarted.id);
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await fixture.cook.startStepTimer();
      expect(fixture.cook.ui.timers, hasLength(1));
      expect(fixture.cook.ui.timers.single.id, restarted.id);
      expect(fixture.cook.ui.timers.single.deadline, restarted.deadline);
    },
  );

  test('a failed pending confirmation after disposal does not touch the disposed UI', () async {
    await fixture.initialize();
    var notifications = 0;
    fixture.cook.addListener(() {
      notifications++;
    });
    fixture.sessions.updateGate = Completer<void>();
    fixture.sessions.failNext = true;
    fixture.cook.ui.confirmIngredient('ingredients', 'yogurt', true);
    await _flush();
    expect(fixture.sessions.updateCalls, 1);
    await fixture.dispose();
    final atDisposal = notifications;
    fixture.sessions.updateGate!.complete();
    // An attempted rollback into a disposed CookingUiController throws here
    // as an unhandled Future error, which fails this test automatically.
    await _flush();
    expect(notifications, atDisposal);
  });

  test('cook-confirmed generated ingredients persist and enter later research context', () async {
    await fixture.initialize();
    expect(
      _recipe.ingredients.any((ingredient) => ingredient.id == 'tomatoes'),
      isFalse,
    );
    fixture.cook.ui.applyToolPayload({
      'components': [
        {
          'id': 'root',
          'component': 'CookingColumn',
          'children': ['found'],
        },
        {
          'id': 'found',
          'component': 'ingredientChecklist',
          'title': 'Also on your counter',
          'items': [
            {'id': 'tomatoes', 'label': 'Fresh tomatoes'},
          ],
        },
      ],
    });
    expect(fixture.cook.confirmedIngredients, isEmpty);
    fixture.cook.ui.confirmIngredient('found', 'tomatoes', true);
    await _flush();
    expect(
      fixture.cook.session!.ingredients['tomatoes'],
      IngredientStatus.have,
    );
    expect(fixture.cook.ui.confirmedIngredients, contains('tomatoes'));
    expect(fixture.cook.confirmedIngredients, contains('tomatoes'));
    expect(fixture.cook.cookingContext, contains('tomatoes'));
    final pending = fixture.cook.researchQuestionNow(
      'Can I add what is on my counter?',
    );
    expect(
      fixture.research.queries.single.confirmedIngredients,
      contains('tomatoes'),
    );
    fixture.research.pending.single.complete(
      const CookingResearchResult(answer: 'A sourced answer.'),
    );
    await pending;
  });
}
