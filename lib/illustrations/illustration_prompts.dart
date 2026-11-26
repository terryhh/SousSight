// What an illustration may show, and the prompt that asks for it (SS-098).
//
// Pure Dart, no I/O. The same builder writes the prompts for the pre-made
// set (tool/generate_illustrations.dart) and for on-demand requests, so both
// follow one rule: a prompt comes from the step's visible cue and the
// recipe's ingredients only, never from the cook's own words or photos.
//
// An illustration shows what food should LOOK like. It never stands in for
// doneness, temperature or safety, so a step that touches meat, poultry,
// fish or eggs gets no "done" picture: it gets the ingredients laid out
// before cooking instead, and a recipe with any of them gets no finished
// plate at all.

import '../core/models.dart';

/// Shown on every illustration, pre-made or on demand.
const kIllustrationLabel = 'AI illustration — not a photo of your food';

/// Shown under every illustration.
const kIllustrationCompareCopy =
    'Compare the look, not the safety. A picture cannot show doneness, '
    'temperature or whether food is safe to eat.';

/// Shown with an illustration of a step that uses heat. Matches the
/// cooking screen's existing camera disclaimer.
const kIllustrationHeatCopy =
    "Judge this yourself; neither this picture nor the camera can confirm "
    'doneness or food safety. Use a food thermometer for anything that must '
    'be cooked through.';

/// Shown instead of a "done" picture for meat, poultry, fish and eggs.
const kIllustrationNoDonenessCopy =
    'No "done" picture for meat, poultry, fish or eggs. Check doneness with '
    'a food thermometer; a picture or the camera cannot confirm it is safe.';

/// The ledger feature for every illustration request.
const kIllustrationFeature = 'step_illustration';

/// What an illustration is of.
sealed class IllustrationTarget {
  const IllustrationTarget();

  /// The session cache and asset key.
  String get key;
}

class StepTarget extends IllustrationTarget {
  const StepTarget(this.stepId);
  final String stepId;
  @override
  String get key => 'step_$stepId';
  @override
  bool operator ==(Object other) =>
      other is StepTarget && other.stepId == stepId;
  @override
  int get hashCode => Object.hash(StepTarget, stepId);
}

class PlateTarget extends IllustrationTarget {
  const PlateTarget();
  @override
  String get key => 'plate';
  @override
  bool operator ==(Object other) => other is PlateTarget;
  @override
  int get hashCode => (PlateTarget).hashCode;
}

enum IllustrationSubject {
  /// What the food should look like at the end of a step.
  stepLook,

  /// The step's ingredients laid out, uncooked: the non-doneness picture for
  /// meat, poultry, fish and egg steps.
  ingredientsLaidOut,

  /// The finished dish, plated.
  finishedPlate,
}

class IllustrationPrompt {
  const IllustrationPrompt({
    required this.target,
    required this.subject,
    required this.text,
    required this.heated,
  });
  final IllustrationTarget target;
  final IllustrationSubject subject;
  final String text;

  /// The step uses heat: the panel keeps the thermometer disclaimer.
  final bool heated;
}

final _risky = RegExp(
  r'\b(raw|meat|meats|poultry|chicken|turkey|duck|beef|steak|pork|bacon|ham|'
  r'lamb|sausages?|burgers?|patty|patties|mince|minced|fish|salmon|tuna|cod|'
  r'seafood|shrimp|prawns?|scallops?|clams?|mussels?|eggs?|yolks?|omelet(?:te)?)\b',
  caseSensitive: false,
);

final _heat = RegExp(
  // A bare "cook" is usually the person ("the cook's call"), so only the
  // verb form followed by what is cooked counts.
  r'\b(cook(?=\s+(?:until|for|the|it|them|on|over|in|gently)\b)|cooked|'
  r'cooking|bake|baked|baking|fry|fried|frying|'
  r'heat|heated|heating|oven|pan|skillet|boil|boiling|simmer|simmering|'
  r'roast|roasting|grill|grilling|microwave|saute|sauté|sautéed|scramble|'
  r'scrambled|toast|toasted|toasting|broil|broiled|steam|steamed|poach|'
  r'poached)\b',
  caseSensitive: false,
);

/// Sentences that claim safety or doneness never reach a prompt.
final _safetySentence = RegExp(
  r'thermometer|food safety|safe to eat|doneness|cooked through|'
  r'internal temp|camera (?:can|cannot|can.t|will)',
  caseSensitive: false,
);

/// Whether [text] mentions meat, poultry, fish or eggs.
bool mentionsAnimalProtein(String text) => _risky.hasMatch(text);

/// Whether [text] describes a step that uses heat.
bool mentionsHeat(String text) => _heat.hasMatch(text);

String _stepText(RecipeStep step) =>
    '${step.title} ${step.instruction} ${step.cue}';

/// Whether any ingredient is meat, poultry, fish or egg.
bool recipeHasAnimalProtein(Recipe recipe) =>
    recipe.ingredients.any((i) => mentionsAnimalProtein(i.name));

