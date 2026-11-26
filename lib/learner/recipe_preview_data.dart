// What the recipe preview shows before cooking starts (SS-099). Everything
// here is computed on the device from the recipe, the cook's confirmed pantry
// list and the household allergens saved on this device. No model call.

import 'package:flutter/foundation.dart' show setEquals;

import '../core/models.dart';
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
    required this.pantryChecked,
    required this.have,
    required this.missing,
    required this.optionalMissing,
  });

  /// False only when the cook skipped the pantry check: the preview then
  /// lists what the recipe needs without claiming what is in the kitchen.
  /// A cook who checked but confirmed nothing has [pantryChecked] true and
  /// sees every required ingredient as missing, each with "Find a swap".
  final bool pantryChecked;
  final List<Ingredient> have;

  /// Required ingredients not on the confirmed list.
  final List<Ingredient> missing;

  /// Optional ingredients not on the confirmed list.
  final List<Ingredient> optionalMissing;

  int get total => have.length + missing.length + optionalMissing.length;
}

// ---- ingredient identity ----------------------------------------------------
//
// A confirmed item ticks an ingredient only when it names the same food as
// the ingredient's display name (or one of its "or" alternatives, or an
// explicit alias). Internal IDs are never read. Words that only describe
// packaging or preparation are dropped; words that tell foods apart ("red"
// onion, corn "starch", "flour" tortillas) are kept, so the match is exact on
// what is left and a missing ingredient is never ticked by a different food.

/// Packaging, preparation and filler words that do not change the food.
const _previewIgnoredWords = {
  'a',
  'an',
  'and',
  'the',
  'of',
  'some',
  'my',
  'for',
  'can',
  'canned',
  'jar',
  'jarred',
  'bag',
  'box',
  'loaf',
  'bottle',
  'pack',
  'package',
  'fresh',
  'whole',
  'sliced',
  'diced',
  'chopped',
  'minced',
  'shredded',
  'grated',
  'drained',
  'rinsed',
  'peeled',
  'finely',
  'thinly',
  'roughly',
  'pre',
};

/// Canonical food phrase → other phrases a cook may type for it.
const kPreviewIngredientAliases = <String, List<String>>{
  'mayonnaise': ['mayo'],
  'lime juice': ['lime', 'limes'],
  'lemon juice': ['lemon', 'lemons'],
  'salt and black pepper': ['salt and pepper'],
  'peanut butter': ['pb'],
  'chickpeas': ['garbanzo beans', 'garbanzos'],
  'cilantro': ['coriander leaves'],
};

String _previewStem(String word) {
  if (word.endsWith('oes') && word.length > 4) {
    return word.substring(0, word.length - 2);
  }
  if (word.endsWith('ies') && word.length > 4) {
    return '${word.substring(0, word.length - 3)}y';
  }
  if (word.endsWith('ches') || word.endsWith('shes') || word.endsWith('ses')) {
    return word.substring(0, word.length - 2);
  }
  if (word.endsWith('s') && word.length > 3 && !word.endsWith('ss')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

/// The food a phrase names, as a set of stemmed significant words.
Set<String> previewFoodWords(String phrase) => {
  for (final word in phrase.toLowerCase().split(RegExp(r'[^a-z]+')))
    if (word.isNotEmpty &&
        !_previewIgnoredWords.contains(word) &&
        !_previewIgnoredWords.contains(_previewStem(word)))
      _previewStem(word),
};

/// The foods an ingredient's display name stands for: its head (text before
/// the first comma or bracket), each " or " alternative, and their aliases.
List<Set<String>> previewIngredientIdentities(Ingredient ingredient) {
  final head = ingredient.name
      .split(RegExp(r'[,(]'))
      .first
      .trim()
      .toLowerCase();
  final phrases = <String>{
    head,
    ...head.split(RegExp(r'\s+or\s+')).map((p) => p.trim()),
  };
  for (final phrase in [...phrases]) {
    for (final entry in kPreviewIngredientAliases.entries) {
      if (setEquals(previewFoodWords(phrase), previewFoodWords(entry.key))) {
        phrases.addAll(entry.value);
      }
    }
  }
  return [
    for (final phrase in phrases)
      if (previewFoodWords(phrase) case final words when words.isNotEmpty)
        words,
  ];
}

/// Whether a cook-confirmed pantry item is the same food as [ingredient].
bool previewItemMatches(String item, Ingredient ingredient) {
  final words = previewFoodWords(item);
  if (words.isEmpty) return false;
  return previewIngredientIdentities(ingredient)
      .any((identity) => setEquals(identity, words));
}

/// [pantryChecked] is false only when the cook skipped the pantry check.
PreviewIngredients previewIngredients(
  Recipe recipe,
  List<String> confirmedItems, {
  required bool pantryChecked,
}) {
  final items = [
    for (final item in confirmedItems)
      if (item.trim().isNotEmpty) item,
  ];
  final have = <Ingredient>[];
  final missing = <Ingredient>[];
  final optional = <Ingredient>[];
  for (final ingredient in recipe.ingredients) {
    if (items.any((item) => previewItemMatches(item, ingredient))) {
      have.add(ingredient);
    } else if (ingredient.optional) {
      optional.add(ingredient);
    } else {
      missing.add(ingredient);
    }
  }
  return PreviewIngredients(
    pantryChecked: pantryChecked || items.isNotEmpty,
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
    bool pantryChecked = true,
    Set<String> household = const {},
  }) : ingredients = previewIngredients(
         recipe,
         confirmedItems,
         pantryChecked: pantryChecked,
       ),
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
