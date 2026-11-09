// Dependency container passed down the widget tree. lib/data/ provides
// `firebaseServices()`; `fakeServices()` runs the app with no backend
// (`--dart-define=FAKE_BACKEND=true`).

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

import '../core/analytics.dart';
import '../core/fakes.dart';
import '../core/models.dart';
import '../core/services.dart';

// Override for a reviewed alternate recipe without changing saved sessions.
const kRecipeId = String.fromEnvironment(
  'RECIPE_ID',
  defaultValue: 'peanut_butter_sandwich_v1',
);
const kFakeBackend = bool.fromEnvironment('FAKE_BACKEND');

class AppServices {
  const AppServices({
    required this.auth,
    required this.recipes,
    required this.sessions,
    required this.bundledRecipe,
    this.clock = DateTime.now,
    this.analytics = const NoopAnalytics(),
  });

  final AuthService auth;
  final RecipeRepository recipes;
  final SessionRepository sessions;

  /// The recipe as shipped in assets (used for target images and offline).
  final Recipe bundledRecipe;
  final DateTime Function() clock;

  /// Usage counts (GA4 in production builds; no-op in fakes and tests).
  final Analytics analytics;
}

Future<Recipe> loadBundledRecipe([String id = kRecipeId]) async {
  final json = await rootBundle.loadString('assets/recipes/$id.json');
  return Recipe.fromMap(jsonDecode(json) as Map<String, dynamic>);
}

Future<AppServices> fakeServices({String recipeId = kRecipeId}) async {
  final recipe = await loadBundledRecipe(recipeId);
  return AppServices(
    auth: FakeAuthService(),
    recipes: FakeRecipeRepository(recipe),
    sessions: FakeSessionRepository(),
    bundledRecipe: recipe,
  );
}

class ServicesScope extends InheritedWidget {
  const ServicesScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ServicesScope>();
    assert(scope != null, 'No ServicesScope above this context');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(ServicesScope oldWidget) => services != oldWidget.services;
}
