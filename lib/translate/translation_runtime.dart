// App wiring for "Cook in your language" (SS-106): one language choice and
// translation cache per hybrid runtime, shared by the header switch, the
// recipe view and the language-aware dispatcher for Coach Lite.

import '../ai/hybrid/hybrid_types.dart';
import '../app/hybrid_runtime.dart';
import 'cook_language.dart';
import 'language_dispatcher.dart';
import 'recipe_translator.dart';
import 'translation_controller.dart';

final _controllers = Expando<TranslationController>('cook-language');

/// The language choice and translations for [hybrid], created on first use.
/// It lives as long as the runtime (one app run), so the cache does too.
TranslationController translationFor(HybridRuntime hybrid) =>
    _controllers[hybrid] ??= TranslationController(
      translator: RecipeTranslator(
        dispatcher: hybrid.dispatcher,
        // A translation belongs to the cooking session it started in.
        sessionIsCurrent: (id) => hybrid.sessionId == id,
      ),
      localTokenBudget: () async =>
          (await hybrid.inference.capabilities()).local?.maxTotalTokens,
    );

/// [hybrid]'s dispatcher, with Coach Lite answering in the cook's language.
/// Pass it to `CoachLite(dispatcher: ...)`.
HybridDispatcher languageAwareDispatcherFor(HybridRuntime hybrid) =>
    LanguageAwareDispatcher(
      hybrid.dispatcher,
      language: () => translationFor(hybrid).language,
    );

/// Features whose answers are written in the cook's language, so the
/// dispatcher's on-device language check must use it. Everything else (the
/// watch, the label check, the pantry scan) keeps the app's own language.
const cookLanguageFeatures = {recipeTranslateFeature, ...languageAwareFeatures};

/// For `DefaultHybridDispatcher(featureLanguageTag: ...)`: the cook's
/// language for [feature], or null to use the default. Never creates a
/// controller.
String? cookLanguageTagFor(HybridRuntime hybrid, String feature) =>
    cookLanguageFeatures.contains(feature)
    ? _controllers[hybrid]?.language.code
    : null;

/// Every cook language, for `HybridConfig.languages` (Chrome's
/// `expectedInputs` / `expectedOutputs`).
List<String> get cookLanguageCodes => [for (final l in cookLanguages) l.code];
