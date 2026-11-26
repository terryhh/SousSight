// The reviewed recipes' pre-made illustrations (SS-098), generated once with
// tool/generate_illustrations.dart and shipped as assets. Provenance (prompt,
// model, date) for every file is in assets/illustrations/manifest.json; a
// test keeps this index, the manifest and the files in step.

import '../pantry/recipe_draft.dart' show kDraftRecipePrefix;
import 'illustration_prompts.dart';

const kIllustrationAssetRoot = 'assets/illustrations';

/// Recipe id → target keys with a shipped image.
const Map<String, Set<String>> kPremadeIllustrations = {
  'peanut_butter_sandwich_v1': {
    'step_prep',
    'step_spread',
    'step_optional_jam',
    'step_close',
    'plate',
  },
  'chickpea_wrap_v1': {
    'step_pickle_onion',
    'step_mash',
    'step_mix',
    'step_roll',
    'plate',
  },
  'black_bean_corn_salsa_v1': {
    'step_drain_rinse',
    'step_dice',
    'step_dress',
    'step_meld',
    'plate',
  },
};

/// Where the image for [target] in [recipeId] lives.
String illustrationAssetPath(String recipeId, IllustrationTarget target) =>
    '$kIllustrationAssetRoot/$recipeId/${target.key}.jpg';

/// The shipped image for [target], or null. AI-drafted recipes never have
/// one, whatever their id.
String? premadeIllustrationAsset(String recipeId, IllustrationTarget target) {
  if (recipeId.startsWith(kDraftRecipePrefix)) return null;
  final keys = kPremadeIllustrations[recipeId];
  if (keys == null || !keys.contains(target.key)) return null;
  return illustrationAssetPath(recipeId, target);
}