/// The cue without any safety or doneness sentence: an illustration is
/// never asked to depict one.
String visibleCue(String cue) {
  final sentences = cue
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && !_safetySentence.hasMatch(s));
  return sentences.join(' ');
}

/// An ingredient's name for a prompt: no notes in brackets, no "only if"
/// asides.
String ingredientForPrompt(String name) {
  var out = name.replaceAll(RegExp(r'\s*\([^)]*\)'), '');
  out = out.replaceAll(
    RegExp(r',?\s*(only if|if you|for serving)\b.*$', caseSensitive: false),
    '',
  );
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _ingredients(Iterable<Ingredient> list) => [
  for (final i in list)
    if (ingredientForPrompt(i.name) case final n when n.isNotEmpty) n,
].join('; ');

const _notIngredientWords = {
  'and',
  'the',
  'for',
  'with',
  'canned',
  'fresh',
  'drained',
  'rinsed',
  'diced',
  'sliced',
  'thinly',
  'finely',
  'chopped',
  'plain',
  'pre',
  'inch',
  'juice',
  'red',
  'black',
  'green',
  'white',
  'yellow',
  'purple',
};

/// Whether [text] names [ingredient]: any of its words, matched on the first
/// four letters so "mayo" finds "Mayonnaise" and "chickpeas" "chickpea".
bool _names(String text, Ingredient ingredient) {
  final lower = text.toLowerCase();
  for (final word in ingredientForPrompt(
    ingredient.name,
  ).toLowerCase().split(RegExp('[^a-z]+'))) {
    if (word.length < 3 || _notIngredientWords.contains(word)) continue;
    final stem = word.substring(0, word.length < 4 ? word.length : 4);
    if (RegExp('\\b$stem').hasMatch(lower)) return true;
  }
  return false;
}

/// The ingredients a step works with, and those earlier steps prepared:
/// a picture of one step should not show what comes later. When no step
/// names any ingredient, the whole list stands in.
({String now, String earlier}) _stepIngredients(Recipe recipe, int index) {
  bool named(Ingredient i, RecipeStep s) => _names(_stepText(s), i);
  final now = [
    for (final i in recipe.ingredients)
      if (named(i, recipe.steps[index])) i,
  ];
  final earlier = [
    for (final i in recipe.ingredients)
      if (!now.contains(i) && recipe.steps.take(index).any((s) => named(i, s)))
        i,
  ];
  if (now.isEmpty && earlier.isEmpty) {
    return (now: _ingredients(recipe.ingredients), earlier: '');
  }
  return (now: _ingredients(now), earlier: _ingredients(earlier));
}

const _style =
    'Style: a clean, friendly instructional food illustration for a home '
    'cooking app, clearly drawn and not photorealistic. Soft natural light, '
    'plain kitchen counter, overhead or three-quarter view. No people, no '
    'hands, no text, no labels, no logos, no brand names, no packaging.';

/// The prompt for [target] in [recipe], or null when there must be no
/// picture: an unknown step, a step with no visible cue, or the finished
/// plate of a recipe with meat, poultry, fish or eggs.
IllustrationPrompt? illustrationPrompt(
  Recipe recipe,
  IllustrationTarget target,
) {
  switch (target) {
    case PlateTarget():
      if (recipeHasAnimalProtein(recipe) ||
          recipe.steps.any((s) => mentionsAnimalProtein(_stepText(s)))) {
        return null;
      }
      return IllustrationPrompt(
        target: target,
        subject: IllustrationSubject.finishedPlate,
        heated: recipe.steps.any((s) => mentionsHeat(_stepText(s))),
        text:
            'Show the finished dish, "${recipe.title}", served on a plate or '
            'in a bowl and ready to eat. Ingredients: '
            '${_ingredients(recipe.ingredients)}. $_style',
      );
    case StepTarget(:final stepId):
      final index = recipe.steps.indexWhere((s) => s.id == stepId);
      if (index < 0) return null;
      final step = recipe.steps[index];
      final used = _stepIngredients(recipe, index);
      final heated = mentionsHeat(_stepText(step));
      if (mentionsAnimalProtein(_stepText(step))) {
        return IllustrationPrompt(
          target: target,
          subject: IllustrationSubject.ingredientsLaidOut,
          heated: heated,
          text:
              'Show these ingredients laid out separately on a cutting board '
              'before any cooking, each in its own small pile or bowl: '
              '${used.now}. Show no cooked food and no finished dish. $_style',
        );
      }
      final cue = visibleCue(step.cue);
      if (cue.isEmpty) return null;
      return IllustrationPrompt(
        target: target,
        subject: IllustrationSubject.stepLook,
        heated: heated,
        text:
            'Show what the food should look like at this point: $cue'
            '${used.now.isEmpty ? '' : ' Ingredients in this step: ${used.now}.'}'
            '${used.earlier.isEmpty ? '' : ' Prepared in earlier steps, and '
                      'shown only where the description above includes '
                      'them: ${used.earlier}.'}'
            ' Show nothing from later steps. $_style',
      );
  }
}
