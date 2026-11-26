import '../core/models.dart';

/// One ingredient row as the cook reads it: the name first, an optional
/// marker, then the amount, e.g. "Peanut butter · about 2 tbsp" or
/// "Jam (optional) · about 1 tbsp".
String ingredientRowLabel(Ingredient ingredient) {
  final name = ingredient.name.trim();
  final qty = ingredient.qty.trim();
  final marked = ingredient.optional && !name.toLowerCase().contains('optional')
      ? '$name (optional)'
      : name;
  if (qty.isEmpty) return marked;
  if (marked.isEmpty) return qty;
  return '$marked · $qty';
}
