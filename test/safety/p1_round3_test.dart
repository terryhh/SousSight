// Third Codex round on #240: the four P1s and the quick P2s, with fakes.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/coach_lite/tts.dart';
import 'package:soussight/genui/cooking_ui_controller.dart';
import 'package:soussight/safety/cook_safety.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/recipe_language_view.dart';
import 'package:soussight/translate/recipe_translator.dart';
import 'package:soussight/translate/translation_controller.dart';
import 'package:soussight/translate/translation_guard.dart';

import '../translate/translate_fixtures.dart';

class _Privacy implements PrivacySettings {
  final Set<String> on = {};
  @override
  bool localOnly(String feature) => on.contains(feature);
}

class _Consent implements ConsentGate {
  @override
  Future<ConsentGrant?> request(ConsentAsk ask) async => ConsentGrant(ask);
}

class _Adapter implements CloudFallbackSender {
  final requests = <HybridRequest>[];
  @override
  Future<HybridResult> send(HybridRequest request) async {
    requests.add(request);
    return HybridResult(
      requestId: request.requestId,
      text: '{}',
      source: InferenceSource.cloud,
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

String _answer(String body, {String id = 'tip'}) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': [id],
    },
    {'id': id, 'component': 'stepCue', 'title': 'Tip', 'body': body},
  ],
});

