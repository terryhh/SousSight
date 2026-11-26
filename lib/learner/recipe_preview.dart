// The recipe preview a cook sees before "Start cooking" (SS-099): what they
// have and what is missing, allergens the recipe mentions against the
// household list saved on this device, time, steps and equipment, and whether
// the recipe was reviewed or AI-drafted. On-device data only; no model call.
// The one model-backed action, "Find a swap", goes through Coach Lite.

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../label/household_allergens.dart';
import 'draft_recipe_chip.dart';
import 'recipe_preview_data.dart';
import 'recipe_preview_swap.dart';

const _green = Color(0xFF285B43);
const _terracotta = Color(0xFFBF5B32);
const _gold = Color(0xFFE9A23B);
const _cream = Color(0xFFF5F1E8);
const _ink = Color(0xFF2B2620);
const _muted = Color(0xFF6B5A3E);
const _line = Color(0xFFE6DDCB);

/// Opens the preview. Completes with true only when the cook taps
/// "Start cooking"; back, the system back gesture and "Back to pantry" are
/// all false.
Future<bool> showRecipePreview(
  BuildContext context, {
  required Recipe recipe,
  List<String> confirmedItems = const [],
  bool pantryChecked = true,
  HouseholdAllergens? household,
  RecipeSwapCoach? swapCoach,
}) async {
  final start = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      builder: (_) => RecipePreviewScreen(
        recipe: recipe,
        confirmedItems: confirmedItems,
        pantryChecked: pantryChecked,
        household: household,
        swapCoach: swapCoach,
      ),
    ),
  );
  return start ?? false;
}

class RecipePreviewScreen extends StatelessWidget {
  const RecipePreviewScreen({
    super.key,
    required this.recipe,
    this.confirmedItems = const [],
    this.pantryChecked = true,
    this.household,
    this.swapCoach,
  });

  final Recipe recipe;
  final List<String> confirmedItems;

  /// False when the cook skipped the pantry check (no have/missing claims).
  final bool pantryChecked;

  /// Saved on this device only. Null when this build has none (rehearsal).
  final HouseholdAllergens? household;

  /// Coach Lite for "Find a swap". Null when Coach Lite is not running; the
  /// swap sheet then shows the question to ask once cooking.
  final RecipeSwapCoach? swapCoach;

