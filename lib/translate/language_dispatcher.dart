// Coach Lite (and other single-turn AI answers) in the cook's language
// (SS-106).
//
// [LanguageAwareDispatcher] wraps the app's [HybridDispatcher]. For the
// features it covers it appends the answer-language directive to the task's
// system instruction, using the language chosen when the question was asked,
// and it refuses any answer that would certify doneness, temperature or
// safety in that language: the feature's own English checks cannot read
// Spanish. Every other task passes through untouched. It never sends
// anything itself, so the inner dispatcher's live privacy, route and consent
// checks still govern every send.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import '../ai/hybrid/hybrid_types.dart';
import 'cook_language.dart';
import 'translation_guard.dart';

/// Features whose answers follow the cook's language by default.
const languageAwareFeatures = {'coach_lite'};

class LanguageAwareDispatcher implements HybridDispatcher {
  LanguageAwareDispatcher(
    this.inner, {
    required this.language,
    this.features = languageAwareFeatures,
  });

  final HybridDispatcher inner;

  /// The cook's current choice. Read once per [start].
  final CookLanguage Function() language;
  final Set<String> features;

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    final chosen = language();
    if (chosen.isSource || !features.contains(task.feature)) {
      return inner.start(
        task,
        sessionId: sessionId,
        validate: validate,
        grant: grant,
      );
    }
    String? check(String text) =>
        validate?.call(text) ??
        (certifiesIn(text, chosen)
            ? 'Answer would certify doneness or safety.'
            : null);
    // The directive changes the payload, so a grant made for the original
    // task no longer matches its digest and the inner dispatcher asks again.
    final op = inner.start(
      HybridTask(
        feature: task.feature,
        systemInstruction: withAnswerLanguage(
          task.systemInstruction ?? '',
          chosen,
        ).trim(),
        parts: task.parts,
        jsonSchema: task.jsonSchema,
        maxOutputTokens: task.maxOutputTokens,
        timeout: task.timeout,
        // Captured now: routing and the web bridge use this snapshot even if
        // the cook switches language while the request is in flight.
        outputLanguages: [sourceLanguage.code, chosen.code],
      ),
      sessionId: sessionId,
      validate: check,
      grant: grant,
    );
    // Checked again here: a dispatcher may skip the validator (fakes do),
    // and a certifying answer must never reach the cook. Its legs stay.
    final result = op.result.then(
      (r) => r.text != null && certifiesIn(r.text!, chosen)
          ? DispatchResult(legs: r.legs, blocked: r.blocked)
          : r,
    );
    return HybridOperation(op.operationId, result, op.cancel);
  }
}
