// App wiring for "Cook in your language" (SS-106): one language choice and
// translation cache per hybrid runtime, shared by the header switch, the
// recipe view and the language-aware dispatcher for Coach Lite.

import '../ai/hybrid/hybrid_types.dart';
import '../app/hybrid_runtime.dart';
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

/// Stops any translation running for [hybrid] at once, so none of its sends
/// reaches the next cooking session. Called when the runtime binds a new
/// session.
void cancelCookLanguageWork(HybridRuntime hybrid) =>
    _controllers[hybrid]?.cancel();