  @override
  Widget build(BuildContext context) {
    final household = this.household;
    return Scaffold(
      key: const ValueKey('recipe-preview'),
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _cream,
        surfaceTintColor: Colors.transparent,
        leading: BackButton(
          key: const ValueKey('preview-back'),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        title: const Text(
          'Before you cook',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: household == null
          ? _body(context, const {})
          : ListenableBuilder(
              listenable: household,
              builder: (context, _) => _body(context, household.allergens),
            ),
      bottomNavigationBar: const _StartBar(),
    );
  }

  Widget _body(BuildContext context, Set<String> household) {
    final data = RecipePreviewData(
      recipe,
      confirmedItems: confirmedItems,
      pantryChecked: pantryChecked,
      household: household,
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Hero(data: data),
              const SizedBox(height: 14),
              _Stats(data: data),
              const SizedBox(height: 14),
              _IngredientsCard(
                data: data,
                onSwap: (ingredient) => unawaited(
                  showRecipeSwapSheet(
                    context,
                    recipe: recipe,
                    question: swapQuestion(ingredient, recipe),
                    coach: swapCoach,
                    confirmedItems: confirmedItems,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _AllergenCard(
                allergens: data.allergens,
                householdAvailable: this.household != null,
              ),
              if (data.equipment.isNotEmpty) ...[
                const SizedBox(height: 14),
                _EquipmentCard(equipment: data.equipment),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---- pieces -----------------------------------------------------------------

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child, this.color = Colors.white});
  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: _line),
    ),
    child: child,
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Row(
      children: [
        Icon(icon, color: _green, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: _ink,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Hero extends StatelessWidget {
  const _Hero({required this.data});
  final RecipePreviewData data;

  @override
  Widget build(BuildContext context) {
    final recipe = data.recipe;
    return Container(
      key: const ValueKey('preview-hero'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2C6A4F), Color(0xFF173F30)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'RECIPE PREVIEW',
            style: TextStyle(
              color: _gold,
              fontSize: 12,
              letterSpacing: 2,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Semantics(
            header: true,
            child: Text(
              recipe.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                height: 1.15,
                letterSpacing: -0.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (recipe.summary.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              recipe.summary.trim(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFDDE8DF),
                fontSize: 15,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 14),
          data.isDraft
              ? DraftRecipeChip(recipe: recipe)
              : const _ReviewedChip(),
        ],
      ),
    );
  }
}

/// The counterpart of [DraftRecipeChip] for bundled, reviewed recipes.
class _ReviewedChip extends StatelessWidget {
  const _ReviewedChip();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('reviewed-recipe-chip'),
    constraints: const BoxConstraints(minHeight: 36),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFE4EBDF),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.verified_outlined, size: 18, color: _green),
        SizedBox(width: 6),
        Flexible(
          child: Text(
            'Reviewed recipe',
            style: TextStyle(color: _green, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    ),
  );
}

class _Stats extends StatelessWidget {
  const _Stats({required this.data});
  final RecipePreviewData data;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        spacing: 10,
        children: [
          Expanded(
            child: _Stat(
              key: const ValueKey('preview-total-time'),
              icon: Icons.schedule_rounded,
              value: '≈ ${formatPreviewMinutes(data.time.totalMinutes)}',
              label: 'Total',
            ),
          ),
          Expanded(
            child: _Stat(
              key: const ValueKey('preview-active-time'),
              icon: Icons.back_hand_outlined,
              value: '≈ ${formatPreviewMinutes(data.time.activeMinutes)}',
              label: 'Hands-on',
            ),
          ),
          Expanded(
            child: _Stat(
              key: const ValueKey('preview-steps'),
              icon: Icons.format_list_numbered_rounded,
              value: '${data.stepCount}',
              label: data.stepCount == 1 ? 'Step' : 'Steps',
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      const Text(
        kPreviewTimeNote,
        style: TextStyle(fontSize: 12, color: _muted),
      ),
    ],
  );
}

class _Stat extends StatelessWidget {
  const _Stat({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
  });
  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label: $value',
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _line),
      ),
      child: Column(
        children: [
          Icon(icon, color: _terracotta, size: 22),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 13, color: _muted)),
        ],
      ),
    ),
  );
}

class _IngredientsCard extends StatelessWidget {
  const _IngredientsCard({required this.data, required this.onSwap});
  final RecipePreviewData data;
  final void Function(Ingredient ingredient) onSwap;

  @override
  Widget build(BuildContext context) {
    final ingredients = data.ingredients;
    if (!ingredients.pantryChecked) {
      return _Card(
        key: const ValueKey('preview-ingredients'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionTitle(
              Icons.shopping_basket_outlined,
              'What you’ll need',
            ),
            const SizedBox(height: 4),
            const Text(
              'You skipped the pantry check, so this is everything the recipe '
              'uses.',
              key: ValueKey('preview-no-pantry'),
              style: TextStyle(fontSize: 14, color: _muted, height: 1.35),
            ),
            const SizedBox(height: 8),
            for (final i in data.recipe.ingredients)
              _IngredientRow(
                ingredient: i,
                icon: Icons.circle,
                iconSize: 8,
                color: _muted,
              ),
          ],
        ),
      );
    }
    final have = ingredients.have.length;
    final needed = have + ingredients.missing.length;
    return _Card(
      key: const ValueKey('preview-ingredients'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle(Icons.kitchen_outlined, 'From your pantry'),
          const SizedBox(height: 10),
          Text(
            ingredients.missing.isEmpty
                ? 'You have everything you need'
                : 'You have $have of $needed ingredients',
            key: const ValueKey('preview-have-count'),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: needed == 0 ? 1 : have / needed,
              minHeight: 10,
              color: _green,
              backgroundColor: const Color(0xFFE9E1D0),
              semanticsLabel: 'Ingredients you have',
            ),
          ),
          if (ingredients.missing.isNotEmpty) ...[
            const SizedBox(height: 16),
            const _GroupLabel('Not on your list', color: _terracotta),
            for (final i in ingredients.missing)
              _IngredientRow(
                key: ValueKey('preview-missing-${i.id}'),
                ingredient: i,
                icon: Icons.radio_button_unchecked,
                color: _terracotta,
                trailing: TextButton.icon(
                  key: ValueKey('find-swap-${i.id}'),
                  style: TextButton.styleFrom(
                    foregroundColor: _green,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: () => onSwap(i),
                  icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                  label: const Text(
                    'Find a swap',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
          if (ingredients.have.isNotEmpty) ...[
            const SizedBox(height: 16),
            const _GroupLabel('You have', color: _green),
            for (final i in ingredients.have)
              _IngredientRow(
                key: ValueKey('preview-have-${i.id}'),
                ingredient: i,
                icon: Icons.check_circle_rounded,
                color: _green,
              ),
          ],
          if (ingredients.optionalMissing.isNotEmpty) ...[
            const SizedBox(height: 16),
            const _GroupLabel('Optional — fine to skip', color: _muted),
            for (final i in ingredients.optionalMissing)
              _IngredientRow(
                key: ValueKey('preview-optional-${i.id}'),
                ingredient: i,
                icon: Icons.remove_circle_outline,
                color: _muted,
              ),
          ],
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w800,
        color: color,
      ),
    ),
  );
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({
    super.key,
    required this.ingredient,
    required this.icon,
    required this.color,
    this.iconSize = 22,
    this.trailing,
  });
  final Ingredient ingredient;
  final IconData icon;
  final Color color;
  final double iconSize;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ingredient.name,
          style: const TextStyle(fontSize: 15, height: 1.3, color: _ink),
        ),
        if (ingredient.qty.trim().isNotEmpty)
          Text(
            ingredient.qty.trim(),
            style: const TextStyle(fontSize: 13, color: _muted),
          ),
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Icon(icon, size: iconSize, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(child: details),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _AllergenCard extends StatelessWidget {
  const _AllergenCard({
    required this.allergens,
    required this.householdAvailable,
  });
  final PreviewAllergens allergens;

  /// False in builds without a household list (rehearsal).
  final bool householdAvailable;

  @override
  Widget build(BuildContext context) {
    final match = allergens.householdMatches.isNotEmpty;
    final householdLine = allergens.householdLine;
    return _Card(
      key: const ValueKey('preview-allergens'),
      color: match ? const Color(0xFFFFF3EC) : Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle(Icons.health_and_safety_outlined, 'Allergens'),
          const SizedBox(height: 10),
          if (householdLine != null)
            _AllergenLine(
              key: const ValueKey('preview-household-line'),
              text: householdLine,
              icon: match
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              color: match ? _terracotta : _green,
              strong: match,
            )
          else
            _AllergenLine(
              key: const ValueKey('preview-no-household'),
              text: householdAvailable
                  ? '$kNoHouseholdAllergensSaved Add them with Label check '
                        'to compare.'
                  : kNoHouseholdAllergensSaved,
              icon: Icons.info_outline_rounded,
              color: _muted,
            ),
          const SizedBox(height: 8),
          _AllergenLine(
            key: const ValueKey('preview-mention-line'),
            text: allergens.mentionLine,
            icon: Icons.menu_book_outlined,
            color: _muted,
          ),
          const SizedBox(height: 10),
          const Text(
            'Your household list stays on this device. The camera and the '
            'coach can’t confirm allergens.',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _AllergenLine extends StatelessWidget {
  const _AllergenLine({
    super.key,
    required this.text,
    required this.icon,
    required this.color,
    this.strong = false,
  });
  final String text;
  final IconData icon;
  final Color color;
  final bool strong;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 15,
            height: 1.35,
            color: strong ? const Color(0xFF7A2E12) : _ink,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    ],
  );
}

class _EquipmentCard extends StatelessWidget {
  const _EquipmentCard({required this.equipment});
  final List<String> equipment;

  @override
  Widget build(BuildContext context) => _Card(
    key: const ValueKey('preview-equipment'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(Icons.blender_outlined, 'Equipment'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in equipment)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFDF8),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _line),
                ),
                child: Text(item, style: const TextStyle(color: _ink)),
              ),
          ],
        ),
      ],
    ),
  );
}

class _StartBar extends StatelessWidget {
  const _StartBar();

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Color(0xFFFFFDF8),
      border: Border(top: BorderSide(color: _line)),
    ),
    child: SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              spacing: 10,
              children: [
                OutlinedButton(
                  key: const ValueKey('preview-back-to-pantry'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 56),
                    foregroundColor: _green,
                    side: const BorderSide(color: _green),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Back'),
                ),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('preview-start-cooking'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _green,
                      minimumSize: const Size.fromHeight(56),
                      textStyle: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.restaurant),
                    label: const Text('Start cooking'),
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
