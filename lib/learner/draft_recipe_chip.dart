import 'package:flutter/material.dart';

import '../core/models.dart';
import '../pantry/recipe_draft.dart';

const draftRecipeAdvice =
    "Gemini drafted this from your pantry items. It hasn't been reviewed by a "
    'person: check each step, read labels, and use a thermometer for anything '
    'that must be cooked through.';

/// Outlined amber chip marking an AI-drafted, unreviewed recipe. Renders
/// nothing for reviewed (bundled) recipes.
class DraftRecipeChip extends StatelessWidget {
  const DraftRecipeChip({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    if (!isDraftRecipe(recipe)) return const SizedBox.shrink();
    void showAdvice() => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.auto_awesome_outlined),
        title: const Text(kDraftRecipeLabel),
        content: const Text(draftRecipeAdvice),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      label: '$kDraftRecipeLabel. Tap for safety advice.',
      excludeSemantics: true,
      onTap: showAdvice,
      child: Material(
        key: const ValueKey('draft-recipe-chip'),
        color: const Color(0xFFFFF7E0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFB7791F), width: 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: showAdvice,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 18,
                    color: Color(0xFF7A4A00),
                  ),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      kDraftRecipeLabel,
                      style: TextStyle(
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
