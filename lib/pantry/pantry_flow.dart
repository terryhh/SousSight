import 'dart:async';

import 'package:flutter/material.dart';

import '../app/services_scope.dart';
import '../core/models.dart';
import '../learner/cooking_app.dart';
import '../live/browser_live_media.dart';
import '../live/live_types.dart';
import 'pantry_client.dart';
import 'pantry_handoff.dart';
import 'pantry_screen.dart';
import 'recipe_catalog.dart';

typedef CookingPageBuilder = Widget Function(
  Recipe recipe,
  VoidCallback onBackToPantry,
);

/// Pantry-first start: the pantry screen opens first, unless a deep link
/// (`?recipe=<id>` or an explicit RECIPE_ID build) jumps straight to cooking.
class PantryFlow extends StatefulWidget {
  const PantryFlow({
    super.key,
    required this.services,
    required this.isDemo,
    this.initialRecipeId,
    this.client,
    this.mediaFactory,
    this.loadRecipes = loadRecipeCatalog,
    this.cookingBuilder,
  });

  final AppServices services;
  final bool isDemo;
  final String? initialRecipeId;
  final PantryClient? client;
  final LiveMedia Function()? mediaFactory;
  final Future<List<Recipe>> Function() loadRecipes;
  final CookingPageBuilder? cookingBuilder;

  @override
  State<PantryFlow> createState() => _PantryFlowState();
}

class _PantryFlowState extends State<PantryFlow> {
  late final Future<List<Recipe>> _recipes = widget.loadRecipes();
  late final PantryClient _client =
      widget.client ??
      (widget.isDemo ? const FakePantryClient() : GeminiPantryClient());
  bool _opening = false;

  Widget _cooking(Recipe recipe, VoidCallback onBack) =>
      widget.cookingBuilder?.call(recipe, onBack) ??
      CookingScreen(
        key: ValueKey('cooking-${recipe.id}'),
        services: widget.services,
        isDemo: widget.isDemo,
        recipe: recipe,
        onBackToPantry: onBack,
      );

  Widget _pantry(List<Recipe> recipes) => PantryScreen(
    recipes: recipes,
    client: _client,
    isDemo: widget.isDemo,
    mediaFactory: widget.isDemo
        ? null
        : (widget.mediaFactory ?? createBrowserLiveMedia),
    onChooseRecipe: _open,
  );

  Future<void> _open(Recipe recipe, PantryHandoff handoff) async {
    if (_opening) return;
    _opening = true;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await applyPantryHandoff(widget.services, recipe, handoff);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not save your pantry list. Tell your coach what you have.',
          ),
        ),
      );
    } finally {
      _opening = false;
    }
    if (!mounted) return;
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (context) =>
              _cooking(recipe, () => Navigator.of(context).maybePop()),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Recipe>>(
    future: _recipes,
    builder: (context, snapshot) {
      final recipes = snapshot.data;
      if (recipes == null) {
        return Scaffold(
          body: Center(
            child: snapshot.hasError
                ? const Text('Could not load the recipe list.')
                : const CircularProgressIndicator(),
          ),
        );
      }
      final deepLinked = recipes
          .where((recipe) => recipe.id == widget.initialRecipeId)
          .firstOrNull;
      if (deepLinked != null) {
        return _DeepLinkedCooking(
          build: (onBack) => _cooking(deepLinked, onBack),
          pantry: () => _pantry(recipes),
        );
      }
      return _pantry(recipes);
    },
  );
}

/// Deep links open cooking directly; "back to pantry" swaps in the pantry.
class _DeepLinkedCooking extends StatefulWidget {
  const _DeepLinkedCooking({required this.build, required this.pantry});
  final Widget Function(VoidCallback onBack) build;
  final Widget Function() pantry;

  @override
  State<_DeepLinkedCooking> createState() => _DeepLinkedCookingState();
}

class _DeepLinkedCookingState extends State<_DeepLinkedCooking> {
  bool _showPantry = false;

  @override
  Widget build(BuildContext context) => _showPantry
      ? widget.pantry()
      : widget.build(() => setState(() => _showPantry = true));
}
