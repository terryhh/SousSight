// When no AI can answer a typed question, answer it as well as the reviewed
// recipe can (Maya persona, SS-089): the ingredients the question names, any
// reviewed swaps for them, and the current step's cue. App-authored text from
// the recipe, never model output, and labelled as such.

import '../core/models.dart';
import '../pantry/pantry_ui.dart' show pantryNamesMatch;

/// Up to [limit] plain lines from [recipe] relevant to [question].
List<String> recipeNotesFor(
  String question,
  Recipe recipe,
  RecipeStep step, {
  int limit = 4,
}) {
  final q = question.toLowerCase();
  final words = q.split(RegExp(r'[^a-z]+')).where((w) => w.length > 2);
  bool mentioned(String name) =>
      q.contains(name.toLowerCase()) ||
      words.any((w) => pantryNamesMatch(w, name));
  final lines = <String>[];
  for (final ingredient in recipe.ingredients) {
    if (!mentioned(ingredient.name)) continue;
    lines.add(
      'Recipe: ${ingredient.qty} ${ingredient.name}'
      '${ingredient.optional ? ' (optional)' : ''}.',
    );
    for (final swap in recipe.reviewedSubstitutions) {
      if (swap.ingredientId != ingredient.id) continue;
      final note = swap.note.trim();
      lines.add(
        'Reviewed swap: ${swap.substitute} for ${ingredient.name}'
        '${note.isEmpty ? '.' : ' — $note'}',
      );
    }
  }
  final cue = step.cue.trim();
  if (cue.isNotEmpty) lines.add('This step — look for: $cue');
  return lines.take(limit).toList();
}
