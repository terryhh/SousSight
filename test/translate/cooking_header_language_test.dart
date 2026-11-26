// The cooking header's language switch (SS-106), wired through a real
// HybridRuntime over FakeHybridInference. No model, camera or network.

import 'dart:async';
import 'dart:typed_data';

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
import 'package:soussight/live/live_types.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/recipe_translator.dart';
import 'package:soussight/translate/translation_runtime.dart';

import 'translate_fixtures.dart';

class _Media implements LiveMedia {
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Stream<CapturedFrame> get timedFrames => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> startCameraOnly() async {}
  @override
  Future<void> stop() async {}
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void playAudio(Uint8List pcm24khz) {}
  @override
  void interruptPlayback() {}
}

class _NoCloud implements CloudFallbackSender {
  int sends = 0;
  @override
  Future<HybridResult> send(HybridRequest request) async {
    sends++;
    throw const HybridException(HybridErrorCode.failed, 'not in tests');
  }

  @override
  Future<void> cancel(String requestId) async {}
}

void main() {
  late FakeHybridInference inference;
  late HybridRuntime hybrid;
  late _NoCloud cloud;

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(fakeServices))!;
    inference = FakeHybridInference();
    cloud = _NoCloud();
    hybrid = HybridRuntime.create(
      inference: inference,
      cloudRoutes: CloudRoutes.parse(''),
      cloudFallback: cloud,
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    final cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: null,
      media: _Media(),
      onSessionReady: hybrid.bindCookingSession,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(
          services: services,
          isDemo: false,
          hybrid: hybrid,
          createCoordinator: () => cook,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('header switch translates on device and ledgers the leg', (
    tester,
  ) async {
    await pumpScreen(tester);
    final button = find.byKey(const ValueKey('cook-language'));
    expect(button, findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('English')),
      findsOneWidget,
    );

    inference.script.add(
      (HybridRequest r) => HybridResult(
        requestId: '',
        text: answerFor(r.task),
        source: InferenceSource.onDevice,
      ),
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-es')));
    await tester.pumpAndSettle();

    expect(find.text('AI translation'), findsOneWidget);
    expect(find.text('Translated on this device.'), findsOneWidget);
    final request = inference.requests.single;
    expect(request.task.feature, recipeTranslateFeature);
    // No route approved in this build: the dispatcher kept it on device.
    expect(request.mode, HybridMode.onlyOnDevice);
    expect(cloud.sends, 0);
    expect(hybrid.ledger.legs.single.feature, recipeTranslateFeature);
    expect(translationFor(hybrid).language, spanish);

    Navigator.of(tester.element(find.text('AI translation'))).pop();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: button, matching: find.text(spanish.nativeName)),
      findsOneWidget,
    );
  });

  testWidgets('runtime glue: one controller per runtime, Coach Lite follows', (
    tester,
  ) async {
    await pumpScreen(tester);
    final controller = translationFor(hybrid);
    expect(identical(translationFor(hybrid), controller), isTrue);

    inference.enqueueText('{}');
    final wrapped = languageAwareDispatcherFor(hybrid);
    unawaited(controller.select(spanish, recipe: testRecipe(), sessionId: 's'));
    controller.cancel();
    final op = wrapped.start(
      const HybridTask(
        feature: 'coach_lite',
        systemInstruction: 'Base.',
        parts: [HybridText('q')],
        maxOutputTokens: 10,
        timeout: Duration(seconds: 5),
      ),
      sessionId: 's',
    );
    await tester.runAsync(() => op.result);
    expect(
      inference.requests.last.task.systemInstruction,
      withAnswerLanguage('Base.', spanish),
    );
  });
}
