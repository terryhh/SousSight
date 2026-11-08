import 'package:a2ui_core/a2ui_core.dart' as a2ui;
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../core/models.dart';
import 'pantry_models.dart';

const pantryGreen = Color(0xFF235B46);
const pantryTomato = Color(0xFFC4472B);
const pantryMustard = Color(0xFFF2B84B);
const pantryCream = Color(0xFFFFF8EC);

/// Renders Gemini's validated pantry result through a GenUI SurfaceController
/// with a small trusted catalog. The model's structured output supplies the
/// content; only these app-owned components can be displayed.
class PantryUiController extends ChangeNotifier {
  PantryUiController({required this.onChooseMeal, this.onFindMissing}) {
    catalog = buildPantryCatalog(this);
    engine = SurfaceController(catalogs: [catalog]);
    engine.handleMessage(
      a2ui.CreateSurfaceMessage(surfaceId: surfaceId, catalogId: catalogId),
    );
  }

  static const surfaceId = 'pantry-results';
  static const catalogId = 'app.soussight.pantry';

  final void Function(String recipeId) onChooseMeal;

  /// Opens "Where to get the missing items" for a meal choice.
  final void Function(List<String> missing)? onFindMissing;
  late final Catalog catalog;
  late final SurfaceController engine;
  List<String> _items = const [];
  final Set<int> _confirmed = {};
  int _generation = 0;
  bool _disposed = false;

  int get generation => _generation;
  List<String> get items => _items;
  List<String> get confirmedItems => [
    for (var i = 0; i < _items.length; i++)
      if (_confirmed.contains(i)) _items[i],
  ];
  bool isConfirmed(int index) => _confirmed.contains(index);

  void toggleItem(int index) {
    if (_disposed || index < 0 || index >= _items.length) return;
    _confirmed.contains(index)
        ? _confirmed.remove(index)
        : _confirmed.add(index);
    notifyListeners();
  }

  void chooseMeal(String recipeId) {
    if (!_disposed) onChooseMeal(recipeId);
  }

  void findMissing(List<String> missing) {
    if (!_disposed && missing.isNotEmpty) onFindMissing?.call(missing);
  }

  /// Replaces the surface with components built from a validated result.
  /// Likely items start selected; low-confidence guesses wait for the cook.
  void show(PantryResult result, List<Recipe> recipes) {
    if (_disposed) return;
    final byId = {for (final recipe in recipes) recipe.id: recipe};
    final meals = [
      for (final meal in result.meals)
        if (byId.containsKey(meal.recipeId)) meal,
    ];
    _items = [for (final item in result.items) item.name];
    _confirmed
      ..clear()
      ..addAll([
        for (var i = 0; i < result.items.length; i++)
          if (result.items[i].confidence != PantryConfidence.low) i,
      ]);
    final components = <Map<String, dynamic>>[
      {
        'id': 'root',
        'component': 'PantryColumn',
        'children': [
          if (result.items.isNotEmpty) 'items',
          for (final meal in meals) 'meal_${meal.recipeId}',
        ],
      },
      if (result.items.isNotEmpty)
        {
          'id': 'items',
          'component': 'pantryItems',
          'title': 'Here’s what I spotted',
          'items': [
            for (var i = 0; i < result.items.length; i++)
              {
                'index': i,
                'label': result.items[i].name,
                'confidence': result.items[i].confidence.name,
              },
          ],
        },
      for (var i = 0; i < meals.length; i++)
        {
          'id': 'meal_${meals[i].recipeId}',
          'component': 'mealChoice',
          'recipeId': meals[i].recipeId,
          'title': byId[meals[i].recipeId]!.title,
          'why': meals[i].why,
          'matched': meals[i].matched,
          'missing': meals[i].missing,
          'best': i == 0,
          'steps': byId[meals[i].recipeId]!.steps.length,
        },
    ];
    engine.handleMessage(a2ui.DeleteSurfaceMessage(surfaceId: surfaceId));
    engine.handleMessage(
      a2ui.CreateSurfaceMessage(surfaceId: surfaceId, catalogId: catalogId),
    );
    engine.handleMessage(
      a2ui.UpdateComponentsMessage(
        surfaceId: surfaceId,
        components: components,
      ),
    );
    _generation++;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    engine.dispose();
    super.dispose();
  }
}

class PantrySurface extends StatelessWidget {
  const PantrySurface({super.key, required this.controller});
  final PantryUiController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (_, _) => controller.generation == 0
        ? const SizedBox.shrink()
        : Surface(
            key: ValueKey(controller.generation),
            surfaceContext: controller.engine.contextFor(
              PantryUiController.surfaceId,
            ),
          ),
  );
}

Map<String, dynamic> _data(CatalogItemContext context) =>
    Map<String, dynamic>.from(context.data as Map);

Schema _object(Map<String, Schema> properties, List<String> required) =>
    S.object(
      properties: properties,
      required: required,
      additionalProperties: false,
    );