void main() {
  group('P1 #1: the last check runs after the ledger leg is published', () {
    late _Privacy privacy;
    late InferenceLedger ledger;
    late _Adapter adapter;
    late DefaultHybridDispatcher dispatcher;
    late FakeHybridInference bridge;

    setUp(() {
      privacy = _Privacy();
      ledger = InferenceLedger(sessionId: 's');
      adapter = _Adapter();
      // No bridge for cloud: the Dart adapter is the sender.
      bridge = FakeHybridInference(
        capabilities: const HybridCapabilities.none(),
        textAvailability: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
        ),
      );
      var seq = 0;
      dispatcher = DefaultHybridDispatcher(
        inference: bridge,
        privacy: privacy,
        cloudRoutes: CloudRoutes.parse('hybridFallback'),
        consent: _Consent(),
        ledger: ledger,
        cloudFallback: adapter,
        newId: () => 'id-${++seq}',
      );
    });

    HybridTask task() => const HybridTask(
      feature: 'recipe_draft',
      parts: [HybridText('recipe text')],
      maxOutputTokens: 10,
      timeout: Duration(seconds: 5),
    );

    test(
      'local-only switched on by a ledger listener stops the send',
      () async {
        ledger.addListener(() => privacy.on.add('recipe_draft'));
        final result = await dispatcher.start(task(), sessionId: 's').result;
        expect(adapter.requests, isEmpty);
        expect(bridge.requests, isEmpty);
        expect(result.blocked, RouteReason.localOnlySetting);
        expect(result.legs.single.transferPermitted, isFalse);
        expect(ledger.legs.single.transferPermitted, isFalse);
        expect(ledger.legs.single.error, HybridErrorCode.blocked);
      },
    );

    test('a cancel from a ledger listener stops the send', () async {
      late HybridOperation op;
      ledger.addListener(() => op.cancel());
      op = dispatcher.start(task(), sessionId: 's');
      final result = await op.result;
      expect(adapter.requests, isEmpty);
      expect(result.blocked, RouteReason.cancelled);
    });
  });

  group('P1 #2: model text in an app card is still gated', () {
    test('read-aloud skips a claim inside app_step, reads app notices', () {
      final answer = CoachLiteAnswer(
        stamp: const CoachLiteStamp(
          sessionId: 's',
          epoch: 0,
          stepId: 'x',
          sequence: 1,
        ),
        status: CoachLiteStatus.invalid,
        kind: CoachLiteQuestionKind.stepHelp,
        components: [
          {
            'id': 'root',
            'component': 'CookingColumn',
            'children': ['app_step', 'app_safety'],
          },
          {
            'id': 'app_step',
            'component': 'stepCue',
            'title': 'Sear',
            // An AI draft's instruction, shown in the app's fallback card.
            'body': 'The chicken is safe to eat. Flip it once.',
          },
          {
            'id': 'app_safety',
            'component': 'stepCue',
            'title': 'Check',
            'body': coachLiteSafetyNotice,
          },
        ],
      );
      final spoken = coachLiteSpokenText(answer);
      expect(spoken, isNot(contains('safe to eat')));
      expect(spoken, contains('Flip it once.'));
      expect(spoken, contains(coachLiteSafetyNotice));
    });
  });

  group('P1 #3: bare temperatures and allergen absence', () {
    const probes = [
      'The camera shows 165F at the center',
      'It reads 74 C inside.',
      'Está a 74 grados.',
      'No peanuts in this dish',
      'Made without nuts.',
      'Sin cacahuates',
      'No lleva maní.',
      'Sin cacahuetes ni nueces.',
    ];
    for (final p in probes) {
      test(p, () {
        expect(touchesFoodSafety(p), isTrue);
        expect(validateCoachLiteResponse(_answer(p)), isNotNull);
        final ui = CookingUiController();
        addTearDown(ui.dispose);
        expect(
          () => ui.applyJson(_answer(p)),
          throwsA(isA<UnsafeClaimException>()),
        );
      });
    }
    test('ordinary amounts still pass', () {
      expect(touchesFoodSafety('Add 2 cups of rice.'), isFalse);
      expect(touchesFoodSafety('Agrega 2 tazas de arroz.'), isFalse);
    });
  });

  group('P1 #4: thermometer and knife-safety lines stay in English', () {
    test('such source lines are never sent', () {
      for (final line in [
        'Check with a thermometer.',
        'Curl the fingertips of your holding hand under, like a claw.',
        'Keep the knife blade away from you.',
      ]) {
        expect(needsReviewedEnglish(line), isTrue, reason: line);
      }
    });
    test(
      'a translation that brings in or negates a thermometer is rejected',
      () {
        for (final t in [
          'No hace falta usar termómetro.',
          'Revisa con un termómetro.',
          'Corta con el cuchillo hacia ti.',
        ]) {
          expect(
            checkTranslatedLine(
              source: 'Stir the sauce.',
              translated: t,
              language: spanish,
            ),
            LineRejection.certifies,
            reason: t,
          );
        }
      },
    );
  });

  group('quick P2s', () {
    test(
      '#11: "sin salpicar" is technique; "¿Puedo comerlo así?" is safety',
      () {
        expect(
          classifyCoachLiteQuestion('¿Cómo lo mezclo sin salpicar?'),
          CoachLiteQuestionKind.stepHelp,
        );
        expect(
          classifyCoachLiteQuestion('¿Puedo comerlo así?'),
          CoachLiteQuestionKind.safety,
        );
        expect(
          classifyCoachLiteQuestion('¿Lo hago sin usar la mayonesa?'),
          CoachLiteQuestionKind.substitution,
        );
      },
    );

    test('#7: half and seventy are parsed', () {
      expect(
        checkTranslatedLine(
          source: 'Use half a cup of oil',
          translated: 'Usa una taza de aceite',
          language: spanish,
        ),
        LineRejection.numbersChanged,
      );
      expect(
        checkTranslatedLine(
          source: 'Warm for seventy minutes',
          translated: 'Calienta durante ochenta horas',
          language: spanish,
        ),
        LineRejection.numbersChanged,
      );
      expect(
        checkTranslatedLine(
          source: 'Warm for seventy minutes',
          translated: 'Calienta durante setenta minutos',
          language: spanish,
        ),
        isNull,
      );
    });

    testWidgets(
      '#5: the language button is disabled until the session exists',
      (tester) async {
        final c = TranslationController(
          translator: RecipeTranslator(dispatcher: FakeHybridDispatcher()),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CookLanguageButton(
                controller: c,
                recipe: testRecipe(),
                sessionId: () => 'pending',
                enabled: false,
              ),
            ),
          ),
        );
        final button = tester.widget<TextButton>(
          find.byKey(const ValueKey('cook-language')),
        );
        expect(button.onPressed, isNull);
      },
    );
  });
}
