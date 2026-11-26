// Maya persona findings folded into SS-089: an unanswered question still
// gets recipe-based help, "Am I doing this right?" always answers, and a
// paused cloud is one calm line. Fakes only.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/coach_lite/coach_lite_answer_card.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/recipe_notes.dart';
import 'package:soussight/trust/app_readiness.dart';

const _step = RecipeStep(
  id: 's1',
  title: 'Spread',
  instruction: 'Spread the peanut butter.',
  cue: 'An even layer to the edges.',
);

Recipe _recipe({List<ReviewedSubstitution> swaps = const []}) => Recipe(
  id: 'r',
  version: 1,
  title: 'Sandwich',
  summary: '',
  ingredients: const [
    Ingredient(id: 'pb', name: 'Peanut butter', qty: 'about 2 tbsp'),
    Ingredient(id: 'jam', name: 'Jam', qty: '1 tbsp', optional: true),
    Ingredient(id: 'bread', name: 'Bread', qty: '2 slices'),
  ],
  equipment: const [],
  steps: const [_step],
  checkpoints: const [],
  reviewedSubstitutions: swaps,
  adjustmentLabels: const {},
);

void main() {
  group('recipe notes when no AI can answer', () {
    test('names the ingredients asked about, swaps, then the cue', () {
      final notes = recipeNotesFor(
        'Can I skip the jam or use almond butter for the peanut butter?',
        _recipe(
          swaps: const [
            ReviewedSubstitution(
              ingredientId: 'pb',
              substitute: 'Sunflower seed butter',
              note: 'Nut-free.',
              approvedBy: 'chef',
            ),
          ],
        ),
        _step,
      );
      expect(notes, [
        'Recipe: about 2 tbsp Peanut butter.',
        'Reviewed swap: Sunflower seed butter for Peanut butter — Nut-free.',
        'Recipe: 1 tbsp Jam (optional).',
        'This step — look for: An even layer to the edges.',
      ]);
    });

    test('nothing named: only the cue; limit respected', () {
      expect(recipeNotesFor('Is this right?', _recipe(), _step), [
        'This step — look for: An even layer to the edges.',
      ]);
      expect(
        recipeNotesFor('bread jam peanut butter', _recipe(), _step, limit: 2),
        hasLength(2),
      );
    });

    testWidgets('the footer shows them, labelled, only without an answer', (
      tester,
    ) async {
      CoachLiteAnswer answer(CoachLiteStatus status) => CoachLiteAnswer(
        stamp: const CoachLiteStamp(
          sessionId: 's',
          epoch: 1,
          stepId: 's1',
          sequence: 1,
        ),
        status: status,
        blocked: status == CoachLiteStatus.blocked
            ? RouteReason.noLocalModel
            : null,
        kind: CoachLiteQuestionKind.stepHelp,
        components: const [],
        legs: status == CoachLiteStatus.answered
            ? const [
                InferenceLeg(
                  requestId: 'r',
                  feature: 'coach_lite',
                  mode: HybridMode.onlyOnDevice,
                  kinds: {DataKind.text},
                  transferPermitted: false,
                  provenance: Provenance.sdkOnDevice,
                ),
              ]
            : const [],
      );
      for (final status in [
        CoachLiteStatus.blocked,
        CoachLiteStatus.answered,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CoachLiteAnswerFooter(
                answer: answer(status),
                question: 'Jam?',
                recipeNotes: const ['Recipe: 1 tbsp Jam (optional).'],
                onStartTimer: (_, _) {},
              ),
            ),
          ),
        );
        final shown = status == CoachLiteStatus.blocked;
        expect(
          find.text('From the recipe (not AI)'),
          shown ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('• Recipe: 1 tbsp Jam (optional).'),
          shown ? findsOneWidget : findsNothing,
        );
      }
    });
  });

  testWidgets('"Am I doing this right?" always answers without Live', (
    tester,
  ) async {
    final services = (await tester.runAsync(fakeServices))!;
    final cook = CookingCoordinator(
      services: services,
      research: const FakeCookingResearchClient(),
      transportFactory: null,
      media: DemoLiveMedia(),
    );
    await tester.runAsync(cook.initialize);
    await cook.checkNow('Ready');
    expect(cook.alert, startsWith('You said: Ready. Compare your food'));
    expect(cook.alert, isNot(contains('Connect the live coach')));
    cook.dispose();
  });

  test('a paused cloud is one honest line', () {
    AppReadiness readiness({required bool local}) => AppReadiness.evaluate(
      ReadinessInput(
        capabilities: fakeWebCapabilities,
        text: HybridAvailability(
          status: local ? OnDeviceStatus.available : OnDeviceStatus.unavailable,
          reason: local ? null : 'device_not_eligible',
        ),
        image: const HybridAvailability(status: OnDeviceStatus.unavailable),
        camera: CameraAccess.notAsked,
        online: true,
        cloudApproved: true,
        attestationFailed: true,
      ),
    );
    expect(
      readinessCalmLine(readiness(local: false)),
      contains('Reloading the page may fix it'),
    );
    expect(
      readinessCalmLine(readiness(local: true)),
      endsWith('Help on this device still works.'),
    );
    final quota = AppReadiness.evaluate(
      ReadinessInput(
        capabilities: fakeWebCapabilities,
        text: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
          reason: 'device_not_eligible',
        ),
        image: const HybridAvailability(status: OnDeviceStatus.unavailable),
        camera: CameraAccess.notAsked,
        online: true,
        cloudApproved: true,
        quotaReached: true,
      ),
    );
    expect(readinessCalmLine(quota), startsWith("Today's online help"));
  });
}
