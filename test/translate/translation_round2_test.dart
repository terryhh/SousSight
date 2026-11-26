// Second Codex round on SS-106 translation: session binding at the runtime,
// connectivity at the final forward, in-flight reuse and retry, answering
// legs, and the sheet's retry and optional marks. Fakes only.


import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/recipe_language_view.dart';
import 'package:soussight/translate/recipe_translator.dart';
import 'package:soussight/translate/translation_controller.dart';
import 'package:soussight/translate/translation_runtime.dart';

import 'translate_fixtures.dart';

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) async =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

InferenceLeg _leg(Provenance p, {bool transfer = true, String id = 'r'}) =>
    InferenceLeg(
      requestId: id,
      feature: recipeTranslateFeature,
      mode: HybridMode.preferOnDevice,
      kinds: const {DataKind.text},
      transferPermitted: transfer,
      provenance: p,
    );

void main() {
  test('binding a new cooking session cancels a running translation', () async {
    // Codex #3: nothing from cook A may be sent into cook B's ledger.
    final inference = FakeHybridInference()
      ..delay = const Duration(milliseconds: 20);
    inference.script.add(
      (HybridRequest r) => HybridResult(
        requestId: '',
        text: 'not json',
        source: InferenceSource.onDevice,
      ),
    );
    final hybrid = HybridRuntime.create(
      inference: inference,
      cloudRoutes: CloudRoutes.parse('hybridFallback'),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    hybrid.bindCookingSession('cook-a');
    final controller = translationFor(hybrid);
    final run = controller.select(
      spanish,
      recipe: testRecipe(),
      sessionId: 'cook-a',
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(inference.requests, hasLength(1));
    hybrid.bindCookingSession('cook-b');
    expect(controller.busy, isFalse);
    await run;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // The malformed answer would have earned a cloud retry; it never went.
    expect(inference.requests, hasLength(1));
    expect(
      hybrid.ledger.legs.where((l) => l.mode == HybridMode.onlyInCloud),
      isEmpty,
    );
  });

  test(
    'the production wrapper re-reads connectivity before forwarding',
    () async {
      // Codex #4: offline between the dispatcher's check and the forward.
      var online = true;
      final inference = FakeHybridInference();
      final hybrid = HybridRuntime.create(
        inference: inference,
        cloudRoutes: CloudRoutes.parse('hybridFallback'),
        cloudFallback: _NoCloud(),
        isOnline: () => online,
        cloudModel: 'test-cloud-model',
      );
      online = false;
      await expectLater(
        hybrid.inference.generate(
          HybridRequest(
            requestId: 'x',
            mode: HybridMode.preferOnDevice,
            task: translationTask(
              recipeSourceLines(testRecipe()).take(1).toList(),
              spanish,
              const [],
            ),
          ),
        ),
        throwsA(isA<HybridException>()),
      );
      expect(inference.requests, isEmpty);
    },
  );

  group('controller', () {
    test('reopening reuses the running translation', () async {
      final d = FakeHybridDispatcher()
        ..delay = const Duration(milliseconds: 10);
      d.script.add((task) => okResult(task, answerFor(task)));
      final c = TranslationController(
        translator: RecipeTranslator(dispatcher: d),
      );
      final run = c.select(spanish, recipe: testRecipe(), sessionId: 's');
      await c.recipeChanged(testRecipe(), sessionId: 's');
      expect(d.cancelledOperations, isEmpty);
      await run;
      expect(d.tasks, hasLength(1));
      // Complete: reopening does not resend.
      await c.recipeChanged(testRecipe(), sessionId: 's');
      expect(d.tasks, hasLength(1));
    });

    test('a blocked result is retried when the sheet reopens', () async {
      final d = FakeHybridDispatcher()..enqueueBlocked(RouteReason.offline);
      d.script.add((task) => okResult(task, answerFor(task)));
      final c = TranslationController(
        translator: RecipeTranslator(dispatcher: d),
      );
      await c.select(spanish, recipe: testRecipe(), sessionId: 's');
      expect(c.translation?.status, TranslationStatus.blocked);
      await c.recipeChanged(testRecipe(), sessionId: 's');
      expect(c.translation?.status, TranslationStatus.complete);
      expect(d.tasks, hasLength(2));
    });
  });

  group('origin wording', () {
    test('displayed text and other transfers are described separately', () {
      // Codex #9: local chunk shown, a malformed cloud retry not shown.
      expect(
        translationOriginSentence(
          [_leg(Provenance.sdkOnDevice)],
          otherLegs: [_leg(Provenance.sdkCloud, id: 'c')],
        ),
        'Translated on this device. Other recipe text was also sent to the '
        'cloud.',
      );
      expect(
        translationOriginSentence(
          [_leg(Provenance.sdkOnDevice)],
          otherLegs: [_leg(Provenance.unknown, id: 'u')],
        ),
        'Translated on this device. Other recipe text may also have been '
        'sent to the cloud.',
      );
      expect(
        translationOriginSentence(
          [_leg(Provenance.sdkCloud)],
          otherLegs: [_leg(Provenance.sdkCloud, id: 'c')],
        ),
        'Some or all of this was translated in the cloud.',
      );
    });
  });

  group('sheet', () {
    Future<void> pump(
      WidgetTester tester,
      TranslationController c,
      Recipe r,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecipeLanguageView(
              controller: c,
              recipe: r,
              sessionId: () => 's',
            ),
          ),
        ),
      );
    }

    testWidgets('optional ingredients are marked in both views', (
      tester,
    ) async {
      final r = Recipe(
        id: 'jam',
        version: 1,
        title: 'Toast',
        summary: '',
        ingredients: const [
          Ingredient(id: 'jam', name: 'Jam', qty: '1 tbsp', optional: true),
        ],
        equipment: const [],
        steps: testRecipe().steps,
        checkpoints: const [],
        reviewedSubstitutions: const [],
        adjustmentLabels: const {},
      );
      final d = FakeHybridDispatcher();
      d.script.add((task) => okResult(task, answerFor(task)));
      final c = TranslationController(
        translator: RecipeTranslator(dispatcher: d),
      );
      await pump(tester, c, r);
      expect(find.byKey(const ValueKey('optional-jam')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('language-es')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('optional-jam')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('show-original')));
      await tester.pump();
      expect(find.byKey(const ValueKey('optional-jam')), findsOneWidget);
    });

    testWidgets('Try again retries a blocked translation', (tester) async {
      final d = FakeHybridDispatcher()..enqueueBlocked(RouteReason.offline);
      d.script.add((task) => okResult(task, answerFor(task)));
      final c = TranslationController(
        translator: RecipeTranslator(dispatcher: d),
      );
      await pump(tester, c, testRecipe());
      await tester.tap(find.byKey(const ValueKey('language-es')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('translation-blocked')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('translation-retry')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('translation-blocked')), findsNothing);
      expect(find.text('AI translation'), findsOneWidget);
      expect(find.byKey(const ValueKey('translation-retry')), findsNothing);
    });
  });
}
