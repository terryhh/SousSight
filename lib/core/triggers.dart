// Deterministic handoff gates and assessment validation. The model fills
// flags in its structured response; code decides what happens.

import 'models.dart';

final _safetyPattern = RegExp(
  r'\b(allerg\w*|anaphyla\w*|sesame|peanut|tree ?nut|gluten|celiac|coeliac|'
  r'shellfish|dairy|lactose|egg allergy|spoil\w*|expired|expiry|moldy|mouldy|'
  r'mold|mould|smells? (off|bad|weird)|gone bad|safe to eat|food poisoning|'
  r'sick|pregnan\w*|raw chicken|undercooked)\b',
  caseSensitive: false,
);

/// Allergen, spoilage, illness, "is it safe" questions. These are always out
/// of scope for the coach and route to the allergens skill.
bool isSafetyQuestion(String text) => _safetyPattern.hasMatch(text);

/// Fixed coach reply for safety questions. Never model-generated.
const safetyReply =
    "I can't judge allergens or food safety from a photo. Check every "
    'ingredient label, and when in doubt, throw it out. I can send this to an '
    'instructor who covers dietary questions.';

/// Returns the reviewed substitution for [ingredientId] whose name matches
/// [proposed] (case-insensitive substring either way), or null.
ReviewedSubstitution? findReviewedSubstitution(
  Recipe recipe,
  String ingredientId,
  String proposed,
) {
  final p = proposed.trim().toLowerCase();
  if (p.isEmpty) return null;
  for (final s in recipe.reviewedSubstitutions) {
    if (s.ingredientId != ingredientId) continue;
    final name = s.substitute.toLowerCase();
    if (name.contains(p) || p.contains(name)) return s;
  }
  return null;
}

/// All reviewed substitutions for one ingredient (shown on the checklist).
List<ReviewedSubstitution> reviewedSubstitutionsFor(
        Recipe recipe, String ingredientId) =>
    recipe.reviewedSubstitutions
        .where((s) => s.ingredientId == ingredientId)
        .toList();

/// Gate 2: two inconclusive results in a row at the same checkpoint.
/// [recent] is newest-last.
bool shouldOfferHandoffAfter(List<Assessment> recent) {
  if (recent.length < 2) return false;
  bool inconclusive(Assessment a) =>
      a.outcome == AssessmentOutcome.uncertain ||
      a.outcome == AssessmentOutcome.needBetterView;
  return inconclusive(recent[recent.length - 1]) &&
      inconclusive(recent[recent.length - 2]);
}

/// Validates a model assessment against the checkpoint definition.
/// - A low-confidence "matches" is downgraded to "uncertain".
/// - Adjustment ids outside the reviewed list are dropped.
/// - Out-of-scope results never claim a match.
Assessment validateAssessment(Assessment a, CheckpointDef def) {
  var v = a;
  if (v.adjustmentId != null && !def.allowedAdjustments.contains(v.adjustmentId)) {
    v = v.copyWith(adjustmentId: null);
  }
  if (v.outcome == AssessmentOutcome.matchesTarget &&
      (v.confidence == Confidence.low || v.outOfScope)) {
    v = v.copyWith(outcome: AssessmentOutcome.uncertain);
  }
  if (v.outcome == AssessmentOutcome.adjust && v.adjustmentId == null &&
      v.suggestedAction.trim().isEmpty) {
    v = v.copyWith(outcome: AssessmentOutcome.uncertain);
  }
  return v;
}

/// Stale-result guard: an async result requested at [requestedRevision] for
/// [requestedStepId] may only be applied if the session has not moved past it.
bool isStale(CookingSession now, {required int requestedRevision, required String requestedStepId}) =>
    now.currentStepId != requestedStepId || now.revision != requestedRevision;
