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

import 'dart:convert';

import '../ai/hybrid/payload_digest.dart' show sha256Hex;
import '../core/models.dart';
import '../pantry/recipe_draft_client.dart'
    show kHeatDisclaimer, kThermometerDisclaimer;

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

// Meat, poultry, fish, seafood and eggs, singular or plural. Deliberately
// broad: a false match only means no picture.
final _risky = RegExp(
  r'\b(?:meats?|poultry|chickens?|turkeys?|ducks?|goose|geese|quails?|'
  r'hens?|beef|steaks?|pork|bacon|hams?|lamb|mutton|veal|venison|goat|'
  r'sausages?|chorizo|salami|pepperoni|prosciutto|pancetta|burgers?|'
  r'patty|patties|meatballs?|ribs?|brisket|tenderloin|loin|'
  r'cutlets?|fillets?|filets?|thighs?|breasts?|drumsticks?|wings?|'
  r'hot ?dogs?|jerky|fish|fishes|salmon|tuna|cod|trout|tilapia|halibut|'
  r'haddock|snapper|bass|catfish|mackerel|sardines?|anchovy|anchovies|'
  r'swordfish|pollock|perch|carp|herring|mahi(?:[- ]mahi)?|seafood|'
  r'shellfish|shrimps?|prawns?|crabs?|lobsters?|scallops?|clams?|mussels?|'
  r'oysters?|squid|calamari|octopus|crawfish|crayfish|hake|pollack|sole|'
  r'flounder|plaice|monkfish|bream|turbot|whiting|eels?|roe|caviar|lox|'
  r'kippers?|eggs?|yolks?|'
  r'whites? of|omelet(?:te)?s?|frittatas?|quiches?|rabbits?|hares?|boar|'
  r'bison|elk|pheasants?|squab|partridges?|grouse|frogs?|snails?|'
  r'escargots?|offal|liver|kidneys?|tripe|sweetbreads?|tartare|carpaccio|'
  r'ceviche|sashimi|sushi|poke)\b',
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
  r'poached|sear|seared|searing|browned|browning|char|charred|smoke|'
  r'smoked|braise|braised|stew|stewed|blanch|blanched|caramelize|'
  r'caramelized|barbecue|bbq|air[- ]fry|deep[- ]fry|stir[- ]fry|reheat|'
  r'melt|melted|brown(?=\s+(?:the|it|them|on|in)\b))\b',
  caseSensitive: false,
);

/// Sentences that claim safety or doneness never reach a prompt.
final _safetySentence = RegExp(
  r'thermometer|food safety|safe to eat|doneness|cooked through|'
  r'internal temp|camera (?:can|cannot|can.t|will)',
  caseSensitive: false,
);

/// Doneness assertions. Their presence means a picture could be read as a
/// doneness reference, so the builder abstains rather than strip them.
final _doneness = RegExp(
  r'fully cooked|cooked through|until (?:it is |they are )?done|'
  r'\b(?:is|are|it.s|when) done\b|done when|doneness|opaque|'
  r'flakes? (?:easily|with a fork)|juices? run clear|no longer pink|'
  r'set in the (?:centre|center|middle)|firm to the touch|'
  r'internal temp|\bsafe(?:ly)?\b|\breach(?:es|ed)?\b|\d+ ?°|°|'
  r'\bdegrees\b|temperature',
  caseSensitive: false,
);

/// Allergen tags that mean fish, shellfish or eggs.
const _proteinAllergens = {
  'fish',
  'shellfish',
  'crustacean',
  'crustaceans',
  'mollusc',
  'molluscs',
  'mollusk',
  'mollusks',
  'egg',
  'eggs',
};

/// Whether [text] mentions meat, poultry, fish or eggs.
bool mentionsAnimalProtein(String text) => _risky.hasMatch(text);

/// Whether [text] asserts doneness ("fully cooked when golden"). The
/// drafter's own camera and thermometer notes are not assertions, so they
/// are ignored here (they still mark the step as heated or risky).
bool assertsDoneness(String text) => _doneness.hasMatch(
  text.replaceAll(kHeatDisclaimer, '').replaceAll(kThermometerDisclaimer, ''),
);

/// Whether [text] describes a step that uses heat.
bool mentionsHeat(String text) => _heat.hasMatch(text);

