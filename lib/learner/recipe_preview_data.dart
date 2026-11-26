// What the recipe preview shows before cooking starts (SS-099). Everything
// here is computed on the device from the recipe, the cook's confirmed pantry
// list and the household allergens saved on this device. No model call.

import 'package:flutter/foundation.dart' show setEquals;

import '../core/models.dart';
import '../label/label_check.dart' show kLabelAllergens;
import '../pantry/recipe_draft.dart' show isDraftRecipe;
import '../pantry/recipe_draft_client.dart' show draftFoodKey;
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
    this.substituted = const [],
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

  /// Ingredients the cook does not have, but for which they confirmed the
  /// recipe's reviewed substitute (e.g. canned diced tomatoes for fresh).
  /// Shown with the reviewer's note; never counted as the ingredient itself.
  final List<({Ingredient ingredient, ReviewedSubstitution substitution})>
  substituted;

  /// Required ingredients the cook has: the "X" of "You have X of N".
  int get requiredHave => have.where((i) => !i.optional).length;

  /// Every required ingredient: the "N" of "You have X of N".
  int get requiredTotal =>
      requiredHave +
      missing.length +
      substituted.where((s) => !s.ingredient.optional).length;
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
  'or',
  'bottled',
  'store',
  'bought',
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

/// Words that only describe size, amount or serving inside a qualifier,
/// e.g. "(10 inch)" or ", for serving". A qualifier made only of these (and
/// [_previewIgnoredWords]) leaves the food unchanged.
const _previewQualifierOnlyWords = {
  'inch',
  'cm',
  'oz',
  'ounce',
  'lb',
  'pound',
  'g',
  'gram',
  'kg',
  'ml',
  'l',
  'cup',
  'tbsp',
  'tsp',
  'tablespoon',
  'teaspoon',
  'small',
  'medium',
  'large',
  'serving',
  'optional',
  'to',
  'taste',
  'about',
  'approx',
  'extra',
  'more',
  'plus',
  'if',
  'needed',
  'each',
};

/// A qualifier with at most this many food words names the food itself
/// ("Milk (coconut)"); a longer one is a cook-facing note ("only if the cook
/// likes it", "flour tortillas contain wheat; check labels") and is ignored.
const _previewMaxIdentityQualifierWords = 2;

/// The foods an ingredient's display name stands for. The head (text before
/// the first comma or bracket) and each of its " or " alternatives, plus
/// any short qualifier that changes the food ("coconut" in "Milk
/// (coconut)"), plus explicit aliases. Size, serving and preparation
/// qualifiers ("(10 inch)", ", diced") are dropped. The verbatim full name
/// always matches too.
List<Set<String>> previewIngredientIdentities(Ingredient ingredient) {
  final name = ingredient.name.trim().toLowerCase();
  final parts = name.split(RegExp(r'[,()]'));
  final head = parts.first.trim();
  final identityQualifiers = <String>{};
  for (final part in parts.skip(1)) {
    final words = {
      for (final w in previewFoodWords(part))
        if (!_previewQualifierOnlyWords.contains(w)) w,
    };
    if (words.isNotEmpty && words.length <= _previewMaxIdentityQualifierWords) {
      identityQualifiers.addAll(words);
    }
  }
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
        {...words, ...identityQualifiers},
    if (previewFoodWords(name) case final words when words.isNotEmpty) words,
  ];
}

/// Packaging families ("canned", "jarred", "bottled"). Usually packaging is
/// just packaging, but when a recipe lists a packaged product as a reviewed
/// substitution ("Canned diced tomatoes, drained" for fresh tomato), an item
/// naming that form is the substitute, not the ingredient.
const _previewFormFamilies = [
  {'can', 'cans', 'canned', 'tin', 'tins', 'tinned'},
  {'jar', 'jars', 'jarred'},
  {'bottle', 'bottles', 'bottled'},
];

Set<int> _forms(String phrase) {
  final words = phrase.toLowerCase().split(RegExp(r'[^a-z]+')).toSet();
  return {
    for (var i = 0; i < _previewFormFamilies.length; i++)
      if (_previewFormFamilies[i].any(words.contains)) i,
  };
}

const _freshState = -1;

/// Stated preparation states: the packaged forms plus "fresh".
Set<int> _states(String phrase) => {
  ..._forms(phrase),
  if (RegExp(r'\bfresh\b', caseSensitive: false).hasMatch(phrase)) _freshState,
};

