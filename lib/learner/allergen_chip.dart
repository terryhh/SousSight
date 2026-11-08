import 'package:flutter/material.dart';

import '../core/models.dart';
import 'recipe_allergens.dart';

const allergenLabelNote = "Check labels; the camera can't confirm allergens.";

/// Compact "Contains: ..." chip for the cooking header. Renders nothing when
/// the recipe data declares no allergens.
class AllergenChip extends StatelessWidget {
  const AllergenChip({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final allergens = recipeAllergens(recipe);
    if (allergens.isEmpty) return const SizedBox.shrink();
    final text =
        'Contains: ${allergens.map((a) => a.optionalOnly ? '${a.name} (optional)' : a.name).join(', ')}';
    return Semantics(
      button: true,
      label: 'Allergens. $text. Tap for label advice.',
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('allergen-chip'),
        color: const Color(0xFFFFF0D6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFD08A1E)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              icon: const Icon(Icons.warning_amber_rounded),
              title: Text(text),
              content: const Text(allergenLabelNote),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Got it'),
                ),
              ],
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: Color(0xFF8A4B00),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      text,
                      style: const TextStyle(
                        color: Color(0xFF5C3300),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
