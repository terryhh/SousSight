// Recipe translation through a scripted dispatcher (SS-106). Fakes only: no
// model, network or device is used.

import 'dart:async';
import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_policy.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/recipe_translator.dart';
import 'package:soussight/translate/translation_guard.dart';

import 'translate_fixtures.dart';

/// A dispatcher whose answers the test releases by hand.
class _GatedDispatcher implements HybridDispatcher {
  final starts = <HybridTask>[];
  final cancelled = <int>[];
  final pending = <Completer<DispatchResult>>[];

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    starts.add(task);
    final c = Completer<DispatchResult>();
    pending.add(c);
    final index = pending.length - 1;
    return HybridOperation('g$index', c.future, () => cancelled.add(index));
  }
}

class _ThrowingDispatcher implements HybridDispatcher {
  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) => throw StateError('boom');
}

void main() {
  group('source lines', () {
    test('every non-empty line, in reading order, with stable ids', () {
      final lines = recipeSourceLines(testRecipe());
      expect(
        [for (final l in lines) l.id],
        [
          RecipeLineIds.title,
          RecipeLineIds.summary,
          RecipeLineIds.ingredientName('bread'),
          RecipeLineIds.ingredientQty('bread'),
          RecipeLineIds.ingredientName('pb'),
          RecipeLineIds.ingredientQty('pb'),
          RecipeLineIds.ingredientName('salt'),
          RecipeLineIds.stepTitle('toast'),
          RecipeLineIds.stepInstruction('toast'),
          RecipeLineIds.stepCue('toast'),
          RecipeLineIds.stepTitle('spread'),
          RecipeLineIds.stepInstruction('spread'),
        ],
      );
      expect(lines[2].kind, RecipeLineKind.ingredientName);
      expect(lines[2].allergenName, 'Bread');
      expect(lines[6].allergenName, isNull);
      expect(allergenIngredientNames(testRecipe()), ['Bread', 'Peanut butter']);
    });
  });

  group('chunking', () {
    final recipe = testRecipe(extraSteps: 40);
    final lines = recipeSourceLines(recipe);
    final allergens = allergenIngredientNames(recipe);

    List<List<SourceLine>> chunks(int budget) => chunkSourceLines(
      lines,
      language: spanish,
      allergenNames: allergens,
      maxTotalTokens: budget,
    );

    test('every chunk fits the Android (4k) budget and keeps line order', () {
      final out = chunks(4000);
      expect(out.length, greaterThan(1));
      for (final c in out) {
        expect(chunkTokens(c, spanish, allergens), lessThanOrEqualTo(3800));
        expect(c.length, lessThanOrEqualTo(24));
        expect(outputTokensFor(c), lessThanOrEqualTo(translateMaxOutputTokens));
      }
      expect([for (final c in out) ...c].map((l) => l.id), [
        for (final l in lines) l.id,
      ]);
    });

    test('Chrome (9k) needs no more chunks than Android', () {
      expect(chunks(9216).length, lessThanOrEqualTo(chunks(4000).length));
    });

    test('a single line too long for the budget goes alone', () {
      final long = SourceLine(
        id: 'long',
        kind: RecipeLineKind.stepInstruction,
        text: 'Stir. ' * 2000,
      );
      final out = chunkSourceLines(
        [lines.first, long, lines.last],
        language: spanish,
        allergenNames: allergens,
        maxTotalTokens: 4000,
      );
      expect(out.map((c) => c.map((l) => l.id).toList()), [
        [lines.first.id],
        ['long'],
        [lines.last.id],
      ]);
    });

    test('the task carries the feature, schema and a bounded output', () {
      final task = translationTask(lines.take(3).toList(), spanish, allergens);
      expect(task.feature, recipeTranslateFeature);
      expect(task.jsonSchema, translationResponseSchema);
      expect(task.maxOutputTokens, lessThanOrEqualTo(translateMaxOutputTokens));
      expect(task.systemInstruction, contains(spanish.modelName));
      expect(task.systemInstruction, contains('°F or °C'));
      final prompt = (task.parts.single as HybridText).text;
      expect(prompt, contains(jsonEncode(allergens)));
      expect(taskLines(task).length, 3);
      // The dispatcher's §4 estimate agrees with ours.
      expect(
        estimateLocalTokens(task, imageTokenEstimate: 0),
        chunkTokens(lines.take(3).toList(), spanish, allergens),
      );
    });
  });

  group('parseTranslationResponse', () {
    const ids = {'a', 'b'};

    test('accepts the agreed shape, fenced or not', () {
      expect(
        parseTranslationResponse(
          '{"lines":[{"id":"a","text":"uno"},{"id":"b","text":"dos"}]}',
          ids,
        ),
        {'a': 'uno', 'b': 'dos'},
      );
      expect(
        parseTranslationResponse(
          '```json\n{"lines":[{"id":"a","text":"uno"}]}\n```',
          ids,
        ),
        {'a': 'uno'},
      );
    });

    test('ignores unknown ids and drops an id given twice', () {
      expect(
        parseTranslationResponse(
          '{"lines":[{"id":"a","text":"uno"},{"id":"a","text":"otro"},'
          '{"id":"zzz","text":"x"},{"id":"b","text":"dos"}]}',
          ids,
        ),
        {'b': 'dos'},
      );
    });

    test('rejects anything else', () {
      for (final bad in [
        'not json',
        '[]',
        '{"lines":[], "extra":1}',
        '{"lines":"a"}',
        '{"lines":[1]}',
        '{"lines":[{"id":"a"}]}',
        '{"lines":[{"id":1,"text":"x"}]}',
        '{"lines":[{"id":"a","text":2}]}',
        'x' * 64001,
      ]) {
        expect(
          () => parseTranslationResponse(bad, ids),
          throwsFormatException,
          reason: bad.length > 40 ? 'long' : bad,
        );
        expect(translationValidator(ids)(bad), isNotNull);
      }
      // Every expected line must come back (Codex #10).
      expect(translationValidator(ids)('{"lines":[]}'), isNotNull);
      expect(
        translationValidator(ids)(
          '{"lines":[{"id":"a","text":"uno"},{"id":"b","text":"dos"}]}',
        ),
        isNull,
      );
    });
  });

  group('RecipeTranslator', () {
    late FakeHybridDispatcher dispatcher;
    late RecipeTranslator translator;

    setUp(() {
      dispatcher = FakeHybridDispatcher();
      translator = RecipeTranslator(dispatcher: dispatcher);
    });

    test('English is the source: nothing is sent', () async {
      final t = await translator.translate(
        testRecipe(),
        sourceLanguage,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.source);
      expect(dispatcher.tasks, isEmpty);
      expect(t.text('recipe.title', 'Original'), 'Original');
    });

    test('translates, checks every line and keeps the legs', () async {
      dispatcher.script.add(
        (task) => okResult(task, answerFor(task, (id, _) => spanishFor[id])),
      );
      final t = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      // Salt was left out of the answer: the chunk is not fully answered,
      // so the result is partial and never cached (Codex #10).
      expect(t.status, TranslationStatus.partial);
      expect(translator.cache.length, 0);
      expect(t.key, const TranslationKey('pb', 1, 'es'));
      expect(t.keptCount, 1);
      expect(
        t.lines[RecipeLineIds.ingredientName('salt')]!.rejection,
        LineRejection.noTranslation,
      );
      expect(
        t.text(RecipeLineIds.stepInstruction('toast'), 'x'),
        'Tuesta el pan (bread) a 350°F por 5 minutos.',
      );
      // The app adds the English name to an allergen ingredient's name.
      expect(
        t.text(RecipeLineIds.ingredientName('pb'), 'x'),
        'Mantequilla de maní (Peanut butter)',
      );
      expect(t.text(RecipeLineIds.ingredientName('bread'), 'x'), 'Pan (Bread)');
      expect(t.legs.single.provenance, Provenance.sdkOnDevice);
      expect(dispatcher.tasks.single.feature, recipeTranslateFeature);
    });

    test('a changed number keeps that line in English', () async {
      dispatcher.script.add(
        (task) => okResult(
          task,
          answerFor(
            task,
            (id, text) => id == RecipeLineIds.stepInstruction('toast')
                ? 'Tuesta el pan (bread) a 180 °C por 5 minutos.'
                : spanishFor[id],
          ),
        ),
      );
      final t = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      final id = RecipeLineIds.stepInstruction('toast');
      expect(t.isKept(id), isTrue);
      expect(t.lines[id]!.rejection, LineRejection.numbersChanged);
      expect(t.text(id, 'orig'), 'orig');
      expect(t.lines[id]!.text, 'Toast the bread at 350°F for 5 minutes.');
      expect(t.isKept(RecipeLineIds.stepTitle('toast')), isFalse);
    });

    test('malformed output abstains: the whole chunk stays English', () async {
      dispatcher.enqueue('{"lines": "oops"}');
      final t = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.partial);
      expect(t.translatedCount, 0);
      expect(
        t.lines.values.every((l) => l.rejection == LineRejection.noTranslation),
        isTrue,
      );
      expect(t.legs, hasLength(1));
      // Not cached: the next request asks again.
      dispatcher.script.add((task) => okResult(task, answerFor(task)));
      final again = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(again.status, TranslationStatus.complete);
      expect(dispatcher.tasks, hasLength(2));
    });

    test('a blocked chunk stops every later send', () async {
      final recipe = testRecipe(extraSteps: 40);
      dispatcher.script
        ..add((task) => okResult(task, answerFor(task)))
        ..add(
          (_) => const DispatchResult(
            legs: [],
            blocked: RouteReason.localOnlySetting,
          ),
        )
        ..add((task) => okResult(task, answerFor(task)));
      final t = await translator.translate(
        recipe,
        spanish,
        sessionId: 's1',
        maxTotalTokens: 4000,
      );
      expect(dispatcher.tasks, hasLength(2));
      expect(t.status, TranslationStatus.partial);
      expect(t.blocked, RouteReason.localOnlySetting);
      expect(t.translatedCount, greaterThan(0));
      expect(translator.cache.length, 0);
    });

    test('blocked on the first chunk means nothing is translated', () async {
      dispatcher.enqueueBlocked(RouteReason.offline);
      final t = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.blocked);
      expect(t.blocked, RouteReason.offline);
      expect(t.translatedCount, 0);
    });

    test('a failed chunk does not stop the next one', () async {
      final recipe = testRecipe(extraSteps: 40);
      dispatcher.script
        ..add((_) => const DispatchResult(legs: []))
        ..add((task) => okResult(task, answerFor(task)));
      for (var i = 0; i < 10; i++) {
        dispatcher.script.add((task) => okResult(task, answerFor(task)));
      }
      final t = await translator.translate(
        recipe,
        spanish,
        sessionId: 's1',
        maxTotalTokens: 4000,
      );
      expect(dispatcher.tasks.length, greaterThan(2));
      expect(t.status, TranslationStatus.partial);
      expect(t.isKept(RecipeLineIds.title), isTrue);
      expect(t.translatedCount, greaterThan(0));
    });

    test('a dispatcher that throws is a failed chunk', () async {
      final t = await RecipeTranslator(dispatcher: _ThrowingDispatcher())
          .translate(testRecipe(), spanish, sessionId: 's1');
      expect(t.status, TranslationStatus.partial);
      expect(t.translatedCount, 0);
    });

    test('cache: keyed by recipe id, version and language', () async {
      for (var i = 0; i < 3; i++) {
        dispatcher.script.add((task) => okResult(task, answerFor(task)));
      }
      final first = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      final again = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's2',
      );
      expect(identical(first, again), isTrue);
      expect(dispatcher.tasks, hasLength(1));
      await translator.translate(
        testRecipe(version: 2),
        spanish,
        sessionId: 's1',
      );
      await translator.translate(
        testRecipe(id: 'other'),
        spanish,
        sessionId: 's1',
      );
      expect(dispatcher.tasks, hasLength(3));
    });

    test('cancel: a running translation comes back cancelled', () async {
      final gated = _GatedDispatcher();
      final t = RecipeTranslator(dispatcher: gated);
      final running = t.translate(testRecipe(), spanish, sessionId: 's1');
      await Future<void>.delayed(Duration.zero);
      t.cancel();
      expect(gated.cancelled, [0]);
      gated.pending.single.complete(
        okResult(gated.starts.single, answerFor(gated.starts.single)),
      );
      final result = await running;
      expect(result.status, TranslationStatus.cancelled);
      expect(t.cache.length, 0);
    });

    test('a newer translation replaces a running one', () async {
      final gated = _GatedDispatcher();
      final t = RecipeTranslator(dispatcher: gated);
      final older = t.translate(testRecipe(), spanish, sessionId: 's1');
      await Future<void>.delayed(Duration.zero);
      final newer = t.translate(
        testRecipe(version: 2),
        spanish,
        sessionId: 's1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(gated.cancelled, [0]);
      for (final (i, c) in gated.pending.indexed) {
        c.complete(okResult(gated.starts[i], answerFor(gated.starts[i])));
      }
      expect((await older).status, TranslationStatus.cancelled);
      final done = await newer;
      expect(done.status, TranslationStatus.complete);
      expect(done.key.version, 2);
    });

    test('an answer missing lines is partial and never cached', () async {
      dispatcher.enqueue('{"lines":[]}');
      final t = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.partial);
      expect(t.translatedCount, 0);
      expect(translator.cache.length, 0);
    });

    test(
      'a newer call answered from the cache still stops the older one',
      () async {
        final gated = _GatedDispatcher();
        final t = RecipeTranslator(dispatcher: gated);
        final key = TranslationKey.of(testRecipe(version: 2), spanish);
        t.cache[key] = RecipeTranslation(
          key: key,
          language: spanish,
          status: TranslationStatus.complete,
        );
        final older = t.translate(testRecipe(), spanish, sessionId: 's1');
        await Future<void>.delayed(Duration.zero);
        final hit = await t.translate(
          testRecipe(version: 2),
          spanish,
          sessionId: 's1',
        );
        expect(hit.key, key);
        expect(gated.cancelled, [0]);
        gated.pending.single.complete(
          okResult(gated.starts.single, answerFor(gated.starts.single)),
        );
        expect((await older).status, TranslationStatus.cancelled);

        // An English selection does too.
        final again = t.translate(testRecipe(), spanish, sessionId: 's1');
        await Future<void>.delayed(Duration.zero);
        await t.translate(testRecipe(), sourceLanguage, sessionId: 's1');
        expect(gated.cancelled, [0, 1]);
        gated.pending.last.complete(
          okResult(gated.starts.last, answerFor(gated.starts.last)),
        );
        expect((await again).status, TranslationStatus.cancelled);
      },
    );

    test('a new cooking session stops the remaining chunks', () async {
      var session = 's1';
      final gated = _GatedDispatcher();
      final t = RecipeTranslator(
        dispatcher: gated,
        sessionIsCurrent: (id) => id == session,
      );
      final run = t.translate(
        testRecipe(extraSteps: 40),
        spanish,
        sessionId: 's1',
        maxTotalTokens: 4000,
      );
      await Future<void>.delayed(Duration.zero);
      expect(gated.starts, hasLength(1));
      session = 's2'; // New cook.
      gated.pending.single.complete(
        okResult(gated.starts.single, answerFor(gated.starts.single)),
      );
      final result = await run;
      expect(result.status, TranslationStatus.cancelled);
      expect(gated.starts, hasLength(1), reason: 'no chunk sent into s2');
      expect(t.cache.length, 0);
    });

    test(
      'a session that changed before the first send sends nothing',
      () async {
        final t = RecipeTranslator(
          dispatcher: dispatcher,
          sessionIsCurrent: (_) => false,
        );
        final result = await t.translate(
          testRecipe(),
          spanish,
          sessionId: 'old',
        );
        expect(result.status, TranslationStatus.cancelled);
        expect(dispatcher.tasks, isEmpty);
      },
    );

    test('a cancelled operation result stops the run', () async {
      dispatcher.enqueueBlocked(RouteReason.cancelled);
      final t = await translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.cancelled);
    });
  });

  test('TranslationCache evicts the least recently used', () {
    final cache = TranslationCache(capacity: 2);
    RecipeTranslation t(String id) => RecipeTranslation(
      key: TranslationKey(id, 1, 'es'),
      language: spanish,
      status: TranslationStatus.complete,
    );
    cache[const TranslationKey('a', 1, 'es')] = t('a');
    cache[const TranslationKey('b', 1, 'es')] = t('b');
    expect(cache[const TranslationKey('a', 1, 'es')], isNotNull);
    cache[const TranslationKey('c', 1, 'es')] = t('c');
    expect(cache[const TranslationKey('b', 1, 'es')], isNull);
    expect(cache[const TranslationKey('a', 1, 'es')], isNotNull);
    expect(cache.length, 2);
    cache.clear();
    expect(cache.length, 0);
    expect('${const TranslationKey('a', 2, 'es')}', 'a@2:es');
  });
}
