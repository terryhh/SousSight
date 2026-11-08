import 'package:flutter/material.dart';

import '../core/models.dart';
import '../nearby/nearby_client.dart';
import '../nearby/nearby_sheet.dart';
import 'cooking_coordinator.dart';

const _pantryFactPrefix = 'Pantry has (confirmed by the cook):';

/// Items from the pantry hand-off fact
/// `Pantry has (confirmed by the cook): a, b, c.` Nothing is inferred.
List<String> pantryItemsFromFacts(Iterable<String> facts) {
  final items = <String>[];
  for (final fact in facts) {
    if (!fact.startsWith(_pantryFactPrefix)) continue;
    var list = fact.substring(_pantryFactPrefix.length).trim();
    if (list.endsWith('.')) list = list.substring(0, list.length - 1);
    for (final item in list.split(',')) {
      final trimmed = item.trim();
      if (trimmed.isNotEmpty &&
          !items.any((i) => i.toLowerCase() == trimmed.toLowerCase())) {
        items.add(trimmed);
      }
    }
  }
  return items;
}

/// The honest end of the pantry-to-plate story: what the cook confirmed, how
/// many steps they finished, and what to do next. No AI calls are made here.
class MealCompletePanel extends StatefulWidget {
  const MealCompletePanel({
    super.key,
    required this.cook,
    required this.isDemo,
    required this.onTextHousehold,
    required this.onCookSomethingElse,
    this.cookSomethingElseLabel = 'Cook something else',
    this.nearbyClient,
    this.locate,
    this.openLink,
  });

  final CookingCoordinator cook;
  final bool isDemo;
  final VoidCallback onTextHousehold;

  /// Back to the pantry when the flow has one, otherwise a new cook. Null
  /// while a new cook is already starting.
  final VoidCallback? onCookSomethingElse;
  final String cookSomethingElseLabel;
  final NearbyClient? nearbyClient;
  final NearbyLocator? locate;
  final NearbyLinkOpener? openLink;

  @override
  State<MealCompletePanel> createState() => _MealCompletePanelState();
}

class _MealCompletePanelState extends State<MealCompletePanel> {
  late final NearbyClient _nearby =
      widget.nearbyClient ??
      (widget.isDemo ? const FakeNearbyClient() : GeminiNearbyClient());

  @override
  void initState() {
    super.initState();
    // On phones the workspace sits below the camera; bring the moment into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _openNearby() => showNearbySheet(
    context,
    client: _nearby,
    kind: NearbyKind.foodHelp,
    locate:
        widget.locate ??
        (widget.isDemo ? () async => NearbyCoordinates(28.54, -81.38) : null),
    openLink: widget.openLink,
  );

  @override
  Widget build(BuildContext context) {
    final cook = widget.cook;
    final session = cook.session;
    final stepIds = {for (final step in cook.recipe.steps) step.id};
    final done =
        session?.completedStepIds.where(stepIds.contains).toSet().length ?? 0;
    final pantry = pantryItemsFromFacts(session?.confirmedFacts ?? const []);
    final had = [
      for (final ingredient in cook.recipe.ingredients)
        if (session?.ingredients[ingredient.id] == IngredientStatus.have &&
            !pantry.any(
              (item) => item.toLowerCase() == ingredient.name.toLowerCase(),
            ))
          ingredient.name,
    ];
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('meal-complete'),
      color: const Color(0xfffff3dc),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(26),
        side: const BorderSide(color: Color(0xffefce98), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(
              child: Text(
                '🎉🍽️',
                textAlign: TextAlign.center,
                style: theme.textTheme.displaySmall,
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              header: true,
              child: Text(
                'You made ${cook.recipe.title}!',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  height: 1.15,
                  letterSpacing: -.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xff1f3d2f),
                ),
              ),
            ),
            if (widget.isDemo) ...[
              const SizedBox(height: 8),
              const Center(
                child: Chip(
                  avatar: Icon(Icons.science_outlined, size: 18),
                  label: Text('Rehearsal · simulated coach'),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _recapLine(
              Icons.check_circle_outline,
              'Steps completed: $done of ${cook.recipe.steps.length}',
            ),
            if (pantry.isNotEmpty)
              _recapList('From your pantry (you confirmed)', pantry),
            if (had.isNotEmpty) _recapList('Ingredients you had', had),
            if (pantry.isEmpty && had.isEmpty)
              _recapLine(
                Icons.kitchen_outlined,
                'No pantry items were confirmed for this cook.',
              ),
            if (!cook.live.isActive) ...[
              const SizedBox(height: 4),
              _recapLine(Icons.pause_circle_outline, mealCompleteCoachNote),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const ValueKey('meal-complete-text-household'),
              onPressed: widget.onTextHousehold,
              icon: const Icon(Icons.sms_outlined),
              label: const Text('Text the household: dinner is ready'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('meal-complete-nearby'),
              onPressed: _openNearby,
              icon: const Icon(Icons.volunteer_activism_outlined),
              label: const Text('Find food help nearby for next time'),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              key: const ValueKey('meal-complete-cook-again'),
              onPressed: widget.onCookSomethingElse,
              icon: const Icon(Icons.restaurant_menu),
              label: Text(widget.cookSomethingElseLabel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recapLine(IconData icon, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: const Color(0xff285b43)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
      ],
    ),
  );

  Widget _recapList(String label, List<String> items) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final item in items)
              Chip(
                label: Text(item),
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xffd9cdb6)),
              ),
          ],
        ),
      ],
    ),
  );
}
