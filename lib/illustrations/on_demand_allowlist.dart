// On-demand illustration eligibility for AI-drafted recipes (SS-098), by
// allowlist at every level. Nothing is pictured unless the builder can
// positively establish that it is safe to show:
//
// - every ingredient's full name is made only of known plant-based or
//   shelf-stable food words (plus measurement and filler words), and no
//   ingredient carries a fish, shellfish or egg allergen tag;
// - every word of the step's title and instruction is a known no-heat
//   preparation verb, a word of this recipe's ingredients, a kitchen noun or
//   a filler word: an unfamiliar method ("sous vide", "cure") means no image;
// - no cue, title, instruction or ingredient name that would enter the
//   prompt makes a doneness, temperature or safety claim, mentions heat or
//   names an animal protein.
//
// The payload is the step's visible cue and the ingredients the step names
// exactly; the plate's payload is its ingredient list. Never the title.
// Over-blocking is accepted: a missing picture costs nothing.

import '../core/models.dart';
import '../pantry/recipe_draft_client.dart'
    show kHeatDisclaimer, kThermometerDisclaimer;
import 'illustration_prompts.dart';

/// Shown wherever an AI-drafted recipe gets no on-demand picture.
const kIllustrationNotOfferedCopy =
    "No picture for this step: looks can't tell you if food is safe.";

/// Plant-based and shelf-stable food words.
const _foods = {
  // Vegetables.
  'carrot', 'onion', 'shallot', 'scallion', 'leek', 'garlic', 'ginger',
  'celery', 'cucumber', 'tomato', 'potato', 'pepper', 'bell', 'chili',
  'chile', 'chilli', 'jalapeno', 'lettuce', 'spinach', 'kale', 'cabbage',
  'arugula', 'rocket', 'broccoli', 'cauliflower', 'zucchini', 'courgette',
  'squash', 'radish', 'beet', 'beetroot', 'corn', 'pea', 'bean', 'sprout',
  'mushroom', 'avocado', 'olive', 'asparagus', 'fennel', 'endive', 'romaine',
  'greens', 'salad', 'vegetable', 'veggie', 'slaw', 'jicama',
  // Herbs and spices.
  'parsley', 'cilantro', 'coriander', 'basil', 'mint', 'dill', 'chive',
  'thyme', 'rosemary', 'oregano', 'sage', 'tarragon', 'herb', 'cumin',
  'paprika', 'turmeric', 'cinnamon', 'nutmeg', 'cardamom', 'clove',
  'spice', 'powder', 'flake', 'seasoning', 'salt', 'peppercorn', 'mustard',
  'vanilla', 'sumac', 'zaatar',
  // Fruit.
  'apple', 'banana', 'berry', 'strawberry', 'blueberry', 'raspberry',
  'blackberry', 'lemon', 'lime', 'orange', 'grapefruit', 'mango',
  'pineapple', 'peach', 'pear', 'grape', 'melon', 'watermelon', 'kiwi',
  'cherry', 'date', 'fig', 'raisin', 'cranberry', 'pomegranate', 'coconut',
  'fruit', 'juice', 'zest', 'apricot', 'plum', 'nectarine', 'papaya',
  // Grains and bread.
  'oat', 'rice', 'quinoa', 'couscous', 'bulgur', 'flour', 'bread',
  'tortilla', 'pita', 'wrap', 'cracker', 'chip', 'cereal', 'granola',
  'bun', 'roll', 'bagel', 'baguette', 'flatbread', 'naan', 'toast',
  // Legumes, nuts, seeds and plant proteins.
  'chickpea', 'lentil', 'edamame', 'hummus', 'tofu', 'tempeh', 'almond',
  'walnut', 'peanut', 'cashew', 'pecan', 'pistachio', 'hazelnut', 'nut',
  'sesame', 'sunflower', 'pumpkin', 'chia', 'flax', 'flaxseed', 'hemp',
  'seed', 'tahini',
  // Oils, vinegars, condiments and pantry.
  'oil', 'vinegar', 'balsamic', 'soy', 'tamari', 'ketchup', 'salsa',
  'sugar', 'syrup', 'maple', 'agave', 'jam', 'preserves', 'marmalade',
  'water', 'ice', 'cocoa', 'chocolate', 'molasses', 'pickle',
  // Plant milks and nut butters (only with a plant word, see below).
  'milk', 'butter',
};

