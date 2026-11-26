import 'package:flutter/material.dart';

import '../core/models.dart';
import '../pantry/recipe_draft.dart';

const draftRecipeAdvice =
    "Gemini drafted this from your pantry items. It hasn't been reviewed by a "
    'person: check each step, read labels, and use a thermometer for anything '
    'that must be cooked through.';

/// Outlined amber chip marking an AI-drafted, unreviewed recipe. Renders
/// nothing for reviewed (bundled) recipes.
/// What the chip says in practice mode, where no model drafted anything.
const kPracticeDraftLabel = 'Practice recipe (pretend answer)';
const practiceDraftAdvice =
    'This is a pretend recipe for practice mode: no AI made it and nothing '
    'was sent. Check each step yourself before cooking for real.';

class DraftRecipeChip extends StatelessWidget {
  const DraftRecipeChip({
    super.key,
    required this.recipe,
    this.practice = false,
  });

  final Recipe recipe;

  /// Practice mode (rehearsal): the chip never claims an AI drafted it.
  final bool practice;

  @override
  Widget build(BuildContext context) {
    if (!isDraftRecipe(recipe)) return const SizedBox.shrink();
    void showAdvice() => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.auto_awesome_outlined),
        title: Text(practice ? kPracticeDraftLabel : kDraftRecipeLabel),
        content: Text(practice ? practiceDraftAdvice : draftRecipeAdvice),
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
      label:
          '${practice ? kPracticeDraftLabel : kDraftRecipeLabel}. Tap for '
          'safety advice.',
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.auto_awesome_outlined,
                    size: 18,
                    color: Color(0xFF7A4A00),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      practice ? kPracticeDraftLabel : kDraftRecipeLabel,
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
