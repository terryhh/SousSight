import '../core/models.dart';

/// Prefix the coach uses for the one-time allergy question so a saved cook
/// answer can be recognised across reconnects.
const allergyQuestionPrefix = 'Allergy check:';

/// One allergen declared by the recipe data. [optionalOnly] is true when every
/// ingredient carrying it is optional, so the cook may simply leave it out.
class RecipeAllergen {
  const RecipeAllergen(this.name, {required this.optionalOnly});
  final String name;
  final bool optionalOnly;

  String get label => optionalOnly ? '$name (optional ingredient)' : name;
}

/// Union of the ingredient allergen tags, in recipe order, de-duplicated
/// case-insensitively. Optional ingredients are included but marked.
List<RecipeAllergen> recipeAllergens(Recipe recipe) {
  final order = <String>[];
  final names = <String, String>{};
  final required = <String, bool>{};
  for (final ingredient in recipe.ingredients) {
    for (final raw in ingredient.allergens) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (!names.containsKey(key)) {
        order.add(key);
        names[key] = name;
      }
      required[key] = (required[key] ?? false) || !ingredient.optional;
    }
  }
  return [
    for (final key in order)
      RecipeAllergen(names[key]!, optionalOnly: !(required[key] ?? false)),
  ];
}

/// Whether the cook already answered the allergy question in this session.
bool hasAllergyAnswer(Iterable<String> confirmedFacts) => confirmedFacts.any(
  (fact) =>
      fact.contains('Answer from cook:') &&
      (fact.startsWith(allergyQuestionPrefix) ||
          fact
              .split('Answer from cook:')
              .first
              .toLowerCase()
              .contains('allerg')),
);

/// Opening instruction for the live coach, or null when no question is needed.
String? allergyContextLine(Recipe recipe, Iterable<String> confirmedFacts) {
  final allergens = recipeAllergens(recipe);
  if (allergens.isEmpty || hasAllergyAnswer(confirmedFacts)) return null;
  final list = allergens.map((a) => a.label).join(', ');
  return 'Recipe allergens: $list. Before any other step guidance, use '
      'ask_cook once with a question starting "$allergyQuestionPrefix" to ask '
      'whether anyone eating has an allergy to these; you may still show the '
      'opening panels while you wait. If yes, use research_cooking for a safe '
      'substitution and let the cook confirm it. Never claim the camera can '
      'verify allergen absence; package labels are the source of truth.';
}