/// "milk" and "butter" are allowed only after one of these.
const _plantQualifiers = {
  'almond',
  'oat',
  'soy',
  'coconut',
  'rice',
  'cashew',
  'peanut',
  'nut',
  'sunflower',
  'apple',
  'hemp',
  'pea',
};

/// Words that describe, measure or fill out a name but name no food.
const _fillers = {
  'a',
  'an',
  'and',
  'or',
  'of',
  'for',
  'to',
  'the',
  'with',
  'in',
  'on',
  'if',
  'you',
  'like',
  'it',
  'only',
  'optional',
  'taste',
  'serving',
  'check',
  'labels',
  'label',
  'contain',
  'contains',
  'about',
  'some',
  'any',
  'fresh',
  'chopped',
  'diced',
  'sliced',
  'minced',
  'grated',
  'shredded',
  'canned',
  'drained',
  'rinsed',
  'dried',
  'frozen',
  'whole',
  'large',
  'small',
  'medium',
  'ripe',
  'peeled',
  'seeded',
  'cored',
  'halved',
  'quartered',
  'cubed',
  'crushed',
  'ground',
  'plain',
  'unsalted',
  'salted',
  'sweet',
  'red',
  'green',
  'yellow',
  'white',
  'black',
  'purple',
  'baby',
  'extra',
  'virgin',
  'pre',
  'cut',
  'thinly',
  'finely',
  'roughly',
  'bottled',
  'store',
  'bought',
  'inch',
  'leaves',
  'leaf',
  'sprig',
  'stalk',
  'head',
  'bunch',
  'can',
  'jar',
  'pinch',
  'handful',
  'piece',
  'kernel',
  'floret',
  'cup',
  'tbsp',
  'tsp',
  'tablespoon',
  'teaspoon',
  'g',
  'kg',
  'ml',
  'oz',
  'lb',
  'clove',
  'wedge',
  'stick',
  'mixed',
  'flat',
  'curly',
  'english',
  'roma',
  'cherry',
  'granulated',
  'brown',
  'kosher',
  'sea',
  'flaky',
  'fine',
  'coarse',
  'light',
  'dark',
  'low',
  'sodium',
  'unsweetened',
  'natural',
  'smooth',
  'crunchy',
  'creamy',
  'firm',
  'soft',
  'shelled',
  'raw',
};

/// No-heat preparation verbs.
const _noHeatVerbs = {
  'chop', 'slice', 'dice', 'mince', 'grate', 'mix', 'stir', 'toss', 'mash',
  'spread', 'fold', 'assemble', 'arrange', 'rinse', 'drain', 'peel',
  'squeeze', 'layer', 'roll', 'wrap', 'serve', 'season',
  // Neutral handling with no heat.
  'add', 'put', 'place', 'combine', 'cut', 'set', 'lay', 'top', 'sprinkle',
  'pour', 'spoon', 'scoop', 'halve', 'quarter', 'cube', 'pit', 'core',
  'zest', 'juice', 'whisk', 'blend', 'measure', 'let', 'sit', 'taste',
  'adjust', 'cover', 'chill', 'refrigerate', 'soak', 'pat', 'dry', 'shake',
  'press', 'crush', 'smash', 'tear', 'pick', 'trim', 'wash', 'open', 'tip',
  'shred', 'divide', 'transfer', 'drizzle', 'dress', 'garnish', 'line',
  'fill', 'close', 'turn', 'leave', 'keep', 'use', 'break', 'separate',
  'scatter', 'stack', 'tuck', 'pile', 'mound', 'swirl', 'dollop', 'dip',
  'remove', 'discard', 'reserve', 'gather', 'wipe', 'rub', 'coat', 'massage',
};

