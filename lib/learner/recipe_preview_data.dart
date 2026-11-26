// What the recipe preview shows before cooking starts (SS-099). Everything
// here is computed on the device from the recipe, the cook's confirmed pantry
// list and the household allergens saved on this device. No model call.

import '../core/models.dart';
import '../pantry/pantry_handoff.dart' show matchIngredientId;
import '../pantry/recipe_draft.dart' show isDraftRecipe;
import 'recipe_allergens.dart';

/// Hands-on minutes the preview assumes for a step without a recipe timer.
const kPreviewMinutesPerStep = 3;

/// Hands-on minutes for a step with a timer (setting it going, checking).
const kPreviewMinutesPerTimedStep = 1;

/// Shown under the time estimate so it is never read as the recipe's own.
const kPreviewTimeNote =
    'Estimated from the steps and the recipe’s timers. Go at your own pace.';

/// The allergen caution that ends every allergen sentence on the preview.
const kCheckLabelsYourself = 'check labels yourself.';

const kNoHouseholdAllergensSaved =
    'No household allergens are saved on this device yet.';

/// Ingredients compared with the confirmed pantry list, recipe order.
class PreviewIngredients {
  const PreviewIngredients({
    required this.hasPantryList,
    required this.have,
    required this.missing,
    required this.optionalMissing,
  });

  /// False when the cook skipped the pantry check: the preview then lists
  /// what the recipe needs without claiming what is in the kitchen.
  final bool hasPantryList;
  final List<Ingredient> have;

  /// Required ingredients not on the confirmed list.
  final List<Ingredient> missing;

  /// Optional ingredients not on the confirmed list.
  final List<Ingredient> optionalMissing;

  int get total => have.length + missing.length + optionalMissing.length;
}

/// Uses the same matcher as the pantry hand-off, so the preview shows exactly
/// the ingredients the coach will be told the cook has.
PreviewIngredients previewIngredients(
  Recipe recipe,
  List<String> confirmedItems,
) {
  final items = [
    for (final item in confirmedItems)
      if (item.trim().isNotEmpty) item,
  ];
  final matched = {for (final item in items) ?matchIngredientId(item, recipe)};
  final have = <Ingredient>[];
  final missing = <Ingredient>[];
  final optional = <Ingredient>[];
  for (final ingredient in recipe.ingredients) {
    if (items.isNotEmpty && matched.contains(ingredient.id)) {
      have.add(ingredient);
    } else if (ingredient.optional) {
      optional.add(ingredient);
    } else {
      missing.add(ingredient);
    }
  }
  return PreviewIngredients(
    hasPantryList: items.isNotEmpty,
    have: have,
    missing: missing,
    optionalMissing: optional,
  );
}

/// A rough plan for the clock: hands-on minutes plus timer waits.
class PreviewTime {
  const PreviewTime({required this.activeMinutes, required this.totalMinutes});
  final int activeMinutes;
  final int totalMinutes;
}

PreviewTime previewTime(Recipe recipe) {
  var active = 0;
  var waitSeconds = 0;
  for (final step in recipe.steps) {
    final timer = step.timerSeconds;
    if (timer != null && timer > 0) {
      active += kPreviewMinutesPerTimedStep;
      waitSeconds += timer;
    } else {
      active += kPreviewMinutesPerStep;
    }
  }
  final wait = (waitSeconds / 60).ceil();
  return PreviewTime(activeMinutes: active, totalMinutes: active + wait);
}

/// "1 min", "25 min", "1 hr 5 min".
String formatPreviewMinutes(int minutes) {
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours hr' : '$hours hr $rest min';
}

String _normalizeAllergen(String name) {
  final value = name.trim().toLowerCase();
  if (value.length > 3 && value.endsWith('s') && !value.endsWith('ss')) {
    return value.substring(0, value.length - 1);
  }
  return value;
}

String _list(List<String> names) => switch (names.length) {
  0 => '',
  1 => names.single,
  2 => '${names[0]} and ${names[1]}',
  _ => '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}',
};

/// The recipe's allergen tags set against the household list. Wording only
/// ever repeats what the recipe data mentions; it never says a dish is free
/// of an allergen or safe to eat.
class PreviewAllergens {
  PreviewAllergens(Recipe recipe, Set<String> household)
    : mentioned = recipeAllergens(recipe),
      household = household.toList()..sort() {
    final saved = {for (final a in household) _normalizeAllergen(a)};
    householdMatches = [
      for (final a in mentioned)
        if (saved.contains(_normalizeAllergen(a.name))) a,
    ];
  }

  final List<RecipeAllergen> mentioned;
  final List<String> household;
  late final List<RecipeAllergen> householdMatches;

  bool get householdSaved => household.isNotEmpty;

  /// "The recipe mentions wheat and peanut — check labels yourself."
  String get mentionLine => mentioned.isEmpty
      ? 'The recipe doesn’t list any allergens — $kCheckLabelsYourself'
      : 'The recipe mentions ${_list([for (final a in mentioned) a.label])} '
            '— $kCheckLabelsYourself';

  /// The household comparison, or null when nothing is saved.
  String? get householdLine {
    if (!householdSaved) return null;
    if (householdMatches.isEmpty) {
      return 'The recipe doesn’t mention your household allergens '
          '(${_list(household)}) — $kCheckLabelsYourself';
    }
    final names = _list([for (final a in householdMatches) a.name]);
    final verb = householdMatches.length == 1 ? 'is' : 'are';
    return 'The recipe mentions $names, which $verb on your household list '
        '— $kCheckLabelsYourself';
  }
}

/// Everything the preview screen shows, computed once per build.
class RecipePreviewData {
  RecipePreviewData(
    this.recipe, {
    List<String> confirmedItems = const [],
    Set<String> household = const {},
  }) : ingredients = previewIngredients(recipe, confirmedItems),
       allergens = PreviewAllergens(recipe, household),
       time = previewTime(recipe);

  final Recipe recipe;
  final PreviewIngredients ingredients;
  final PreviewAllergens allergens;
  final PreviewTime time;

  bool get isDraft => isDraftRecipe(recipe);
  int get stepCount => recipe.steps.length;
  List<String> get equipment => [
    for (final e in recipe.equipment)
      if (e.trim().isNotEmpty) e.trim(),
  ];
}

/// A short, speakable name: "Canned black beans, drained" → "canned black
/// beans". Text after the first comma or bracket is preparation detail.
String shortIngredientName(Ingredient ingredient) {
  final name = ingredient.name.split(RegExp(r'[,(]')).first.trim();
  final base = name.isEmpty ? ingredient.name.trim() : name;
  // Lower-case a capitalised first word, but leave acronyms ("BBQ") alone.
  if (base.length > 1 &&
      base[0] != base[0].toLowerCase() &&
      base[1] == base[1].toLowerCase()) {
    return base[0].toLowerCase() + base.substring(1);
  }
  return base;
}

/// The exact Coach Lite question behind a "Find a swap" tap.
String swapQuestion(Ingredient ingredient, Recipe recipe) =>
    'What can I use instead of ${shortIngredientName(ingredient)} in '
    '${recipe.title.trim()}?';