String _stepText(RecipeStep step) =>
    '${step.title} ${step.instruction} ${step.cue}';

/// The only products whose fish, shellfish or egg allergen tag is exempt in
/// the reviewed-recipe builder: identified shelf-stable products, matched
/// against the complete name (qualifiers included). A composite such as
/// "langoustines in garlic sauce" or an unknown tagged food (hake,
/// gravlax) is protein; abstaining is the cautious answer.
final _shelfStableProduct = RegExp(
  r'^(?:mayo|mayonnaise|(?:prepared |store[- ]bought )?mayonnaise|'
  r'worcestershire sauce|bread|crackers?)$',
  caseSensitive: false,
);

/// Whether [ingredient] is meat, poultry, fish, shellfish or egg: by its
/// name, or by a fish, shellfish or egg allergen tag unless it is an
/// identified shelf-stable product.
bool isAnimalProtein(Ingredient ingredient) =>
    mentionsAnimalProtein(ingredient.name) ||
    (ingredient.allergens.any(
          (a) => _proteinAllergens.contains(a.trim().toLowerCase()),
        ) &&
        !_shelfStableProduct.hasMatch(ingredient.name.trim()));

/// Whether the recipe has meat, poultry, fish or eggs anywhere: an
/// ingredient's name or allergen tags, any step's text, or a step that
/// carries the drafter's thermometer note (heat plus a risky food).
bool recipeHasAnimalProtein(Recipe recipe) =>
    recipe.ingredients.any(isAnimalProtein) ||
    recipe.steps.any(
      (s) =>
          mentionsAnimalProtein(_stepText(s)) ||
          s.cue.contains(kThermometerDisclaimer),
    );

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

/// Spelling variants a step may use for an ingredient word.
const _aliases = <String, List<String>>{
  'mayonnaise': ['mayo'],
};

/// The whole-word forms of [word]: itself, its singular and plural.
Iterable<String> _forms(String word) sync* {
  yield word;
  if (word.endsWith('oes')) yield word.substring(0, word.length - 2);
  if (word.endsWith('s') && word.length > 3) {
    yield word.substring(0, word.length - 1);
  } else {
    yield '${word}s';
    yield '${word}es';
  }
  yield* _aliases[word] ?? const [];
}

/// Whether [text] names [ingredient]: one of its significant words as a
/// whole word (singular, plural or a listed alias). "salt" never matches
/// "saltines"; an uncertain match is no match.
bool _names(String text, Ingredient ingredient) {
  final lower = text.toLowerCase();
  for (final word in ingredientForPrompt(
    ingredient.name,
  ).toLowerCase().split(RegExp('[^a-z]+'))) {
    if (word.length < 3 || _notIngredientWords.contains(word)) continue;
    for (final form in _forms(word)) {
      if (RegExp('\\b${RegExp.escape(form)}\\b').hasMatch(lower)) return true;
    }
  }
  return false;
}

bool _named(Ingredient i, RecipeStep s) => _names(_stepText(s), i);

/// The ingredients a step names, and those earlier steps named: a picture
/// of one step should not show what comes later. Nothing is guessed: a step
/// that names no ingredient gets no ingredient list.
({List<Ingredient> now, List<Ingredient> earlier}) _stepIngredients(
  Recipe recipe,
  int index,
) {
  final now = [
    for (final i in recipe.ingredients)
      if (_named(i, recipe.steps[index])) i,
  ];
  final earlier = [
    for (final i in recipe.ingredients)
      if (!now.contains(i) && recipe.steps.take(index).any((s) => _named(i, s)))
        i,
  ];
  return (now: now, earlier: earlier);
}

/// Whether [index] touches meat, poultry, fish or eggs: by its own words or
/// by an ingredient it names.
bool _touchesProtein(Recipe recipe, int index) {
  final step = recipe.steps[index];
  return mentionsAnimalProtein(_stepText(step)) ||
      step.cue.contains(kThermometerDisclaimer) ||
      recipe.ingredients.any((i) => isAnimalProtein(i) && _named(i, step));
}

/// The drawing style every prompt ends with.
const kIllustrationStyle =
    'Style: a clean, friendly instructional food illustration for a home '
    'cooking app, clearly drawn and not photorealistic. Soft natural light, '
    'plain kitchen counter, overhead or three-quarter view. No people, no '
    'hands, no text, no labels, no logos, no brand names, no packaging.';

