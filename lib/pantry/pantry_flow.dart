import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart' show CloudRoute;
import '../app/hybrid_controls.dart';
import '../app/hybrid_runtime.dart';
import '../app/rehearsal_runtime.dart';
import '../app/services_scope.dart';
import '../core/analytics.dart';
import '../core/models.dart';
import '../learner/cooking_app.dart';
import '../live/live_media_factory.dart';
import '../live/live_types.dart';
import '../nearby/nearby_client.dart' show NearbyClient, nearbyClientFor;
import 'pantry_client.dart';
import 'pantry_handoff.dart';
import 'pantry_screen.dart';
import 'recipe_catalog.dart';
import 'recipe_draft.dart';
import 'recipe_draft_client.dart';

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
    this.draftClient,
    this.mediaFactory,
    this.loadRecipes = loadRecipeCatalog,
    this.cookingBuilder,
    this.hybrid,
  });

  final AppServices services;
  final bool isDemo;
  final String? initialRecipeId;
  final PantryClient? client;

  /// Drafts a recipe from confirmed pantry items when no reviewed one fits.
  final RecipeDraftClient? draftClient;
  final LiveMedia Function()? mediaFactory;
  final Future<List<Recipe>> Function() loadRecipes;
  final CookingPageBuilder? cookingBuilder;

  /// Shared hybrid inference services. In rehearsal this is the practice-mode
  /// runtime (scripted, labelled simulated); null in tests that supply their
  /// own clients.
  final HybridRuntime? hybrid;

  @override
  State<PantryFlow> createState() => _PantryFlowState();
}

class _PantryFlowState extends State<PantryFlow> {
  late final Future<List<Recipe>> _recipes = widget.loadRecipes();
  late final PantryClient _client =
      widget.client ??
      switch ((widget.isDemo, widget.hybrid)) {
        (true, final hybrid?) => RehearsalPantryClient(hybrid),
        (true, null) => const FakePantryClient(),
        (false, final hybrid?) => HybridPantryClient(
          dispatcher: hybrid.dispatcher,
          sessionId: () => hybrid.sessionId,
        ),
        (false, null) => GeminiPantryClient(),
      };
  // SS-053: the only place the default draft clients are chosen.
  late final RecipeDraftClient _draftClient =
      widget.draftClient ??
      switch ((widget.isDemo, widget.hybrid)) {
        (true, final hybrid?) => RehearsalDraftClient(
          hybrid,
          FakeRecipeDraftClient(),
        ),
        (true, null) => FakeRecipeDraftClient(),
        (false, final hybrid?) => HybridRecipeDraftClient(
          dispatcher: hybrid.dispatcher,
          sessionId: () => hybrid.sessionId,
        ),
        (false, null) => GeminiRecipeDraftClient(),
      };
  // Gated by CloudRoute.nearby and the cook's switch; null hides nearby.
  late final NearbyClient? _nearbyClient = nearbyClientFor(
    isDemo: widget.isDemo,
    hybrid: widget.hybrid,
  );
  bool _opening = false;

  Widget _cooking(Recipe recipe, VoidCallback onBack) =>
      widget.cookingBuilder?.call(recipe, onBack) ??
      CookingScreen(
        key: ValueKey('cooking-${recipe.id}'),
        services: widget.services,
        isDemo: widget.isDemo,
        recipe: recipe,
        onBackToPantry: onBack,
        hybrid: widget.hybrid,
      );

  Widget _pantry(List<Recipe> recipes) => PantryScreen(
    recipes: recipes,
    client: _client,
    draftClient: _draftClient,
    isDemo: widget.isDemo,
    nearbyClient: _nearbyClient,
    mediaFactory: widget.isDemo
        ? null
        : (widget.mediaFactory ?? createLiveMedia),
    onChooseRecipe: _open,
    header: switch ((widget.isDemo, widget.hybrid)) {
      (false, final hybrid?) => HybridReadinessCard(hybrid: hybrid),
      _ => null,
    },
    // Read live (the gate can change when Remote Config settles).
    voiceOnline: switch (widget.hybrid) {
      // Offline counts as unavailable too (Codex #221).
      final hybrid? =>
        () =>
            hybrid.cloudRoutes.allows(CloudRoute.hybridFallback) &&
            hybrid.isOnline(),
      null => null,
    },
    unavailableReason: switch (widget.hybrid) {
      final hybrid? => () => hybridUnavailableReason(hybrid),
      null => null,
    },
    headerActions: switch (widget.hybrid) {
      final hybrid? => HybridHeaderButtons(
        hybrid: hybrid,
        // Typed labels only here: the pantry screen owns its own camera.
        onLabel: () => unawaited(
          openLabelCheck(context, hybrid, sessionId: hybrid.sessionId),
        ),
      ),
      _ => null,
    },
  );

  Future<void> _open(Recipe recipe, PantryHandoff handoff) async {
    if (_opening) return;
    _opening = true;
    if (!widget.isDemo) {
      widget.services.analytics.log(AnalyticsEvents.recipeChosen, {
        'recipe_id': isDraftRecipe(recipe) ? 'ai_draft' : recipe.id,
      });
    }
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
      navigator
          .push(
            MaterialPageRoute<void>(
              builder: (context) =>
                  _cooking(recipe, () => Navigator.of(context).maybePop()),
            ),
          )
          // Back on the pantry: a new pantry flow with its own ledger.
          .then((_) => widget.hybrid?.beginPantry()),
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
          build: (onBack) => _cooking(deepLinked, () {
            widget.hybrid?.beginPantry();
            onBack();
          }),
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
