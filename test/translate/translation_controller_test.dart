// The cook's language choice and stale-result handling (SS-106). Fakes only.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/recipe_translator.dart';
import 'package:soussight/translate/translation_controller.dart';

import 'translate_fixtures.dart';

/// Hands back translations the test completes by hand.
class _ManualTranslator extends RecipeTranslator {
  _ManualTranslator() : super(dispatcher: FakeHybridDispatcher());
  final calls = <({String recipe, int version, String lang, int budget})>[];
  final pending = <Completer<RecipeTranslation>>[];
  int cancels = 0;
  Object? throwOnTranslate;

  @override
  void cancel() => cancels++;

  @override
  Future<RecipeTranslation> translate(
    recipe,
    language, {
    required String sessionId,
    int maxTotalTokens = translateDefaultMaxTotalTokens,
  }) {
    if (throwOnTranslate case final e?) return Future.error(e);
    calls.add((
      recipe: recipe.id,
      version: recipe.version,
      lang: language.code,
      budget: maxTotalTokens,
    ));
    final c = Completer<RecipeTranslation>();
    pending.add(c);
    return c.future;
  }
}

RecipeTranslation _done(
  int version, {
  TranslationStatus status = TranslationStatus.complete,
}) => RecipeTranslation(
  key: TranslationKey('pb', version, 'es'),
  language: spanish,
  status: status,
  lines: const {
    'recipe.title': TranslatedLine(
      id: 'recipe.title',
      original: 'Peanut Butter Toast',
      translated: 'Pan tostado',
    ),
  },
);