/// Kitchen nouns and step filler that name no food and no method.
const _stepWords = {
  'step',
  'go',
  'goes',
  'get',
  'make',
  'bowl',
  'board',
  'plate',
  'platter',
  'knife',
  'fork',
  'spoon',
  'cup',
  'jar',
  'colander',
  'sieve',
  'strainer',
  'grater',
  'tray',
  'dish',
  'side',
  'top',
  'bottom',
  'edge',
  'center',
  'centre',
  'middle',
  'layer',
  'half',
  'halves',
  'piece',
  'bit',
  'chunk',
  'strip',
  'round',
  'line',
  'row',
  'end',
  'it',
  'them',
  'they',
  'this',
  'that',
  'these',
  'those',
  'each',
  'all',
  'some',
  'most',
  'more',
  'less',
  'few',
  'until',
  'then',
  'and',
  'or',
  'with',
  'into',
  'onto',
  'over',
  'under',
  'from',
  'to',
  'in',
  'on',
  'of',
  'a',
  'an',
  'the',
  'your',
  'you',
  'if',
  'as',
  'at',
  'by',
  'for',
  'up',
  'out',
  'off',
  'together',
  'evenly',
  'gently',
  'well',
  'lightly',
  'finely',
  'roughly',
  'thinly',
  'small',
  'large',
  'even',
  'little',
  'bite',
  'size',
  'sized',
  'minute',
  'minutes',
  'second',
  'seconds',
  'about',
  'any',
  'one',
  'two',
  'three',
  'four',
  'other',
  'remaining',
  'rest',
  'mixture',
  'filling',
  'dressing',
  'sandwich',
  'salad',
  'hand',
  'hands',
  'surface',
  'counter',
  'paper',
  'towel',
  'lid',
  'wrap',
  'container',
  'fridge',
  'refrigerator',
  'ready',
  'want',
  'like',
  'prefer',
  'is',
  'are',
  'be',
  'not',
  'no',
  'so',
  'just',
  'still',
  'again',
  'once',
  'everything',
  'everyone',
  'what',
  'have',
  'has',
  'can',
  'will',
  'would',
  'should',
  'may',
  'might',
  'do',
  'does',
  'don',
  't',
  'its',
  'their',
  'very',
  'too',
  'also',
  'plus',
  'whichever',
  'such',
  'than',
  'loose',
  'tight',
  'neat',
  'flat',
  'upright',
  'aside',
  'away',
  'back',
  'down',
  'through',
  'across',
  'around',
  'between',
  'along',
  'lower',
  'upper',
  'third',
  'sides',
};

