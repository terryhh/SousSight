// Practice-mode (rehearsal) hybrid runtime, SS-089. Fakes only: no model,
// camera or network is used.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/label/label_check.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/watch/watch_verdict.dart';

HybridTask _task(String feature, List<HybridPart> parts) => HybridTask(
  feature: feature,
  parts: parts,
  maxOutputTokens: 100,
  timeout: const Duration(seconds: 5),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Recipe> recipes;

  setUpAll(() async {
    recipes = await loadRecipeCatalog();
  });

  RehearsalHybridRuntime runtime() => RehearsalHybridRuntime.create(
    inference: RehearsalHybridInference(answerDelay: Duration.zero),
  );

  group('pantry: the result respects the typed list (item 9)', () {
    test('bread, peanut butter, banana → peanut butter sandwich first', () {
      final prompt =
          buildPantryScanTask(
                typedText: 'bread, peanut butter, banana',
                spokenItems: const [],
                photoJpeg: null,
                recipes: recipes,
              ).parts.first
              as HybridText;
      final answer =
          jsonDecode(practicePantryAnswer(prompt.text)) as Map<String, dynamic>;
      final items = [for (final i in answer['items'] as List) i['name']];
      expect(items, ['bread', 'peanut butter', 'banana']);
      final meals = answer['meals'] as List;
      expect(meals.first['recipeId'], 'peanut_butter_sandwich_v1');
      expect(meals.first['matched'], containsAll(['peanut butter']));
      expect(
        meals.map((m) => m['recipeId']),
        isNot(contains('black_bean_corn_salsa_v1')),
      );
      expect(answer['question'], contains('banana'));
      // The answer is a valid pantry result for this catalog.
      final parsed = parsePantryResult(jsonEncode(answer), {
        for (final r in recipes) r.id,
      });
      expect(parsed.meals.first.recipeId, 'peanut_butter_sandwich_v1');
    });

    test('nothing typed that matches: items only, no meals, no question', () {
      final answer = jsonDecode(
        practicePantryAnswer(
          jsonEncode({
            'catalog': [
              {
                'recipeId': 'r1',
                'ingredients': ['Bread', 'Jam?'],
              },
            ],
            'typedByCook': '2 apples and a pear',
          }),
        ),
      ) as Map<String, dynamic>;
      expect(
        [for (final i in answer['items'] as List) i['name']],
        ['apples', 'pear'],
      );
      expect(answer['meals'], isEmpty);
      expect(answer.containsKey('question'), isFalse);
    });

    test('malformed prompt gives an empty, valid answer', () {
      final answer = jsonDecode(practicePantryAnswer('not json')) as Map;
      expect(answer['items'], isEmpty);
      expect(answer['meals'], isEmpty);
    });

    test('a meal with nothing missing says you can make it now', () {
      final answer = jsonDecode(
        practicePantryAnswer(
          jsonEncode({
            'catalog': [
              {
                'recipeId': 'toast',
                'ingredients': ['Bread', 'Butter?'],
              },
            ],
            'typedByCook': 'bread',
          }),
        ),
      ) as Map<String, dynamic>;
      final meal = (answer['meals'] as List).single as Map;
      expect(meal['why'], 'You have bread, so you can make this now.');
      expect(meal['missing'], isEmpty);
    });

    test('RehearsalPantryClient: typed list runs through the dispatcher, '
        'labelled simulated; legs are never on-device', () async {
      final hybrid = runtime();
      final result = await RehearsalPantryClient(hybrid)
          .identify(const PantryInput(text: 'bread, peanut butter'), recipes);
      expect(result.simulated, isTrue);
      expect(result.items.map((i) => i.name), ['bread', 'peanut butter']);
      expect(result.meals.first.recipeId, 'peanut_butter_sandwich_v1');
      expect(result.legs, isNotEmpty);
      for (final leg in [...result.legs, ...hybrid.ledger.legs]) {
        expect(leg.provenance, Provenance.simulated);
        expect(leg.transferPermitted, isFalse);
      }
    });

    test('RehearsalPantryClient: a pretend photo alone uses the canned '
        'rehearsal result', () async {
      final result = await RehearsalPantryClient(
        runtime(),
        fallback: const FakePantryClient(delay: Duration.zero),
      ).identify(const PantryInput(), recipes);
      expect(result.simulated, isTrue);
      expect(result.legs.single.provenance, Provenance.simulated);
    });

    test('the canned chickpea wrap matches the bundled recipe asset', () async {
      final result = await const FakePantryClient(delay: Duration.zero)
          .identify(const PantryInput(), recipes);
      final wrap = result.meals.firstWhere(
        (m) => m.recipeId == 'chickpea_wrap_v1',
      );
      final recipe = recipes.firstWhere((r) => r.id == 'chickpea_wrap_v1');
      bool names(String item, Ingredient i) =>
          practiceHasIngredient(item, i.name) ||
          i.name.toLowerCase().contains(item.toLowerCase());
      // Every "still need" item is a required ingredient of the asset...
      for (final item in wrap.missing) {
        final match = recipe.ingredients.where((i) => names(item, i)).toList();
        expect(match, isNotEmpty, reason: '$item is not in the recipe');
        expect(match.every((i) => !i.optional), isTrue, reason: item);
      }
      // ...every required ingredient is accounted for (Codex #221)...
      for (final ingredient in recipe.ingredients.where((i) => !i.optional)) {
        expect(
          [
            ...wrap.matched,
            ...wrap.missing,
          ].any((item) => names(item, ingredient)),
          isTrue,
          reason: '${ingredient.name} is missing from the fake',
        );
      }
      // ...and everything it already has is in the recipe too.
      for (final item in wrap.matched) {
        expect(
          recipe.ingredients.any((i) => names(item, i)),
          isTrue,
          reason: item,
        );
      }
    });

    test(
      'Codex #221: ranking needs ingredient identity, not a shared word',
      () {
        expect(
          practiceHasIngredient('sunflower seed butter', 'Peanut butter'),
          isFalse,
        );
        expect(practiceHasIngredient('peanut butter', 'Peanut butter'), isTrue);
        expect(
          practiceHasIngredient(
            'black beans',
            'Canned black beans, drained and rinsed',
          ),
          isTrue,
        );
        expect(
          practiceHasIngredient(
            'tortillas',
            'Tortilla chips or tortillas, for serving',
          ),
          isTrue,
        );
        final prompt =
            buildPantryScanTask(
                  typedText: 'bread, sunflower seed butter',
                  spokenItems: const [],
                  photoJpeg: null,
                  recipes: recipes,
                ).parts.first
                as HybridText;
        final answer = jsonDecode(
          practicePantryAnswer(prompt.text),
        ) as Map<String, dynamic>;
        final pb = (answer['meals'] as List).firstWhere(
          (m) => m['recipeId'] == 'peanut_butter_sandwich_v1',
        ) as Map;
        expect(pb['matched'], ['bread']);
        expect(pb['missing'], contains('peanut butter'));
        expect(pb['why'], isNot(contains('can make this now')));
      },
    );

    test(
      'Codex #221: a pretend photo writes its legs to the ledger once',
      () async {
        final hybrid = runtime();
        final result = await RehearsalPantryClient(
          hybrid,
          fallback: const FakePantryClient(delay: Duration.zero),
        ).identify(const PantryInput(), recipes);
        expect(result.legs, hasLength(1));
        expect(hybrid.ledger.legs, hasLength(1));
        expect(hybrid.ledger.legs.single.provenance, Provenance.simulated);
        expect(
          hybrid.ledger.legs.single.requestId,
          result.legs.single.requestId,
        );
      },
    );
  });

  group('scripted answers', () {
    test('Coach Lite: a valid, pretend answer about the step', () {
      final prompt = buildCoachLitePrompt(
        question: 'How thick should I spread it?',
        step: const RecipeStep(
          id: 's1',
          title: 'Spread',
          instruction: 'Spread the peanut butter edge to edge.',
          cue: 'An even layer.',
          timerSeconds: 60,
        ),
        recipe: recipes.first,
        confirmedFacts: const [],
        maxChars: 4000,
      );
      final text = practiceCoachAnswer(prompt);
      final parsed = parseCoachLiteResponse(text);
      expect(parsed.timer?.seconds, 60);
      final body = jsonEncode(parsed.components);
      expect(body, contains('How thick should I spread it?'));
      expect(body, contains('pretend answer'));
      expect(body, contains('An even layer.'));
      expect(validateCoachLiteResponse(text), isNull);
    });

    test('Coach Lite: no question, no timer', () {
      final text = practiceCoachAnswer('Step title: "Wait"');
      final decoded = jsonDecode(text) as Map;
      expect(decoded.containsKey('timerSuggestion'), isFalse);
      expect(jsonEncode(decoded), isNot(contains('You asked')));
    });

    test('watch: not_yet → unsure → ready, all parseable and modest', () {
      final states = [
        for (var i = 0; i < 4; i++) parseWatchJson(practiceWatchAnswer(i)),
      ];
      expect(states.map((s) => s.state), [
        WatchState.notYet,
        WatchState.unsure,
        WatchState.ready,
        WatchState.notYet,
      ]);
      expect(states.every((s) => !s.redacted), isTrue);
      expect(states.first.whatISee, startsWith('Practice camera:'));
    });

    test('label: typed text names allergens; a photo is unreadable', () {
      final typed = parseLabelReading(
        practiceLabelAnswer(buildTypedPrompt('Contains: PEANUTS, wheat.')),
      );
      expect(typed.readable, isTrue);
      expect(typed.allergensMentioned, containsAll(['peanut', 'wheat']));
      final photo = parseLabelReading(practiceLabelAnswer(buildPhotoPrompt()));
      expect(photo.readable, isFalse);
    });

    test('an unscripted feature fails as unavailable', () async {
      final inference = RehearsalHybridInference(answerDelay: Duration.zero);
      await expectLater(
        inference.generate(
          HybridRequest(
            requestId: 'r',
            mode: HybridMode.onlyOnDevice,
            task: _task('recipe_draft', const [HybridText('x')]),
          ),
        ),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.unavailable,
          ),
        ),
      );
    });

    test('concurrent requests each get their own answer', () async {
      final inference = RehearsalHybridInference(answerDelay: Duration.zero);
      final watch = inference.generate(
        HybridRequest(
          requestId: 'w',
          mode: HybridMode.onlyOnDevice,
          task: _task(kLocalWatchFeature, const [HybridText('x')]),
        ),
      );
      final label = inference.generate(
        HybridRequest(
          requestId: 'l',
          mode: HybridMode.onlyOnDevice,
          task: _task(kLabelCheckFeature, [
            HybridText(buildTypedPrompt('milk')),
          ]),
        ),
      );
      expect(parseWatchJson((await watch).text).state, WatchState.notYet);
      expect((await watch).source, InferenceSource.onDevice);
      expect(parseLabelReading((await label).text).allergensMentioned, [
        'milk',
      ]);
    });
  });

  group('simulated legs', () {
    InferenceLeg leg(Provenance p, {HybridErrorCode? error}) => InferenceLeg(
      requestId: 'r',
      feature: 'coach_lite',
      mode: HybridMode.onlyOnDevice,
      kinds: const {DataKind.text},
      transferPermitted: false,
      provenance: p,
      modelLabel: 'm',
      error: error,
    );

    test('finished legs become simulated; failed ones keep their truth', () {
      expect(
        simulatedLeg(leg(Provenance.sdkOnDevice)).provenance,
        Provenance.simulated,
      );
      expect(simulatedLeg(leg(Provenance.sdkOnDevice)).modelLabel, isNull);
      expect(
        simulatedLeg(leg(Provenance.sdkCloud)).provenance,
        Provenance.simulated,
      );
      final failed = leg(Provenance.unknown, error: HybridErrorCode.failed);
      expect(simulatedLeg(failed), same(failed));
    });

    test('the ledger records simulated outcomes', () {
      final ledger = SimulatedInferenceLedger(sessionId: 's');
      final entry = ledger.begin(leg(Provenance.unknown));
      ledger.complete(entry, provenance: Provenance.sdkOnDevice);
      ledger.record(leg(Provenance.sdkCloud));
      final failed = ledger.begin(leg(Provenance.unknown));
      ledger.complete(
        failed,
        provenance: Provenance.unknown,
        error: HybridErrorCode.timeout,
      );
      expect(ledger.legs.map((l) => l.provenance), [
        Provenance.simulated,
        Provenance.simulated,
        Provenance.unknown,
      ]);
    });

    test('practice mode never sends anything online', () async {
      const sender = NoCloudInPracticeMode();
      await expectLater(
        sender.send(
          HybridRequest(
            requestId: 'r',
            mode: HybridMode.onlyInCloud,
            task: _task('coach_lite', const [HybridText('x')]),
          ),
        ),
        throwsA(isA<HybridException>()),
      );
      await sender.cancel('r');
    });

    test('the runtime is recognised as practice mode; a real one is not', () {
      final practice = runtime();
      expect(isPracticeRuntime(practice), isTrue);
      expect(isPracticeRuntime(null), isFalse);
      expect(
        isPracticeRuntime(
          HybridRuntime.create(
            inference: FakeHybridInference(),
            cloudFallback: const NoCloudInPracticeMode(),
          ),
        ),
        isFalse,
      );
      expect(practice.cloudRoutes.approved, isEmpty);
      expect(practice.isOnline(), isTrue);
    });

    test(
      'a cancelled operation stays cancellable through the wrapper',
      () async {
        final inference = RehearsalHybridInference(
          answerDelay: const Duration(milliseconds: 50),
        );
        final hybrid = RehearsalHybridRuntime.create(inference: inference);
        final op = hybrid.dispatcher.start(
          _task(kLocalWatchFeature, const [HybridText('x')]),
          sessionId: hybrid.sessionId,
        );
        op.cancel();
        final result = await op.result;
        expect(result.ok, isFalse);
      },
    );
  });

  group('practice camera', () {
    test('frames flow only during a camera-only capture', () {
      fakeAsync((async) {
        final media = RehearsalLiveMedia(
          interval: const Duration(milliseconds: 5),
          now: () => DateTime(2026),
        );
        final frames = <CapturedFrame>[];
        final sub = media.timedFrames.listen(frames.add);
        async.elapse(const Duration(milliseconds: 20));
        expect(frames, isEmpty);
        media.startCameraOnly();
        async.flushMicrotasks();
        expect(media.capturing, isTrue);
        async.elapse(const Duration(milliseconds: 12));
        expect(frames, hasLength(2));
        expect(frames[0].bytes, isNot(equals(frames[1].bytes)));
        media.stop();
        async.flushMicrotasks();
        expect(media.capturing, isFalse);
        async.elapse(const Duration(milliseconds: 20));
        expect(frames, hasLength(2));
        sub.cancel();
      });
    });

    test('the frame is a valid PNG the engine can decode', () async {
      final png = practiceCameraFrame(0, width: 32, height: 24);
      expect(png.sublist(0, 8), [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 32);
      expect(frame.image.height, 24);
    });

    test('large images span several stored deflate blocks', () async {
      final rgb = Uint8List(200 * 120 * 3)..fillRange(0, 200 * 120 * 3, 128);
      final png = encodePng(200, 120, rgb);
      final codec = await ui.instantiateImageCodec(png);
      expect((await codec.getNextFrame()).image.width, 200);
    });
  });
}
