// "Cook in your language" widgets (SS-106): every sheet state, the header
// button, and wording derived from legs. Fakes only.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/recipe_language_view.dart';
import 'package:soussight/translate/recipe_translator.dart';
import 'package:soussight/translate/translation_controller.dart';

import 'translate_fixtures.dart';

InferenceLeg _leg(Provenance p, {bool transfer = true}) => InferenceLeg(
  requestId: 'r-${p.name}',
  feature: recipeTranslateFeature,
  mode: HybridMode.preferOnDevice,
  kinds: const {DataKind.text},
  transferPermitted: transfer,
  provenance: p,
);

void main() {
  group('translationOriginSentence (claims from legs)', () {
    test('success wording needs an accepted translation and provenance', () {
      expect(
        translationOriginSentence([_leg(Provenance.sdkOnDevice)]),
        'Translated on this device.',
      );
      expect(
        translationOriginSentence([
          _leg(Provenance.sdkOnDevice),
          _leg(Provenance.cloudAdapter),
        ]),
        'Some or all of this was translated in the cloud.',
      );
      expect(
        translationOriginSentence([_leg(Provenance.unknown)]),
        'Some recipe text may have been sent to the cloud.',
      );
      expect(
        translationOriginSentence([
          _leg(Provenance.sdkOnDevice),
          _leg(Provenance.unknown, transfer: false),
        ]),
        'Translated on this device.',
      );
      expect(
        translationOriginSentence([_leg(Provenance.simulated)]),
        'Practice mode: a pretend translation, not a real model.',
      );
      // Codex #11: an unknown leg that did not finish is not "on device",
      // and no legs is not a "saved" translation.
      expect(
        translationOriginSentence([_leg(Provenance.unknown, transfer: false)]),
        "Translated by AI; where it ran isn't known.",
      );
      expect(
        translationOriginSentence(const []),
        "Translated by AI; where it ran isn't known.",
      );
    });

    test('attempt wording when nothing was translated', () {
      expect(
        translationOriginSentence(const [], translated: false),
        'Nothing was translated.',
      );
      expect(
        translationOriginSentence([
          _leg(Provenance.unknown, transfer: false),
        ], translated: false),
        'Nothing was translated, and nothing left this device.',
      );
      expect(
        translationOriginSentence([
          _leg(Provenance.sdkCloud),
        ], translated: false),
        'Nothing was translated. Recipe text was sent to the cloud.',
      );
      expect(
        translationOriginSentence([
          _leg(Provenance.unknown),
        ], translated: false),
        'Nothing was translated. Recipe text may have been sent to the cloud.',
      );
      expect(
        translationOriginSentence([
          _leg(Provenance.simulated),
        ], translated: false),
        'Practice mode: nothing was translated.',
      );
    });
  });

  group('RecipeLanguageView', () {
    late FakeHybridDispatcher dispatcher;
    late TranslationController controller;

    setUp(() {
      dispatcher = FakeHybridDispatcher();
      controller = TranslationController(
        translator: RecipeTranslator(dispatcher: dispatcher),
      );
    });

    Future<void> pump(WidgetTester tester, {String? currentStepId}) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecipeLanguageView(
              controller: controller,
              recipe: testRecipe(),
              sessionId: () => 's1',
              currentStepId: currentStepId,
            ),
          ),
        ),
      );
    }

    String lineText(WidgetTester tester, String id) =>
        tester.widget<Text>(find.byKey(ValueKey('line-$id'))).data!;

    testWidgets('English: the recipe as written, no AI label', (tester) async {
      await pump(tester, currentStepId: 'spread');
      expect(lineText(tester, RecipeLineIds.title), 'Peanut Butter Toast');
      expect(find.byKey(const ValueKey('ai-translation-label')), findsNothing);
      expect(find.byKey(const ValueKey('show-original')), findsNothing);
      expect(find.text('Step 2 · Now'), findsOneWidget);
      expect(find.text(translationSafetyNote), findsNothing);
    });

    testWidgets('busy, then translated with label, badge and kept note', (
      tester,
    ) async {
      dispatcher.delay = const Duration(milliseconds: 10);
      dispatcher.script.add(
        (task) => okResult(
          task,
          answerFor(
            task,
            (id, text) => id == RecipeLineIds.stepInstruction('toast')
                ? 'Tuesta el pan (bread) por 6 minutos.'
                : spanishFor[id] ?? 'Sal',
          ),
        ),
      );
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('language-es')));
      await tester.pump();
      expect(find.byKey(const ValueKey('translation-busy')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(find.byKey(const ValueKey('translation-busy')), findsNothing);
      expect(
        find.byKey(const ValueKey('ai-translation-label')),
        findsOneWidget,
      );
      expect(find.text('AI translation'), findsOneWidget);
      expect(find.text('Translated on this device.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('inference-source-badge')),
        findsOneWidget,
      );
      expect(
        lineText(tester, RecipeLineIds.title),
        spanishFor[RecipeLineIds.title],
      );
      expect(
        lineText(tester, RecipeLineIds.ingredientName('pb')),
        'Mantequilla de maní (Peanut butter)',
      );
      // The changed time keeps the English line, with a note.
      final kept = RecipeLineIds.stepInstruction('toast');
      expect(lineText(tester, kept), 'Toast the bread for 5 minutes.');
      expect(find.byKey(ValueKey('kept-$kept')), findsOneWidget);
      expect(find.text('kept in English'), findsOneWidget);
      // The warning was never sent: kept for safety.
      final warning = RecipeLineIds.stepCue('spread');
      expect(
        lineText(tester, warning),
        'Do not press hard enough to tear the bread.',
      );
      expect(find.text('kept in English for safety'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('translation-kept-count')),
        findsOneWidget,
      );
      expect(find.textContaining('2 lines stay in English'), findsOneWidget);
      expect(find.text(translationSafetyNote), findsOneWidget);

      // Show original: everything English, no kept notes.
      await tester.tap(find.byKey(const ValueKey('show-original')));
      await tester.pump();
      expect(lineText(tester, RecipeLineIds.title), 'Peanut Butter Toast');
      expect(find.text('kept in English'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('show-original')));
      await tester.pump();
      expect(
        lineText(tester, RecipeLineIds.title),
        spanishFor[RecipeLineIds.title],
      );
    });

    testWidgets('Stop cancels a running translation', (tester) async {
      dispatcher.delay = const Duration(milliseconds: 50);
      dispatcher.script.add((task) => okResult(task, answerFor(task)));
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('language-es')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('translation-cancel')));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const ValueKey('translation-busy')), findsNothing);
      expect(find.byKey(const ValueKey('ai-translation-label')), findsNothing);
      expect(lineText(tester, RecipeLineIds.title), 'Peanut Butter Toast');
      expect(dispatcher.cancelledOperations, hasLength(1));
    });

    testWidgets('blocked: says why and shows the recipe as written', (
      tester,
    ) async {
      dispatcher.enqueueBlocked(RouteReason.localOnlySetting);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('language-es')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('translation-blocked')), findsOneWidget);
      expect(
        find.textContaining('Showing the recipe as written.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ai-translation-label')), findsNothing);
      expect(lineText(tester, RecipeLineIds.title), 'Peanut Butter Toast');
    });

    testWidgets('partial: says part stays in English', (tester) async {
      dispatcher.enqueue('not json');
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('language-es')));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('Part of the recipe could not be translated'),
        findsOneWidget,
      );
      expect(find.text('kept in English'), findsWidgets);
    });

    testWidgets('switching back to English hides the translation', (
      tester,
    ) async {
      dispatcher.script.add((task) => okResult(task, answerFor(task)));
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('language-es')));
      await tester.pump();
      await tester.pump();
      expect(find.text('AI translation'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('language-en')));
      await tester.pump();
      expect(find.text('AI translation'), findsNothing);
      expect(lineText(tester, RecipeLineIds.title), 'Peanut Butter Toast');
    });
  });

  testWidgets('header button shows the language and opens the sheet', (
    tester,
  ) async {
    final dispatcher = FakeHybridDispatcher()
      ..script.add((task) => okResult(task, answerFor(task)));
    final controller = TranslationController(
      translator: RecipeTranslator(dispatcher: dispatcher),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CookLanguageButton(
            controller: controller,
            recipe: testRecipe(),
            sessionId: () => 's1',
          ),
        ),
      ),
    );
    expect(find.text('English'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cook-language')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-language-view')), findsOneWidget);
    expect(dispatcher.tasks, isEmpty); // English: nothing sent on open
    await tester.tap(find.byKey(const ValueKey('language-es')));
    await tester.pumpAndSettle();
    expect(find.text('AI translation'), findsOneWidget);
    Navigator.of(tester.element(find.byType(RecipeLanguageView))).pop();
    await tester.pumpAndSettle();
    expect(find.text(spanish.nativeName), findsOneWidget);

    // A newer recipe version under Spanish is translated when reopened;
    // the same version comes from the cache with no new send.
    await tester.tap(find.byKey(const ValueKey('cook-language')));
    await tester.pumpAndSettle();
    expect(dispatcher.tasks, hasLength(1));
  });
}
