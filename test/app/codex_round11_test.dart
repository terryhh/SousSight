// Codex review of #221 (last round). Fakes only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/draft_recipe_chip.dart';
import 'package:soussight/learner/plain_research_text.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_handoff.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

class _Answer implements CookingResearchClient {
  const _Answer(this.answer);
  final String answer;
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async =>
      CookingResearchResult(answer: answer);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('#4 "2 cans of black beans" maps to black_beans', () async {
    final recipes = await loadRecipeCatalog();
    final salsa = recipes.firstWhere((r) => r.id == 'black_bean_corn_salsa_v1');
    expect(matchIngredientId('2 cans of black beans', salsa), 'black_beans');
  });

  test('#6 pretend photo and voice legs record their kinds', () async {
    final recipes = await loadRecipeCatalog();
    for (final (photo, audio, kinds) in [
      (true, false, {DataKind.image}),
      (false, true, {DataKind.audio}),
      (true, true, {DataKind.image, DataKind.audio}),
    ]) {
      final hybrid = RehearsalHybridRuntime.create(
        inference: RehearsalHybridInference(answerDelay: Duration.zero),
      );
      final result =
          await RehearsalPantryClient(
            hybrid,
            fallback: const FakePantryClient(delay: Duration.zero),
          ).identify(
            PantryInput(simulatedPhoto: photo, simulatedAudio: audio),
            recipes,
          );
      expect(result.legs.single.kinds, kinds);
      expect(hybrid.ledger.legs.single.kinds, kinds);
    }
  });

  test('#9 formatting controls alone are no answer', () async {
    const q = CookingResearchQuery(question: 'q', currentStep: 's');
    for (final answer in ['[\u200E](https://x.example)', '\u202A\u2066 ']) {
      await expectLater(
        PlainTextResearchClient(_Answer(answer)).research(q),
        throwsA(isA<CookingResearchException>()),
      );
    }
  });

  test('#10 the unavailable copy covers offline', () {
    expect(pantryVoiceUnavailable, contains('connection'));
    expect(pantryVoiceUnavailable, contains('offline'));
  });

  testWidgets('#12 a practice draft says it is pretend', (tester) async {
    const recipe = Recipe(
      id: 'draft_x',
      version: 1,
      title: 'Draft',
      summary: '',
      ingredients: [],
      equipment: [],
      steps: [],
      checkpoints: [],
      reviewedSubstitutions: [],
      adjustmentLabels: {},
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DraftRecipeChip(recipe: recipe, practice: true)),
      ),
    );
    expect(find.text(kPracticeDraftLabel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('draft-recipe-chip')));
    await tester.pumpAndSettle();
    expect(find.text(practiceDraftAdvice), findsOneWidget);
    expect(find.textContaining('Gemini'), findsNothing);
  });
}