Catalog buildPantryCatalog(PantryUiController controller) => Catalog([
  CatalogItem(
    name: 'PantryColumn',
    dataSchema: _object({'children': S.list(items: S.string())}, ['children']),
    widgetBuilder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 18,
      children: [
        for (final id in _data(context)['children'] as List)
          context.buildChild(id as String),
      ],
    ),
  ),
  CatalogItem(
    name: 'pantryItems',
    dataSchema: _object(
      {
        'title': S.string(),
        'items': S.list(
          items: _object(
            {
              'index': S.integer(),
              'label': S.string(),
              'confidence': S.string(enumValues: ['low', 'medium', 'high']),
            },
            ['index', 'label', 'confidence'],
          ),
        ),
      },
      ['title', 'items'],
    ),
    widgetBuilder: (context) {
      final data = _data(context);
      return _PantryCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              data['title'] as String,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap to keep only what you really have. Dimmed items are guesses.',
              style: TextStyle(fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 14),
            AnimatedBuilder(
              animation: controller,
              builder: (_, _) => Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final item in data['items'] as List)
                    _ItemChip(
                      label: (item as Map)['label'] as String,
                      confidence: item['confidence'] as String,
                      selected: controller.isConfirmed(item['index'] as int),
                      onTap: () => controller.toggleItem(item['index'] as int),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  ),
  CatalogItem(
    name: 'mealChoice',
    dataSchema: _object(
      {
        'recipeId': S.string(),
        'title': S.string(),
        'why': S.string(),
        'matched': S.list(items: S.string()),
        'missing': S.list(items: S.string()),
        'best': S.boolean(),
        'steps': S.integer(),
      },
      ['recipeId', 'title', 'why', 'matched', 'missing'],
    ),
    widgetBuilder: (context) {
      final data = _data(context);
      return _MealCard(
        recipeId: data['recipeId'] as String,
        title: data['title'] as String,
        why: data['why'] as String,
        matched: (data['matched'] as List).cast<String>(),
        missing: (data['missing'] as List).cast<String>(),
        best: data['best'] as bool? ?? false,
        steps: data['steps'] as int?,
        onChoose: controller.chooseMeal,
        onFindMissing: controller.onFindMissing == null
            ? null
            : controller.findMissing,
      );
    },
  ),
], catalogId: PantryUiController.catalogId);

class _PantryCard extends StatelessWidget {
  const _PantryCard({required this.child, this.highlight = false});
  final Widget child;
  final bool highlight;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(26),
      border: Border.all(
        color: highlight ? pantryGreen : const Color(0xFFEADFCB),
        width: highlight ? 2.5 : 1,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x14000000),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

class _ItemChip extends StatelessWidget {
  const _ItemChip({
    required this.label,
    required this.confidence,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String confidence;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hint = switch (confidence) {
      'high' => 'clear',
      'medium' => 'likely',
      _ => 'not sure',
    };
    return Semantics(
      button: true,
      toggled: selected,
      label: '$label, $hint',
      excludeSemantics: true,
      child: Material(
        color: selected ? pantryGreen : pantryCream,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? pantryGreen : const Color(0xFFD9C9AE),
            width: 1.5,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 18, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? Icons.check_circle : Icons.add_circle_outline,
                    size: 22,
                    color: selected ? Colors.white : pantryGreen,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? Colors.white
                            : const Color(0xFF3B3328),
                      ),
                    ),
                  ),
                  if (confidence != 'high') ...[
                    const SizedBox(width: 6),
                    Text(
                      hint,
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: selected
                            ? Colors.white70
                            : const Color(0xFF7A6A52),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MealCard extends StatelessWidget {
  const _MealCard({
    required this.recipeId,
    required this.title,
    required this.why,
    required this.matched,
    required this.missing,
    required this.best,
    required this.steps,
    required this.onChoose,
    this.onFindMissing,
  });
  final String recipeId;
  final String title;
  final String why;
  final List<String> matched;
  final List<String> missing;
  final bool best;
  final int? steps;
  final void Function(String recipeId) onChoose;
  final void Function(List<String> missing)? onFindMissing;

  @override
  Widget build(BuildContext context) => _PantryCard(
    highlight: best,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (best) _badge('BEST MATCH', pantryGreen, Colors.white),
            if (steps != null)
              _badge('$steps STEPS', pantryCream, const Color(0xFF6B5A3E)),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          title,
          style: const TextStyle(
            fontSize: 24,
            height: 1.15,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(why, style: const TextStyle(fontSize: 16, height: 1.45)),
        if (matched.isNotEmpty) ...[
          const SizedBox(height: 12),
          _list(Icons.check_rounded, 'You have', matched, pantryGreen),
        ],
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 8),
          _list(
            Icons.shopping_basket_outlined,
            'Still need',
            missing,
            pantryTomato,
          ),
          if (onFindMissing case final find?) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: ValueKey('nearby-missing-$recipeId'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: pantryGreen,
                side: const BorderSide(color: pantryGreen, width: 1.5),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: const Icon(Icons.storefront_outlined),
              label: const Text('Where to get the missing items'),
              onPressed: () => find(missing),
            ),
          ],
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: ValueKey('cook-$recipeId'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              backgroundColor: best ? pantryTomato : pantryGreen,
              textStyle: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const Icon(Icons.restaurant),
            label: Text('Cook $title'),
            onPressed: () => onChoose(recipeId),
          ),
        ),
      ],
    ),
  );

  static Widget _badge(String text, Color background, Color foreground) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w800,
              color: foreground,
            ),
          ),
        ),
      );

  static Widget _list(
    IconData icon,
    String label,
    List<String> values,
    Color color,
  ) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 8),
      Expanded(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(fontWeight: FontWeight.w800, color: color),
              ),
              TextSpan(text: values.join(', ')),
            ],
          ),
          style: const TextStyle(fontSize: 15, height: 1.4),
        ),
      ),
    ],
  );
}