/// A leading amount and measuring unit on a confirmed item ("1 cup corn",
/// "2 tbsp peanut butter", "½ lb of beef"). Containers ("a can of") are kept:
/// they say what form the food is in.
final _leadingAmount = RegExp(
  r'^\s*(?:(?:\d+(?:[./]\d+)?|[½¼¾⅓⅔]|a|an|one|two|three|four|half|'
  r'some|few)\s*)+'
  r'(?:(?:cups?|tbsps?|tsps?|tablespoons?|teaspoons?|oz|ounces?|lbs?|'
  r'pounds?|g|grams?|kg|ml|l|liters?|litres?|pinch(?:es)?|handfuls?|'
  r'cloves?|slices?|pieces?|sticks?)\b\.?\s*(?:of\s+)?)?',
  caseSensitive: false,
);

String _withoutLeadingAmount(String item) =>
    item.replaceFirst(_leadingAmount, '');

/// Whether a cook-confirmed pantry item names the same food as [ingredient].
/// A leading amount on the item is ignored; a stated preparation state that
/// contradicts the ingredient's ("fresh" for "Canned black beans") is not
/// the same food.
bool previewItemMatches(String item, Ingredient ingredient) {
  final words = previewFoodWords(_withoutLeadingAmount(item));
  if (words.isEmpty) return false;
  final itemStates = _states(item);
  final nameStates = _states(ingredient.name);
  if (itemStates.isNotEmpty &&
      nameStates.isNotEmpty &&
      itemStates.intersection(nameStates).isEmpty) {
    return false;
  }
  return previewIngredientIdentities(ingredient)
      .any((identity) => setEquals(identity, words));
}

/// Whether [item] is the reviewed substitute [sub], in the substitute's own
/// packaged form.
bool _isSubstitute(String item, ReviewedSubstitution sub) =>
    _forms(sub.substitute).containsAll(_forms(item)) &&
    previewItemMatches(
      item,
      Ingredient(id: sub.ingredientId, name: sub.substitute, qty: ''),
    );

/// Whether [item] is [recipe]'s reviewed substitute for [ingredient] rather
/// than the ingredient: it matches the substitute and names a packaged form
/// that the ingredient's own name does not allow.
bool _isSubstituteNotIngredient(
  Recipe recipe,
  Ingredient ingredient,
  String item,
) =>
    !_forms(ingredient.name).containsAll(_forms(item)) &&
    recipe.reviewedSubstitutions.any(
      (sub) => sub.ingredientId == ingredient.id && _isSubstitute(item, sub),
    );

/// Whether the cook has [ingredient] of [recipe], from their confirmed items.
/// For an AI draft, the draft builder accepted each ingredient only when its
/// food key equals the confirmed item it came from (`fromConfirmed`), so the
/// same key comparison restores that validated association here ("Milk
/// (coconut)" from "1 cup coconut milk").
bool previewHasIngredient(
  Recipe recipe,
  Ingredient ingredient,
  Iterable<String> confirmedItems,
) {
  final draftKey = isDraftRecipe(recipe) ? draftFoodKey(ingredient.name) : '';
  return confirmedItems.any(
    (item) =>
        (previewItemMatches(item, ingredient) &&
            !_isSubstituteNotIngredient(recipe, ingredient, item)) ||
        (draftKey.isNotEmpty && draftFoodKey(item) == draftKey),
  );
}

