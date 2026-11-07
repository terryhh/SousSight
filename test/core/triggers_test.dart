import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/core/triggers.dart';

Assessment a(AssessmentOutcome o,
        {Confidence c = Confidence.high, String? adj, String action = 'x'}) =>
    Assessment(
        outcome: o,
        observations: const ['obs'],
        cue: 'cue',
        suggestedAction: action,
        confidence: c,
        adjustmentId: adj);

void main() {
  final recipe = Recipe.fromMap(jsonDecode(
          File('assets/recipes/chickpea_wrap_v1.json').readAsStringSync())
      as Map<String, dynamic>);
  final mash = recipe.checkpoints.first;

  test('recipe asset parses', () {
    expect(recipe.steps.map((s) => s.id), ['pickle_onion', 'mash', 'mix', 'roll']);
    expect(recipe.checkpointForStep('mash')?.id, 'cp_mash');
    expect(recipe.step('pickle_onion').timerSeconds, 300);
  });

  test('safety questions are detected', () {
    expect(isSafetyQuestion('My roommate has a sesame allergy, is this ok?'), isTrue);
    expect(isSafetyQuestion('The mayo smells off'), isTrue);
    expect(isSafetyQuestion('Is it safe to eat tomorrow?'), isTrue);
    expect(isSafetyQuestion('No lemon, can I use vinegar?'), isFalse);
  });

  test('reviewed substitutions match loosely; unreviewed do not', () {
    expect(findReviewedSubstitution(recipe, 'mayo', 'greek yogurt'), isNotNull);
    expect(findReviewedSubstitution(recipe, 'lemon', 'vinegar'), isNull);
  });

  test('two inconclusive results in a row offer the handoff', () {
    expect(shouldOfferHandoffAfter([a(AssessmentOutcome.uncertain)]), isFalse);
    expect(
        shouldOfferHandoffAfter([
          a(AssessmentOutcome.uncertain),
          a(AssessmentOutcome.needBetterView),
        ]),
        isTrue);
    expect(
        shouldOfferHandoffAfter([
          a(AssessmentOutcome.uncertain),
          a(AssessmentOutcome.adjust),
        ]),
        isFalse);
  });

  test('validation downgrades low-confidence matches and drops unknown adjustments', () {
    expect(validateAssessment(a(AssessmentOutcome.matchesTarget, c: Confidence.low), mash).outcome,
        AssessmentOutcome.uncertain);
    expect(validateAssessment(a(AssessmentOutcome.adjust, adj: 'add_salt'), mash).adjustmentId,
        isNull);
    expect(validateAssessment(a(AssessmentOutcome.adjust, adj: 'mash_more'), mash).adjustmentId,
        'mash_more');
  });

  test('stale results are detected by revision and step', () {
    final s = CookingSession(
      id: 's', learnerId: 'l', recipeId: recipe.id, recipeVersion: 1,
      ingredients: const {}, substitutions: const [], currentStepId: 'mix',
      completedStepIds: const ['mash'], revision: 4,
      createdAt: DateTime(2026), updatedAt: DateTime(2026),
    );
    expect(isStale(s, requestedRevision: 4, requestedStepId: 'mix'), isFalse);
    expect(isStale(s, requestedRevision: 3, requestedStepId: 'mix'), isTrue);
    expect(isStale(s, requestedRevision: 4, requestedStepId: 'mash'), isTrue);
  });
}
