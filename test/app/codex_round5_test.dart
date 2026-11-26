// Codex review of #221 at 3b0369d: narrowed promises and small fixes.
// Fakes only.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/plain_research_text.dart';
import 'package:soussight/live/live_tools.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_handoff.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/pantry_ui.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/trust/privacy_preferences.dart';
import 'package:soussight/watch/watch_verdict.dart';

/// Microphone that delivers one usable clip as soon as capture starts.
class _ClipMedia extends DemoLiveMedia {
  final _mic = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get microphone => _mic.stream;
  @override
  Future<void> start() async {
    scheduleMicrotask(() => _mic.add(Uint8List(32000)));
  }
}

class _Recording implements PantryClient {
  final inputs = <PantryInput>[];
  Completer<PantryResult>? gate;
  @override
  Future<PantryResult> identify(PantryInput input, List<Recipe> recipes) {
    inputs.add(input);
    return gate?.future ??
        Future.value(
          const PantryResult(
            items: [
              PantryItem(name: 'rice', confidence: PantryConfidence.high),
            ],
            meals: [],
          ),
        );
  }
}

class _Transport extends DemoLiveTransport {
  final texts = <String>[];
  @override
  Future<void> sendText(String text) async {
    texts.add(text);
    await super.sendText(text);
  }
}

class _SlowResearch implements CookingResearchClient {
  final pending = <Completer<CookingResearchResult>>[];
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) {
    final c = Completer<CookingResearchResult>();
    pending.add(c);
    return c.future;
  }
}

