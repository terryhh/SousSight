import '../app/services_scope.dart';
import '../core/models.dart';

/// What the cook confirmed on the pantry screen, carried into cooking.
class PantryHandoff {
  const PantryHandoff({this.confirmedItems = const [], this.answer});
  final List<String> confirmedItems;

  /// The pantry question and the cook's answer, if they gave one.
  final ({String question, String answer})? answer;

  bool get isEmpty => confirmedItems.isEmpty && answer == null;
}

const _ignoredWords = {
  'canned',
  'can',
  'fresh',
  'jar',
  'of',
  'and',
  'or',
  'a',
  'the',
  'some',
  'bag',
  'box',
  'loaf',
  'sliced',
  'diced',
  'dried',
  'whole',
  'for',
  'serving',
};

String _stem(String word) {
  if (word.endsWith('oes')) return word.substring(0, word.length - 2);
  if (word.endsWith('es') && word.length > 4 && !word.endsWith('ies')) {
    return word.endsWith('ses') || word.endsWith('ches')
        ? word.substring(0, word.length - 2)
        : word.substring(0, word.length - 1);
  }
  if (word.endsWith('s') && word.length > 3 && !word.endsWith('ss')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

Set<String> _words(String text) => {
  for (final word in text.toLowerCase().split(RegExp(r'[^a-z]+')))
    if (word.isNotEmpty && !_ignoredWords.contains(word)) _stem(word),
};

/// Maps a cook-confirmed pantry item to a recipe ingredient ID when every
/// meaningful word of the ingredient ID appears in the item name.
String? matchIngredientId(String item, Recipe recipe) {
  final itemWords = _words(item);
  if (itemWords.isEmpty) return null;
  for (final ingredient in recipe.ingredients) {
    final idWords = _words(ingredient.id.replaceAll('_', ' '));
    if (idWords.isNotEmpty && itemWords.containsAll(idWords)) {
      return ingredient.id;
    }
  }
  return null;
}

/// Writes pantry context into the cook's session before the cooking screen
/// opens, in a fresh session that the coordinator resumes as the newest one.
/// Matched items become `have` ingredients (never overriding a prior choice);
/// everything else is kept as a cook-confirmed fact, not a guess.
Future<void> applyPantryHandoff(
  AppServices services,
  Recipe recipe,
  PantryHandoff handoff,
) async {
  if (handoff.isEmpty) return;
  final uid = await services.auth.signInLearner();
  // A pantry scan is a new meal: start a fresh session (earlier sessions are
  // preserved) that the coordinator then resumes as the newest one.
  final session = await services.sessions.createNew(uid, recipe);
  final matched = {
    for (final item in handoff.confirmedItems) ?matchIngredientId(item, recipe),
  };
  final facts = [
    if (handoff.confirmedItems.isNotEmpty)
      'Pantry has (confirmed by the cook): ${handoff.confirmedItems.join(', ')}.',
    if (handoff.answer case final qa?)
      '${qa.question} Answer from cook: ${qa.answer}',
  ];
  await services.sessions.update(session.id, (current) {
    final ingredients = {...current.ingredients};
    for (final id in matched) {
      ingredients.putIfAbsent(id, () => IngredientStatus.have);
    }
    return current.copyWith(
      ingredients: ingredients,
      confirmedFacts: [
        ...current.confirmedFacts,
        for (final fact in facts)
          if (!current.confirmedFacts.contains(fact)) fact,
      ].reversed.take(30).toList().reversed.toList(),
      revision: current.revision + 1,
      updatedAt: services.clock(),
    );
  });
}