/// The prompt for [target] in [recipe], or null when there must be no
/// picture.
///
/// For a recipe with meat, poultry, fish or eggs anywhere, the builder only
/// draws what cannot imply doneness: steps before the first step that heats
/// or touches the protein look as usual; a step that touches the protein
/// before any heat gets its ingredients laid out, uncooked; every other step
/// and the finished plate get no picture. Otherwise there is no picture for
/// an unknown step or a step without a visible cue.
IllustrationPrompt? illustrationPrompt(
  Recipe recipe,
  IllustrationTarget target,
) {
  final protein = recipeHasAnimalProtein(recipe);
  switch (target) {
    case PlateTarget():
      if (protein || recipe.steps.any((s) => assertsDoneness(_stepText(s)))) {
        return null;
      }
      return IllustrationPrompt(
        target: target,
        subject: IllustrationSubject.finishedPlate,
        heated: recipe.steps.any(
          (s) => mentionsHeat(_stepText(s)) || s.cue.contains(kHeatDisclaimer),
        ),
        text:
            'Show the finished dish, "${recipe.title}", served on a plate or '
            'in a bowl and ready to eat. Ingredients: '
            '${_ingredients(recipe.ingredients)}. $kIllustrationStyle',
      );
    case StepTarget(:final stepId):
      final index = recipe.steps.indexWhere((s) => s.id == stepId);
      if (index < 0) return null;
      final step = recipe.steps[index];
      final used = _stepIngredients(recipe, index);
      // A doneness assertion anywhere in the step means no picture at all.
      if (assertsDoneness(_stepText(step))) return null;
      // The drafter's heat notes count as heat, so the panel keeps the
      // thermometer note beside any picture of this step.
      final heated =
          mentionsHeat(_stepText(step)) ||
          step.cue.contains(kHeatDisclaimer) ||
          step.cue.contains(kThermometerDisclaimer);
      if (protein) {
        bool heats(int i) {
          final s = recipe.steps[i];
          return mentionsHeat(_stepText(s)) ||
              s.cue.contains(kHeatDisclaimer) ||
              s.cue.contains(kThermometerDisclaimer);
        }

        final firstRisk = [
          for (var i = 0; i < recipe.steps.length; i++)
            if (heats(i) || _touchesProtein(recipe, i)) i,
        ].firstOrNull;
        if (firstRisk != null && index >= firstRisk) {
          final heatSoFar = [for (var i = 0; i <= index; i++) i].any(heats);
          if (!_touchesProtein(recipe, index) ||
              heatSoFar ||
              used.now.isEmpty) {
            return null;
          }
          return IllustrationPrompt(
            target: target,
            subject: IllustrationSubject.ingredientsLaidOut,
            heated: heated,
            text:
                'Show these ingredients laid out separately on a cutting '
                'board before any cooking, each in its own small pile or '
                'bowl: ${_ingredients(used.now)}. Show no cooked food and no '
                'finished dish. $kIllustrationStyle',
          );
        }
      }
      final cue = visibleCue(step.cue);
      if (cue.isEmpty) return null;
      final now = _ingredients(used.now);
      final earlier = _ingredients(used.earlier);
      return IllustrationPrompt(
        target: target,
        subject: IllustrationSubject.stepLook,
        heated: heated,
        text:
            'Show what the food should look like at this point: $cue'
            '${now.isEmpty ? '' : ' Ingredients in this step: $now.'}'
            '${earlier.isEmpty ? '' : ' Prepared in earlier steps, and '
                      'shown only where the description above includes '
                      'them: $earlier.'}'
            ' Show nothing from later steps. $kIllustrationStyle',
      );
  }
}

/// A digest of everything an illustration prompt can depend on. Pending
/// work and cached images belong to one revision; a recipe edited in place
/// (same ids, new cue or ingredients) is a new revision.
String illustrationRevision(Recipe recipe) => sha256Hex(
  utf8.encode(
    jsonEncode({
      'id': recipe.id,
      'title': recipe.title,
      'ingredients': [
        for (final i in recipe.ingredients) [i.id, i.name, i.allergens],
      ],
      'steps': [
        for (final s in recipe.steps) [s.id, s.title, s.instruction, s.cue],
      ],
    }),
  ),
);

