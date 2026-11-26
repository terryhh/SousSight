// End-to-end wiring for "Cook in your language" (SS-106) on the cooking
// screen: the real coordinator wiring (Coach Lite through the language-aware
// dispatcher, the per-feature language tag), the Live instruction, and the
// labelled practice translations in rehearsal. Fakes only: no model,
// network, camera or device.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/practice_translation.dart';
import 'package:soussight/translate/recipe_language_view.dart';
import 'package:soussight/translate/recipe_translator.dart';
import 'package:soussight/translate/translation_runtime.dart';
import 'package:soussight/trust/privacy_preferences.dart';
import 'package:soussight/trust/trust_labels.dart';

import 'translate_fixtures.dart';

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) async =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

class _RecordingTransport extends DemoLiveTransport {
  final instructions = <String>[];
  @override
  Future<void> connect({required String systemInstruction}) {
    instructions.add(systemInstruction);
    return super.connect(systemInstruction: systemInstruction);
  }
}

/// Answers translation requests from the practice table; Coach Lite gets a
/// plain valid answer.
Object _answer(HybridRequest r) => HybridResult(
  requestId: '',
  text: r.task.feature == recipeTranslateFeature
      ? answerFor(r.task, (_, text) => practiceSpanish[text])
      : jsonEncode({
          'components': [
            {
              'id': 'root',
              'component': 'CookingColumn',
              'children': ['tip'],
            },
            {
              'id': 'tip',
              'component': 'stepCue',
              'title': 'Consejo',
              'body': 'Unta una capa delgada.',
            },
          ],
        }),
  source: InferenceSource.onDevice,
);

void main() {
  Future<void> setSize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> chooseSpanish(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('cook-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-es')));
    await tester.pumpAndSettle();
  }

  String line(WidgetTester tester, String id) =>
      tester.widget<Text>(find.byKey(ValueKey('line-$id'))).data!;

  testWidgets(
    'real wiring: Español translates the steps and Coach Lite gets the '
    'language instruction',
    (tester) async {
      await setSize(tester);
      final services = (await tester.runAsync(fakeServices))!;
      final inference = FakeHybridInference();
      for (var i = 0; i < 6; i++) {
        inference.script.add(_answer);
      }
      final hybrid = HybridRuntime.create(
        inference: inference,
        cloudRoutes: CloudRoutes.parse(''),
        cloudFallback: _NoCloud(),
        isOnline: () => true,
        cloudModel: 'test-cloud-model',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: CookingScreen(
            services: services,
            isDemo: false,
            hybrid: hybrid,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await chooseSpanish(tester);
      expect(
        line(tester, RecipeLineIds.stepTitle('spread')),
        practiceSpanish['Spread the peanut butter'],
      );
      // "...a butter knife..." is a knife-safety line: kept in English.
      expect(
        find.byKey(ValueKey('kept-${RecipeLineIds.stepInstruction('spread')}')),
        findsOneWidget,
      );
      expect(find.text('Translated on this device.'), findsOneWidget);
      expect(find.text('kept in English'), findsNothing);
      Navigator.of(tester.element(find.text('AI translation'))).pop();
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('cooking-message-input')),
        'How thick should it be?',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final coach = inference.requests.last;
      expect(coach.task.feature, 'coach_lite');
      expect(
        coach.task.systemInstruction,
        endsWith(answerLanguageDirective(spanish)),
      );
      expect(find.textContaining('Unta una capa delgada.'), findsWidgets);

      // Both requests carried their own language; nothing else changed.
      expect(coach.task.outputLanguages, ['en', 'es']);
      expect(inference.requests.first.task.outputLanguages, ['en', 'es']);
    },
  );

  test('Spanish on a device without Spanish keeps Coach Lite honest', () async {
    final inference = FakeHybridInference(capabilities: fakeIosCapabilities);
    final hybrid = HybridRuntime.create(
      inference: inference,
      cloudRoutes: CloudRoutes.parse(''),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    final controller = translationFor(hybrid);
    await controller.select(
      spanish,
      recipe: testRecipe(),
      sessionId: hybrid.sessionId,
    );
    // Not validated on this device and the cloud route is off: blocked,
    // nothing sent.
    expect(controller.translation?.blocked, RouteReason.cloudNotApproved);
    final result = await languageAwareDispatcherFor(hybrid)
        .start(
          const HybridTask(
            feature: 'coach_lite',
            parts: [HybridText('q')],
            maxOutputTokens: 10,
            timeout: Duration(seconds: 5),
          ),
          sessionId: 's',
        )
        .result;
    expect(result.blocked, RouteReason.cloudNotApproved);
    expect(inference.requests, isEmpty);
  });

  test("Live connects with the cook's language", () async {
    final services = await fakeServices();
    final transport = _RecordingTransport();
    final cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: () => transport,
      media: DemoLiveMedia(),
      isDemo: true,
      cookLanguage: () => spanish,
    );
    await cook.initialize();
    await cook.connect();
    expect(transport.instructions.single, contains(spanish.modelName));
    expect(
      transport.instructions.single,
      contains(answerLanguageDirective(spanish)),
    );
    await cook.live.stop();
    cook.dispose();
  });

  testWidgets('rehearsal: canned Spanish, labelled practice, never on-device', (
    tester,
  ) async {
    await setSize(tester);
    final services = (await tester.runAsync(fakeServices))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(services: services, isDemo: true),
      ),
    );
    await tester.pumpAndSettle();
    await chooseSpanish(tester);
    expect(
      line(tester, RecipeLineIds.title),
      'Sándwich de mantequilla de maní (peanut butter)',
    );
    expect(
      find.text('Practice mode: a pretend translation, not a real model.'),
      findsOneWidget,
    );
    expect(find.text('Translated on this device.'), findsNothing);
    expect(find.text('Simulated'), findsOneWidget);
    expect(find.text('kept in English'), findsNothing);
    // Reset the shared practice choice for other tests.
    await tester.tap(find.byKey(const ValueKey('language-en')));
    await tester.pumpAndSettle();
  });

  test('English-only features keep the configured languages', () async {
    // Codex #6 (second round): languages are per request, not global.
    final inference = FakeHybridInference();
    final hybrid = HybridRuntime.create(
      inference: inference,
      cloudRoutes: CloudRoutes.parse(''),
      cloudFallback: _NoCloud(),
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    await hybrid.inference.capabilities();
    await Future<void>.delayed(Duration.zero);
    expect(inference.config?.languages, ['en']);
  });

  test('privacy switch and ledger label exist for recipe_translate', () {
    expect(
      privacyFeatures.map((f) => f.feature),
      contains(recipeTranslateFeature),
    );
    expect(featureLabel(recipeTranslateFeature), 'Recipe translation');
  });

  test('translation origin of practice legs', () async {
    final d = PracticeTranslationDispatcher(delay: Duration.zero);
    final t = await RecipeTranslator(dispatcher: d)
        .translate(testRecipe(), spanish, sessionId: 's');
    expect(
      translationOriginSentence(t.legs),
      'Practice mode: a pretend translation, not a real model.',
    );
  });
}
