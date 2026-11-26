// The reviewed recipes' pre-made illustrations (SS-098), generated once with
// tool/generate_illustrations.dart and shipped as assets. Provenance (prompt,
// model, date) for every file is in assets/illustrations/manifest.json; a
// test keeps this index, the manifest and the files in step.

import 'dart:convert';

import '../ai/hybrid/payload_digest.dart' show sha256Hex;
import '../core/models.dart';
import '../pantry/recipe_draft.dart' show isDraftRecipe;
import 'illustration_prompts.dart';

const kIllustrationAssetRoot = 'assets/illustrations';

/// Recipe id → target key → SHA-256 of the builder prompt the image was
/// reviewed against. A bundled image is shown only while the recipe still
/// produces that exact prompt, so a reviewed recipe edited later never
/// shows a picture of its old wording.
const Map<String, Map<String, String>> kPremadeIllustrations = {
  'peanut_butter_sandwich_v1': {
    'step_prep':
        'dc84e590e1cc9c53567932a46f4f8201eb3a9a43d1482c7eab2c5686b8aec453',
    'step_spread':
        'f782f1f0222715eb8dd194a65b71a8f760d95f7bd46165146f6c9e8a9f89e1b3',
    'step_optional_jam':
        'adeefaf9d01809326c50232eb5469e0e9693b34b58394d33dea765d6d6f1876d',
    'step_close':
        '6f4fac18f2ec1b0d2bf80aa6a24c7a8b6ea896b200c5fe878de462346a40b428',
    'plate': '28c9f6bad27c15dae7ff2be07c573c9eec10e9e762266c533b228c6fce63fdee',
  },
  'chickpea_wrap_v1': {
    'step_pickle_onion':
        'bf00c824d2cfe7307611dca21b1aa4a53ec5090a83925cda5c498955d121553e',
    'step_mash':
        'cc0a2a897bf5d3817afb3a852c4b18fd55262368a289497679eb499caeef0c19',
    'step_mix':
        '6605158bbf30cabae2423dfad769f3304d475fe28cc659e051d6f64033d10834',
    'step_roll':
        '413c1cce1e35dae712621b11159b0734bb00031161e17deb586661f573f5f819',
    'plate': '98e5f88dd19bc8886ddf6d28d92fdaab81c6b7465b563ab362432182d03bdcd2',
  },
  'black_bean_corn_salsa_v1': {
    'step_drain_rinse':
        'fffa3ff10d517304148d68344148a592fdf53139838a1fb8a2c0c15feae9795c',
    'step_dice':
        '82b3b4a9119964878a0c09d0215a58040652548c51d2061f96a60e5a7b162405',
    'step_dress':
        '1c966c199837b23b8e917c7099b6071ace8d57458ad81a32bbb914713c97a6ed',
    'step_meld':
        '9476feeaa3818f14388a97d2c171dbb449ff1b02863a62b2a3169309f5c04356',
    'plate': '913402e2404e8b177f94fd6a57e479fe1ce52a18b7b8a0eed6b7e94633c911a5',
  },
};

/// Where the image for [target] in [recipeId] lives.
String illustrationAssetPath(String recipeId, IllustrationTarget target) =>
    '$kIllustrationAssetRoot/$recipeId/${target.key}.jpg';

/// The shipped image for [target] in [recipe], or null: AI-drafted recipes
/// never have one, and a reviewed recipe whose content no longer matches
/// the reviewed prompt has none either.
String? premadeIllustrationAsset(Recipe recipe, IllustrationTarget target) {
  if (isDraftRecipe(recipe)) return null;
  final expected = kPremadeIllustrations[recipe.id]?[target.key];
  if (expected == null) return null;
  final prompt = illustrationPrompt(recipe, target);
  if (prompt == null || sha256Hex(utf8.encode(prompt.text)) != expected) {
    return null;
  }
  return illustrationAssetPath(recipe.id, target);
}

/// Requested `recipeId/key` targets that are not in the index. The
/// generator refuses to run while any are left, so a typo cannot quietly
/// generate nothing.
Set<String> unknownPremadeTargets(Iterable<String> requested) {
  final known = {
    for (final MapEntry(key: recipeId, value: keys)
        in kPremadeIllustrations.entries)
      for (final key in keys.keys) '$recipeId/$key',
  };
  return {
    for (final t in requested)
      if (!known.contains(t)) t,
  };
}