/// Shown wherever an AI-drafted recipe gets no on-demand picture.
const kIllustrationNotOfferedCopy =
    "No picture for this step: looks can't tell you if food is safe.";

// Anything that may involve heat, broadly. Over-blocking only costs a
// picture.
final _anyHeat = RegExp(
  r'\b(?:cook\w*|bak\w*|roast\w*|fr(?:y|ies|ied|ying)|saut\w*|simmer\w*|'
  r'boil\w*|grill\w*|toast\w*|warm\w*|heat\w*|hot|microwav\w*|oven\w*|'
  r'pans?|skillet\w*|stove\w*|hob|burners?|steam\w*|poach\w*|broil\w*|'
  r'sear\w*|char\w*|smok\w*|brais\w*|stew\w*|blanch\w*|caramel\w*|'
  r'barbecue\w*|bbq|griddle\w*|wok|melt\w*|scald\w*|reheat\w*|'
  r'air[- ]?fr\w*|torch\w*|flame\w*|bring to)\b',
  caseSensitive: false,
);

/// The allowlist's protein test for AI drafts: any meat, poultry, fish,
/// shellfish, egg or game word in an ingredient or step, any fish,
/// shellfish or egg allergen tag (no exemptions), or the drafter's
/// thermometer note.
bool draftHasAnimalProtein(Recipe recipe) =>
    recipe.ingredients.any(
      (i) =>
          mentionsAnimalProtein(i.name) ||
          i.allergens.any(
            (a) => _proteinAllergens.contains(a.trim().toLowerCase()),
          ),
    ) ||
    recipe.steps.any(
      (s) =>
          mentionsAnimalProtein(_stepText(s)) ||
          s.cue.contains(kThermometerDisclaimer),
    );

bool _mayHeat(RecipeStep s) =>
    _anyHeat.hasMatch(_stepText(s)) ||
    s.cue.contains(kHeatDisclaimer) ||
    s.cue.contains(kThermometerDisclaimer);

/// The on-demand prompt for an AI-drafted recipe, by allowlist: a picture
/// is offered only when nothing about it could be read as doneness or
/// safety.
///
/// - Step: the step involves no heat, makes no doneness, temperature or
///   safety claim, and the whole recipe has no animal protein. The prompt
///   carries only the step's visible cue and the ingredients that step
///   names.
/// - Plate: the whole recipe is no-cook, makes no such claim, and has no
///   animal protein. The prompt carries the dish's name and ingredients.
///
/// Anything else returns null: the cook sees [kIllustrationNotOfferedCopy].
IllustrationPrompt? onDemandIllustrationPrompt(
  Recipe recipe,
  IllustrationTarget target,
) {
  if (draftHasAnimalProtein(recipe)) return null;
  switch (target) {
    case PlateTarget():
      if (_anyHeat.hasMatch(recipe.title) ||
          recipe.steps.any(_mayHeat) ||
          recipe.steps.any((s) => assertsDoneness(_stepText(s)))) {
        return null;
      }
      return IllustrationPrompt(
        target: target,
        subject: IllustrationSubject.finishedPlate,
        heated: false,
        text:
            'Show the finished dish, "${recipe.title}", served on a plate or '
            'in a bowl and ready to eat. Ingredients: '
            '${_ingredients(recipe.ingredients)}. $kIllustrationStyle',
      );
    case StepTarget(:final stepId):
      final index = recipe.steps.indexWhere((s) => s.id == stepId);
      if (index < 0) return null;
      final step = recipe.steps[index];
      if (_mayHeat(step) || assertsDoneness(_stepText(step))) return null;
      final cue = visibleCue(step.cue);
      if (cue.isEmpty) return null;
      final now = _ingredients([
        for (final i in recipe.ingredients)
          if (_named(i, step)) i,
      ]);
      return IllustrationPrompt(
        target: target,
        subject: IllustrationSubject.stepLook,
        heated: false,
        text:
            'Show what the food should look like at this point: $cue'
            '${now.isEmpty ? '' : ' Ingredients in this step: $now.'}'
            ' Show nothing from other steps. $kIllustrationStyle',
      );
  }
}