class _Markdown implements CookingResearchClient {
  const _Markdown(this.answer);
  final String answer;
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async =>
      CookingResearchResult(answer: answer);
}

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#1 the voice clip never rides along unseen', () {
    test('the disclosure promises nothing about other paths', () {
      expect(pantryVoiceDisclosure, startsWith('Voice lists need online'));
      expect(pantryVoiceUnavailable, contains('off in this build'));
      expect(pantryVoiceDisclosure, isNot(contains('keep everything')));
      expect(
        pantryVoiceDisclosure,
        contains('Leaving Say it deletes the clip'),
      );
    });

    testWidgets('record, switch to Type, find: no audio is sent', (
      tester,
    ) async {
      await _phone(tester);
      final recipes = (await tester.runAsync(loadRecipeCatalog))!;
      final client = _Recording();
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: PantryScreen(
            recipes: recipes,
            client: client,
            onChooseRecipe: (_, _) {},
            mediaFactory: _ClipMedia.new,
            recordDuration: const Duration(milliseconds: 300),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('mode-say')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('record-voice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('clip is ready'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mode-type')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'rice');
      final findMeal = find.byKey(const ValueKey('find-meal'));
      await tester.ensureVisible(findMeal);
      await tester.pumpAndSettle();
      await tester.tap(findMeal);
      await tester.pumpAndSettle();
      expect(client.inputs.single.audioWav, isNull);
      expect(client.inputs.single.text, 'rice');
    });
  });

  test('#2 the switch says what it guards', () {
    final coach = privacyFeatures.firstWhere((f) => f.feature == 'coach_lite');
    expect(coach.label, 'Questions to Coach Lite');
    expect(coach.detail, contains("doesn't cover Live chat or the Research"));
    expect(coach.detail, isNot(contains('go online')));
  });

  test('#2 a follow-up result is not forwarded to Live once blocked', () async {
    final services = await fakeServices();
    final transport = _Transport();
    final research = _SlowResearch();
    final cook = CookingCoordinator(
      services: services,
      isDemo: true,
      research: research,
      transportFactory: () => transport,
      media: DemoLiveMedia(),
    );
    await cook.initialize();
    await cook.connect();
    expect(cook.live.isActive, isTrue);
    String? blocked;
    final first = cook.researchQuestionNow(
      'Swap?',
      requestWorkspace: false,
      sendBlocked: () => blocked,
    );
    research.pending.single.complete(
      const CookingResearchResult(answer: 'Yes.'),
    );
    await first;
    final panel = cook.researchPanel!;
    final followUp = panel.client.followUp(
      CookingResearchQuery(
        question: panel.query.question,
        currentStep: panel.query.currentStep,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    blocked = 'Kept here.'; // the cook changed the setting mid-search
    research.pending.last.complete(const CookingResearchResult(answer: 'Ok.'));
    await followUp;
    expect(
      transport.texts.where(
        (t) => t.contains('provider returned the evidence'),
      ),
      isEmpty,
    );
    cook.dispose();
  });

  test('#14 each blocker keeps its own reason', () {
    expect(followUpBlockedMessage(null), isNull);
    expect(
      followUpBlockedMessage(CoachLiteSourcesUnavailable.offline),
      startsWith("You're offline"),
    );
    expect(
      followUpBlockedMessage(CoachLiteSourcesUnavailable.localOnly),
      contains('keep questions to Coach Lite on this device'),
    );
    expect(
      followUpBlockedMessage(CoachLiteSourcesUnavailable.notApproved),
      startsWith('Research is off'),
    );
    expect(
      followUpBlockedMessage(CoachLiteSourcesUnavailable.notRun),
      'This follow-up was not sent.',
    );
  });

  test('#3 handoff maps canonical names to the recipe IDs', () async {
    final recipes = await loadRecipeCatalog();
    final wrap = recipes.firstWhere((r) => r.id == 'chickpea_wrap_v1');
    expect(matchIngredientId('Dijon mustard', wrap), 'mustard');
    expect(matchIngredientId('lemon juice', wrap), 'lemon');
    expect(matchIngredientId('flour tortillas', wrap), 'tortillas');
    final sandwich = recipes.firstWhere(
      (r) => r.id == 'peanut_butter_sandwich_v1',
    );
    expect(matchIngredientId('peanut butter cups', sandwich), isNull);
  });

  test('#4 "0 eggs" means none', () async {
    expect(pantryTypedEntries('bread, 0 peanut butter, no eggs, 2 limes'), [
      'bread',
      'limes',
    ]);
    final recipes = await loadRecipeCatalog();
    final prompt =
        buildPantryScanTask(
              typedText: 'bread, 0 peanut butter',
              spokenItems: const [],
              photoJpeg: null,
              recipes: recipes,
            ).parts.first
            as HybridText;
    expect(practicePantryAnswer(prompt.text), isNot(contains('make this now')));
  });

  testWidgets('#5 confirmation uses the submitted text', (tester) async {
    await _phone(tester);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final client = _Recording()..gate = Completer();
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryScreen(
          recipes: recipes,
          client: client,
          onChooseRecipe: (_, _) {},
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'rice');
    final findMeal = find.byKey(const ValueKey('find-meal'));
    await tester.ensureVisible(findMeal);
    await tester.pumpAndSettle();
    await tester.tap(findMeal);
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'beans');
    client.gate!.complete(
      const PantryResult(
        items: [PantryItem(name: 'rice', confidence: PantryConfidence.high)],
        meals: [],
      ),
    );
    await tester.pumpAndSettle();
    final chip = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .firstWhere((s) => s.properties.label == 'rice, clear');
    expect(chip.properties.toggled, isTrue);
  });

  test('#6 Live layouts may not use app_ IDs', () {
    String? check(String id) => validateLiveTool(
      LiveToolCall(
        id: 'c',
        name: 'show_cooking_ui',
        arguments: {
          'stepId': 's1',
          'uiJson':
              '{"components":[{"id":"root","component":"CookingColumn",'
              '"children":["$id"]},{"id":"$id","component":"stepCue",'
              '"title":"t","body":"b"}]}',
        },
      ),
    );
    expect(check('app_watch'), contains('reserved for the app'));
    expect(check('tip'), isNull);
  });

  test(
    '#8 a cancelled practice request leaves the next one its own answer',
    () async {
      final inference = RehearsalHybridInference(
        answerDelay: const Duration(milliseconds: 20),
      );
      HybridRequest watch(String id) => HybridRequest(
        requestId: id,
        mode: HybridMode.onlyOnDevice,
        task: HybridTask(
          feature: kLocalWatchFeature,
          parts: const [HybridText('x')],
          maxOutputTokens: 50,
          timeout: const Duration(seconds: 5),
        ),
      );
      final a = inference.generate(watch('a'));
      await inference.cancel('a');
      final b = inference.generate(watch('b'));
      await expectLater(
        a,
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.cancelled,
          ),
        ),
      );
      expect(parseWatchJson((await b).text).state, WatchState.notYet);
      expect(inference.cancelled, isEmpty, reason: 'cleaned up once settled');
    },
  );

  test('#9 an answer that is only Markdown is no answer', () async {
    final query = const CookingResearchQuery(question: 'q', currentStep: 's');
    await expectLater(
      const PlainTextResearchClient(_Markdown('---\n**  **')).research(query),
      throwsA(isA<CookingResearchException>()),
    );
    expect(
      (await const PlainTextResearchClient(_Markdown('**Ok**')).research(query))
          .answer,
      'Ok',
    );
  });

  test('#12 Live is never told a prediction the cook did not make', () async {
    final services = await fakeServices();
    final transport = _Transport();
    final cook = CookingCoordinator(
      services: services,
      isDemo: true,
      research: const FakeCookingResearchClient(),
      transportFactory: () => transport,
      media: DemoLiveMedia(),
    );
    await cook.initialize();
    await cook.connect();
    await cook.checkNow();
    expect(transport.texts.last, startsWith('Am I doing this right? '));
    expect(transport.texts.last, isNot(contains('My prediction')));
    await cook.checkNow('Ready');
    expect(transport.texts.last, contains('My prediction is: Ready.'));
    cook.dispose();
  });
}