void main() {
  late _ManualTranslator translator;
  late TranslationController controller;
  var notifications = 0;

  setUp(() {
    translator = _ManualTranslator();
    controller = TranslationController(
      translator: translator,
      localTokenBudget: () async => 9216,
    );
    notifications = 0;
    controller.addListener(() => notifications++);
  });

  tearDown(() {
    try {
      controller.dispose();
    } catch (_) {}
  });

  test('starts in English with nothing to show', () {
    expect(controller.language, sourceLanguage);
    expect(controller.busy, isFalse);
    expect(controller.shownFor(testRecipe()), isNull);
    expect(controller.text(testRecipe(), 'recipe.title', 'Orig'), 'Orig');
  });

  test('select Spanish: busy, then the translation is shown', () async {
    final run = controller.select(
      spanish,
      recipe: testRecipe(),
      sessionId: 's1',
    );
    expect(controller.busy, isTrue);
    expect(controller.language, spanish);
    await Future<void>.delayed(Duration.zero);
    expect(translator.calls.single.budget, 9216);
    translator.pending.single.complete(_done(1));
    await run;
    expect(controller.busy, isFalse);
    expect(controller.text(testRecipe(), 'recipe.title', 'x'), 'Pan tostado');
    expect(controller.shownFor(testRecipe(version: 2)), isNull);
    expect(notifications, greaterThanOrEqualTo(2));
  });

  test('Show original hides the translation without discarding it', () async {
    final run = controller.select(
      spanish,
      recipe: testRecipe(),
      sessionId: 's',
    );
    await Future<void>.delayed(Duration.zero);
    translator.pending.single.complete(_done(1));
    await run;
    controller.showOriginal = true;
    expect(controller.text(testRecipe(), 'recipe.title', 'x'), 'x');
    controller.showOriginal = true; // no change, no extra notification
    controller.showOriginal = false;
    expect(controller.text(testRecipe(), 'recipe.title', 'x'), 'Pan tostado');
  });

  test('a stale result is dropped when the cook switches back', () async {
    final run = controller.select(
      spanish,
      recipe: testRecipe(),
      sessionId: 's',
    );
    await Future<void>.delayed(Duration.zero);
    await controller.select(
      sourceLanguage,
      recipe: testRecipe(),
      sessionId: 's',
    );
    translator.pending.single.complete(_done(1));
    await run;
    expect(controller.language, sourceLanguage);
    expect(controller.translation, isNull);
    expect(controller.busy, isFalse);
    expect(translator.cancels, greaterThanOrEqualTo(2));
  });

  test('stale while the budget is still loading', () async {
    final budget = Completer<int?>();
    final c = TranslationController(
      translator: translator,
      localTokenBudget: () => budget.future,
    );
    final run = c.select(spanish, recipe: testRecipe(), sessionId: 's');
    c.cancel();
    expect(c.busy, isFalse);
    budget.complete(4000);
    await run;
    expect(translator.calls, isEmpty);
    c.dispose();
  });

  test('a budget error falls back to the default budget', () async {
    final c = TranslationController(
      translator: translator,
      localTokenBudget: () => Future.error(StateError('no bridge')),
    );
    final run = c.select(spanish, recipe: testRecipe(), sessionId: 's');
    await Future<void>.delayed(Duration.zero);
    expect(translator.calls.single.budget, translateDefaultMaxTotalTokens);
    translator.pending.single.complete(_done(1));
    await run;
    c.dispose();
  });

  test('cancelled results are never shown', () async {
    final run = controller.select(
      spanish,
      recipe: testRecipe(),
      sessionId: 's',
    );
    await Future<void>.delayed(Duration.zero);
    translator.pending.single.complete(
      _done(1, status: TranslationStatus.cancelled),
    );
    await run;
    expect(controller.translation, isNull);
  });

  test('blocked results are kept for the notice but not shown', () async {
    final run = controller.select(
      spanish,
      recipe: testRecipe(),
      sessionId: 's',
    );
    await Future<void>.delayed(Duration.zero);
    translator.pending.single.complete(
      _done(1, status: TranslationStatus.blocked),
    );
    await run;
    expect(controller.translation?.status, TranslationStatus.blocked);
    expect(controller.shownFor(testRecipe()), isNull);
  });

  test('a translator error ends busy without a translation', () async {
    translator.throwOnTranslate = StateError('boom');
    await controller.select(spanish, recipe: testRecipe(), sessionId: 's');
    expect(controller.busy, isFalse);
    expect(controller.translation, isNull);
  });

  test('a translator error after a newer request is ignored', () async {
    final failing = Completer<RecipeTranslation>();
    final t = _ManualTranslator();
    final c = TranslationController(translator: t);
    final run = c.select(spanish, recipe: testRecipe(), sessionId: 's');
    await Future<void>.delayed(Duration.zero);
    t.pending.single.complete(failing.future);
    c.cancel();
    failing.completeError(StateError('late'));
    await run;
    expect(c.busy, isFalse);
    c.dispose();
  });

  test('recipeChanged re-translates only when the recipe moved on', () async {
    await controller.recipeChanged(testRecipe(), sessionId: 's');
    expect(translator.calls, isEmpty); // English: nothing to do

    final run = controller.select(
      spanish,
      recipe: testRecipe(),
      sessionId: 's',
    );
    await Future<void>.delayed(Duration.zero);
    translator.pending.single.complete(_done(1));
    await run;
    await controller.recipeChanged(testRecipe(), sessionId: 's');
    expect(translator.calls, hasLength(1));

    final next = controller.recipeChanged(
      testRecipe(version: 2),
      sessionId: 's',
    );
    await Future<void>.delayed(Duration.zero);
    expect(translator.calls.last.version, 2);
    translator.pending.last.complete(_done(2));
    await next;
    expect(controller.shownFor(testRecipe(version: 2)), isNotNull);
  });

  test('dispose stops the run and later selects do nothing', () async {
    final c = TranslationController(translator: translator);
    final run = c.select(spanish, recipe: testRecipe(), sessionId: 's');
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    translator.pending.single.complete(_done(1));
    await run;
    expect(c.translation, isNull);
    await c.select(spanish, recipe: testRecipe(), sessionId: 's');
    expect(translator.calls, hasLength(1));
  });

  test('cancel when idle does not notify', () {
    controller.cancel();
    expect(notifications, 0);
  });
}