/// The recipe's reviewed substitution for [ingredient] that the cook
/// confirmed having, if any.
ReviewedSubstitution? previewConfirmedSubstitution(
  Recipe recipe,
  Ingredient ingredient,
  Iterable<String> confirmedItems,
) {
  for (final sub in recipe.reviewedSubstitutions) {
    if (sub.ingredientId != ingredient.id) continue;
    if (confirmedItems.any((item) => _isSubstitute(item, sub))) return sub;
  }
  return null;
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
  final substituted =
      <({Ingredient ingredient, ReviewedSubstitution substitution})>[];
  for (final ingredient in recipe.ingredients) {
    if (previewHasIngredient(recipe, ingredient, items)) {
      have.add(ingredient);
    } else if (previewConfirmedSubstitution(recipe, ingredient, items)
        case final sub?) {
      // Before the optional branch, so an optional ingredient's reviewed swap
      // and its note are shown too (it stays out of the required count).
      substituted.add((ingredient: ingredient, substitution: sub));
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
    substituted: substituted,
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

/// Words in an ingredient name that suggest one of [kLabelAllergens]. Used
/// only to warn: a hint is never treated as proof either way.
const kPreviewAllergenNameHints = <String, List<String>>{
  'milk': [
    'milk',
    'cheese',
    'butter',
    'cream',
    'yogurt',
    'yoghurt',
    'whey',
    'ghee',
    'buttermilk',
    'parmesan',
    'mozzarella',
    'cheddar',
  ],
  'egg': ['egg', 'eggs', 'mayonnaise', 'mayo', 'aioli'],
  'fish': [
    'fish',
    'salmon',
    'tuna',
    'cod',
    'tilapia',
    'anchovy',
    'anchovies',
    'sardine',
    'sardines',
    'trout',
  ],
  'shellfish': [
    'shrimp',
    'prawn',
    'prawns',
    'crab',
    'lobster',
    'clam',
    'clams',
    'mussel',
    'mussels',
    'oyster',
    'oysters',
    'scallop',
    'scallops',
  ],
  'tree nut': [
    'almond',
    'almonds',
    'walnut',
    'walnuts',
    'cashew',
    'cashews',
    'pecan',
    'pecans',
    'pistachio',
    'pistachios',
    'hazelnut',
    'hazelnuts',
    'macadamia',
    'nutella',
  ],
  'peanut': ['peanut', 'peanuts'],
  'wheat': [
    'wheat',
    'flour',
    'bread',
    'pasta',
    'spaghetti',
    'noodle',
    'noodles',
    'couscous',
    'cracker',
    'crackers',
    'breadcrumbs',
    'pita',
    'bagel',
  ],
  'soy': ['soy', 'soya', 'tofu', 'edamame', 'tempeh', 'miso'],
  'sesame': ['sesame', 'tahini'],
};

// A plant word anywhere in a name ("Coconut milk", "Milk (coconut)",
// "Sunflower seed butter") means its milk, butter or cream is not dairy.
const _plantWords = {
  'peanut',
  'peanuts',
  'nut',
  'nuts',
  'almond',
  'cashew',
  'seed',
  'seeds',
  'sunflower',
  'apple',
  'coconut',
  'oat',
  'oats',
  'rice',
  'soy',
  'soya',
};
const _plantableDairyWords = {
  'milk',
  'butter',
  'cream',
  'yogurt',
  'yoghurt',
  'cheese',
};

/// [kLabelAllergens] that [text] (one food's name) suggests, in label order.
List<String> previewAllergenHintsFor(String text) {
  final words = text.toLowerCase().split(RegExp(r'[^a-z]+')).toSet();
  final plant = words.any(_plantWords.contains);
  final found = <String>{};
  for (final MapEntry(key: allergen, value: hints)
      in kPreviewAllergenNameHints.entries) {
    final pool = allergen == 'milk' && plant
        ? words.difference(_plantableDairyWords)
        : words;
    if (hints.any(pool.contains)) found.add(allergen);
  }
  return [
    for (final a in kLabelAllergens)
      if (found.contains(a)) a,
  ];
}

/// [kLabelAllergens] that the recipe's ingredient names suggest.
List<String> previewAllergenHints(Recipe recipe) {
  final found = {
    for (final i in recipe.ingredients) ...previewAllergenHintsFor(i.name),
  };
  return [
    for (final a in kLabelAllergens)
      if (found.contains(a)) a,
  ];
}

// "Contains dairy." in a reviewer's note names an allergen of the swap.
final _containsNote = RegExp(r'\bcontains?\s+([a-z ]+)', caseSensitive: false);

/// Allergens a reviewed swap suggests: from its name, and from a "contains
/// …" statement in the reviewer's note ("dairy" counts as milk, "gluten" as
/// wheat). Other words in the note are advice, not contents.
List<String> previewSwapAllergens(ReviewedSubstitution sub) {
  final contains = [
    for (final m in _containsNote.allMatches(sub.note)) m.group(1)!,
  ].join(' ').replaceAll('dairy', 'milk').replaceAll('gluten', 'wheat');
  final found = {
    ...previewAllergenHintsFor(sub.substitute),
    ...previewAllergenHintsFor(contains),
  };
  return [
    for (final a in kLabelAllergens)
      if (found.contains(a)) a,
  ];
}

/// The recipe's allergen tags, and allergens its ingredient names suggest,
/// set against the household list. Wording only ever repeats what the recipe
/// says or suggests; it never says a dish is free of an allergen or safe to
/// eat, and when the app finds no match it says that rules nothing out.
class PreviewAllergens {
  PreviewAllergens(
    Recipe recipe,
    Set<String> household, {
    List<ReviewedSubstitution> swaps = const [],
  }) : mentioned = recipeAllergens(recipe),
       household = household.toList()..sort() {
    final saved = {for (final a in household) _normalizeAllergen(a)};
    householdMatches = [
      for (final a in mentioned)
        if (saved.contains(_normalizeAllergen(a.name))) a,
    ];
    final tagged = {for (final a in mentioned) _normalizeAllergen(a.name)};
    nameHints = [
      for (final a in previewAllergenHints(recipe))
        if (!tagged.contains(_normalizeAllergen(a))) a,
    ];
    householdHints = [
      for (final a in nameHints)
        if (saved.contains(_normalizeAllergen(a))) a,
    ];
    swapAllergens = [
      for (final sub in swaps)
        if (previewSwapAllergens(sub) case final found when found.isNotEmpty)
          (swap: sub.substitute, allergens: found),
    ];
    householdSwapHits = [
      for (final s in swapAllergens)
        for (final a in s.allergens)
          if (saved.contains(_normalizeAllergen(a)))
            (swap: s.swap, allergen: a),
    ];
  }

  /// Allergens suggested by the reviewed swaps the cook confirmed.
  late final List<({String swap, List<String> allergens})> swapAllergens;

  /// [swapAllergens] on the household list.
  late final List<({String swap, String allergen})> householdSwapHits;

  /// Each confirmed swap that suggests an allergen, named so the cook can
  /// tell which warning comes from the swap, or null when none does.
  String? get swapLine => swapAllergens.isEmpty
      ? null
      : [
          for (final s in swapAllergens)
            'Your reviewed swap, ${s.swap}, suggests '
                '${_list(s.allergens)} — check its label yourself.',
        ].join(' ');

  final List<RecipeAllergen> mentioned;
  final List<String> household;
  late final List<RecipeAllergen> householdMatches;

  /// Allergens the ingredient names suggest that the tags do not list.
  late final List<String> nameHints;

  /// [nameHints] on the household list.
  late final List<String> householdHints;

  bool get householdSaved => household.isNotEmpty;

  /// True when a household allergen is tagged or suggested by a name.
  bool get householdWarning =>
      householdMatches.isNotEmpty ||
      householdHints.isNotEmpty ||
      householdSwapHits.isNotEmpty;

  /// "The recipe mentions wheat and peanut — check labels yourself."
  String get mentionLine => mentioned.isEmpty
      ? 'The recipe doesn’t list any allergens — $kCheckLabelsYourself'
      : 'The recipe mentions ${_list([for (final a in mentioned) a.label])} '
            '— $kCheckLabelsYourself';

  /// Names that suggest an untagged allergen, or null.
  String? get hintLine => nameHints.isEmpty
      ? null
      : 'Ingredient names suggest ${_list(nameHints)}, which the recipe’s '
            'allergen list doesn’t include — check the ingredients and '
            'labels yourself.';

  /// The household comparison, or null when nothing is saved.
  String? get householdLine {
    if (!householdSaved) return null;
    if (householdMatches.isNotEmpty) {
      final names = _list([for (final a in householdMatches) a.name]);
      final verb = householdMatches.length == 1 ? 'is' : 'are';
      return 'The recipe mentions $names, which $verb on your household list '
          '— $kCheckLabelsYourself';
    }
    if (householdHints.isNotEmpty) {
      final names = _list(householdHints);
      final verb = householdHints.length == 1 ? 'is' : 'are';
      return 'An ingredient name suggests $names, which $verb on your '
          'household list — check the ingredients and labels yourself.';
    }
    if (householdSwapHits.isNotEmpty) {
      final names = _list(
        {for (final h in householdSwapHits) h.allergen}.toList(),
      );
      final swaps = _list({for (final h in householdSwapHits) h.swap}.toList());
      final verb = names.contains(' and ') ? 'are' : 'is';
      return 'Your reviewed swap ($swaps) suggests $names, which $verb on '
          'your household list — check its label yourself.';
    }
    return 'The app found no match for your household allergens '
        '(${_list(household)}) in this recipe. That doesn’t rule them out — '
        'check the ingredients and labels yourself.';
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
       allergens = PreviewAllergens(
         recipe,
         household,
         swaps: [
           for (final s in previewIngredients(
             recipe,
             confirmedItems,
             pantryChecked: pantryChecked,
           ).substituted)
             s.substitution,
         ],
       ),
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

/// The exact Coach Lite question behind a "Find a swap" tap. It quotes the
/// ingredient's full display name, so a qualifier that names the food
/// ("Milk (coconut)") is never lost.
String swapQuestion(Ingredient ingredient, Recipe recipe) =>
    'What can I use instead of "${ingredient.name.trim()}" in '
    '${recipe.title.trim()}?';