/// Singular, lower-case form of [word] ("tomatoes" → "tomato").
String _singular(String word) {
  if (word.length > 4 && word.endsWith('ies')) {
    return '${word.substring(0, word.length - 3)}y';
  }
  if (word.length > 3 && word.endsWith('oes')) {
    return word.substring(0, word.length - 2);
  }
  if (word.length > 3 && word.endsWith('es') && !word.endsWith('ses')) {
    final stem = word.substring(0, word.length - 2);
    if (_foods.contains(stem) || _noHeatVerbs.contains(stem)) return stem;
  }
  if (word.length > 2 && word.endsWith('s') && !word.endsWith('ss')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

/// A verb's base form for common inflections ("chopped" → "chop").
Iterable<String> _verbForms(String word) sync* {
  yield word;
  yield _singular(word);
  for (final suffix in ['ing', 'ed', 'd']) {
    if (word.length > suffix.length + 2 && word.endsWith(suffix)) {
      final stem = word.substring(0, word.length - suffix.length);
      yield stem;
      yield '${stem}e';
      // Doubled final consonant: "chopped" → "chop".
      if (stem.length > 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
        yield stem.substring(0, stem.length - 1);
      }
    }
  }
}

List<String> _words(String text) => [
  for (final w in text.toLowerCase().split(RegExp(r"[^a-z']+")))
    if (w.isNotEmpty) w.replaceAll("'", ''),
];

/// Whether [ingredient]'s complete name (qualifiers in brackets included)
/// is made only of known plant-based or shelf-stable food words, and it
/// carries no fish, shellfish or egg tag.
bool isAllowlistedIngredient(Ingredient ingredient) {
  if (ingredient.allergens.any(
    (a) => proteinAllergenTags.contains(a.trim().toLowerCase()),
  )) {
    return false;
  }
  final name = ingredient.name;
  if (mentionsAnimalProtein(name) || assertsDoneness(name)) return false;
  final words = _words(name).map(_singular).toList();
  var foods = 0;
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (w == 'milk' || w == 'butter') {
      final before = i > 0 ? words[i - 1] : '';
      if (!_plantQualifiers.contains(before)) return false;
      foods++;
      continue;
    }
    if (_foods.contains(w)) {
      foods++;
      continue;
    }
    if (_fillers.contains(w)) continue;
    return false; // an unknown word: cannot establish it is safe
  }
  return foods > 0;
}

/// The words of [step]'s title and instruction that are not a known no-heat
/// verb, a word of [recipe]'s ingredients, a kitchen noun or a filler.
List<String> unknownStepWords(Recipe recipe, RecipeStep step) {
  final ingredientWords = {
    for (final i in recipe.ingredients)
      for (final w in _words(i.name)) _singular(w),
  };
  bool known(String word) =>
      RegExp(r'^\d').hasMatch(word) ||
      _verbForms(word).any(_noHeatVerbs.contains) ||
      ingredientWords.contains(_singular(word)) ||
      _foods.contains(_singular(word)) ||
      _stepWords.contains(word) ||
      _stepWords.contains(_singular(word)) ||
      _fillers.contains(word) ||
      _fillers.contains(_singular(word));
  return [
    for (final word in _words('${step.title} ${step.instruction}'))
      if (!known(word)) word,
  ];
}

/// Whether [step] is an allowlisted no-heat preparation: no doneness or
/// protein words, and no unknown word (an unfamiliar method means no).
bool isNoHeatStep(Recipe recipe, RecipeStep step) {
  final text = '${step.title} ${step.instruction}';
  if (assertsDoneness(text) || mentionsAnimalProtein(text)) return false;
  if (mentionsAnyHeat(text)) return false;
  return unknownStepWords(recipe, step).isEmpty;
}

/// The phrase an ingredient is known by: its name before any comma, with
/// brackets and preparation words removed ("Red bell pepper, diced" →
/// "red bell pepper").
String _keyPhrase(Ingredient ingredient) {
  final head = ingredientForPrompt(ingredient.name).split(',').first;
  const prep = {
    'fresh',
    'chopped',
    'diced',
    'sliced',
    'minced',
    'grated',
    'shredded',
    'canned',
    'drained',
    'rinsed',
    'dried',
    'frozen',
    'whole',
    'large',
    'small',
    'medium',
    'ripe',
    'peeled',
    'seeded',
    'raw',
    'plain',
  };
  return _words(head).where((w) => !prep.contains(w)).join(' ');
}

/// The ingredients [step] names exactly. An ingredient counts when the step
/// contains its key phrase, or a shorter ending of it that no other
/// ingredient's key phrase shares ("bell pepper" for "red bell pepper",
/// while "pepper" alone is ambiguous next to "black pepper").
List<Ingredient> exactlyNamedIngredients(Recipe recipe, RecipeStep step) {
  final text = _words('${step.title} ${step.instruction} ${step.cue}')
      .map(_singular)
      .join(' ');
  final keys = {
    for (final i in recipe.ingredients)
      i: _words(_keyPhrase(i)).map(_singular).toList(),
  };
  bool contains(List<String> phrase) =>
      phrase.isNotEmpty &&
      RegExp('(^| )${RegExp.escape(phrase.join(' '))}( |\$)').hasMatch(text);
  bool shared(List<String> ending, Ingredient owner) => keys.entries.any(
    (e) =>
        e.key != owner &&
        RegExp('(^| )${RegExp.escape(ending.join(' '))}( |\$)')
            .hasMatch(e.value.join(' ')),
  );
  return [
    for (final MapEntry(key: ingredient, value: phrase) in keys.entries)
      if (contains(phrase) ||
          [
            for (var start = 1; start < phrase.length; start++)
              phrase.sublist(start),
          ].any((ending) => !shared(ending, ingredient) && contains(ending)))
        ingredient,
  ];
}

/// Readiness and browning claims a cue must never make for a picture.
final _cueClaims = RegExp(
  r'ready to (?:eat|serve)|\bdone\b|\bproves?\b|\bedible\b|\bgolden\b|'
  r'\bcrust\w*|\bcrisp\w*|\bbrown\w*|\bset\b|\bpink\b|\braw\b',
  caseSensitive: false,
);

bool _cueIsClean(String cue) =>
    !_cueClaims.hasMatch(cue) &&
    !assertsDoneness(cue) &&
    !mentionsAnimalProtein(cue) &&
    !mentionsAnyHeat(cue) &&
    !cue.contains('camera');

final _anyHeat = RegExp(
  r'\b(?:cook\w*|bak\w*|roast\w*|fr(?:y|ies|ied|ying)|saut\w*|simmer\w*|'
  r'boil\w*|grill\w*|toast(?:ed|ing|s)?|warm\w*|heat\w*|hot|microwav\w*|'
  r'oven\w*|pans?|skillet\w*|stove\w*|hob|burners?|steam\w*|poach\w*|'
  r'broil\w*|sear\w*|char\w*|smok\w*|brais\w*|stew\w*|blanch\w*|'
  r'caramel\w*|barbecue\w*|bbq|griddle\w*|wok|melt\w*|scald\w*|reheat\w*|'
  r'air[- ]?fr\w*|torch\w*|flame\w*|sous|vide|cure\w*|ferment\w*)\b',
  caseSensitive: false,
);

/// Whether [text] mentions any heat or non-trivial method, broadly.
bool mentionsAnyHeat(String text) => _anyHeat.hasMatch(text);

/// Whether the whole recipe passes the ingredient allowlist.
bool allIngredientsAllowlisted(Recipe recipe) =>
    recipe.ingredients.isNotEmpty &&
    recipe.ingredients.every(isAllowlistedIngredient);

/// The on-demand prompt for an AI-drafted recipe, or null when the
/// allowlist cannot establish that a picture is safe to show.
IllustrationPrompt? onDemandIllustrationPrompt(
  Recipe recipe,
  IllustrationTarget target,
) {
  if (!allIngredientsAllowlisted(recipe)) return null;
  // The drafter's heat or thermometer notes mean heat somewhere.
  if (recipe.steps.any(
    (s) =>
        s.cue.contains(kHeatDisclaimer) ||
        s.cue.contains(kThermometerDisclaimer),
  )) {
    return null;
  }
  switch (target) {
    case PlateTarget():
      // No-cook, all the way: every step is an allowlisted no-heat step
      // with a clean cue.
      if (recipe.steps.isEmpty ||
          !recipe.steps.every(
            (s) => isNoHeatStep(recipe, s) && _cueIsClean(s.cue),
          )) {
        return null;
      }
      return IllustrationPrompt(
        target: target,
        subject: IllustrationSubject.finishedPlate,
        heated: false,
        text:
            'Show a finished, no-cook dish served on a plate or in a bowl, '
            'made from: ${_list(recipe.ingredients)}. $kIllustrationStyle',
      );
    case StepTarget(:final stepId):
      final step = recipe.steps.where((s) => s.id == stepId).firstOrNull;
      if (step == null || !isNoHeatStep(recipe, step)) return null;
      if (!_cueIsClean(step.cue)) return null;
      final cue = visibleCue(step.cue);
      if (cue.isEmpty) return null;
      final named = exactlyNamedIngredients(recipe, step);
      return IllustrationPrompt(
        target: target,
        subject: IllustrationSubject.stepLook,
        heated: false,
        text:
            'Show what the food should look like at this point: $cue'
            '${named.isEmpty ? '' : ' Ingredients in this step: ${_list(named)}.'}'
            ' Show nothing from other steps. $kIllustrationStyle',
      );
  }
}

String _list(Iterable<Ingredient> list) => [
  for (final i in list)
    if (ingredientForPrompt(i.name) case final n when n.isNotEmpty) n,
].join('; ');
