import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../core/models.dart';

/// Reviewed recipes shipped with the app. The pantry matcher may only rank
/// these; it never invents a recipe.
const kBundledRecipeIds = [
  'peanut_butter_sandwich_v1',
  'chickpea_wrap_v1',
  'black_bean_corn_salsa_v1',
];

Future<List<Recipe>> loadRecipeCatalog([AssetBundle? bundle]) async {
  final source = bundle ?? rootBundle;
  return [
    for (final id in kBundledRecipeIds)
      Recipe.fromMap(
        jsonDecode(await source.loadString('assets/recipes/$id.json'))
            as Map<String, dynamic>,
      ),
  ];
}

/// A deep link that skips the pantry screen: `?recipe=<id>` in the page URL,
/// or an explicit `--dart-define=RECIPE_ID=<id>` build. Unknown IDs are ignored.
String? deepLinkRecipeId({Uri? url}) {
  final fromUrl = (url ?? Uri.base).queryParameters['recipe'];
  if (fromUrl != null && kBundledRecipeIds.contains(fromUrl)) return fromUrl;
  const defined = bool.hasEnvironment('RECIPE_ID');
  const id = String.fromEnvironment('RECIPE_ID');
  if (defined && kBundledRecipeIds.contains(id)) return id;
  return null;
}
