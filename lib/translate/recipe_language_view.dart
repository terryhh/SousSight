// "Cook in your language" UI (SS-106): the header switch and the translated
// recipe sheet. Shell strings stay English; recipe content follows the cook's
// language, labelled as an AI translation with a "Show original" toggle.

import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../core/models.dart';
import '../trust/inference_source_badge.dart';
import '../trust/route_reason_text.dart';
import '../trust/trust_labels.dart';
import 'cook_language.dart';
import 'recipe_translator.dart';
import 'translation_controller.dart';
import 'translation_guard.dart';

/// Where a translation ran, derived only from its legs.
String translationOriginSentence(List<InferenceLeg> legs) {
  if (legs.isEmpty) return 'Saved translation.';
  final outcomes = {for (final leg in legs) legOutcome(leg)};
  if (outcomes.every((o) => o == LegOutcome.simulated)) {
    return 'Practice mode: a pretend translation, not a real model.';
  }
  if (outcomes.contains(LegOutcome.cloudSdk) ||
      outcomes.contains(LegOutcome.cloudAdapter)) {
    return 'Some or all of this was translated in the cloud.';
  }
  if (outcomes.contains(LegOutcome.maybeSent)) {
    return 'Some recipe text may have been sent to the cloud.';
  }
  if (outcomes.every(
    (o) => o == LegOutcome.onDevice || o == LegOutcome.notFinishedLocal,
  )) {
    return 'Translated on this device.';
  }
  return 'Translated by AI.';
}

const translationSafetyNote =
    'AI translations can be wrong. Numbers, times and temperatures are '
    'checked against the original, allergen names keep their English name, '
    'and any line that fails a check stays in English.';

/// Header button: shows the cook's language and opens the recipe in it.
class CookLanguageButton extends StatelessWidget {
  const CookLanguageButton({
    super.key,
    required this.controller,
    required this.recipe,
    required this.sessionId,
    this.currentStepId,
  });

  final TranslationController controller;
  final Recipe recipe;

  /// Read when a translation starts, so it uses the current session.
  final String Function() sessionId;
  final String? currentStepId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Tooltip(
      message: 'Cook in your language',
      child: TextButton.icon(
        key: const ValueKey('cook-language'),
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          foregroundColor: const Color(0xff285b43),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          shape: const StadiumBorder(
            side: BorderSide(color: Color(0x33285b43)),
          ),
        ),
        onPressed: () {
          // A new cook or recipe version under a chosen language: translate
          // it (a cached one comes back at once).
          unawaited(controller.recipeChanged(recipe, sessionId: sessionId()));
          unawaited(
            showRecipeLanguageSheet(
              context,
              controller: controller,
              recipe: recipe,
              sessionId: sessionId,
              currentStepId: currentStepId,
            ),
          );
        },
        icon: const Icon(Icons.translate, size: 18),
        label: Text(controller.language.nativeName),
      ),
    ),
  );
}

Future<void> showRecipeLanguageSheet(
  BuildContext context, {
  required TranslationController controller,
  required Recipe recipe,
  required String Function() sessionId,
  String? currentStepId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.85,
    maxChildSize: 0.95,
    builder: (context, scroll) => RecipeLanguageView(
      controller: controller,
      recipe: recipe,
      sessionId: sessionId,
      currentStepId: currentStepId,
      scrollController: scroll,
    ),
  ),
);

/// The language choice and the recipe in that language.
class RecipeLanguageView extends StatelessWidget {
  const RecipeLanguageView({
    super.key,
    required this.controller,
    required this.recipe,
    required this.sessionId,
    this.currentStepId,
    this.scrollController,
  });

  final TranslationController controller;
  final Recipe recipe;
  final String Function() sessionId;
  final String? currentStepId;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final language = controller.language;
      final finished = controller.translation;
      final relevant =
          finished != null &&
          finished.key == TranslationKey.of(recipe, language);
      final shown = controller.shownFor(recipe);
      final theme = Theme.of(context);

      Widget line(String id, String original, {TextStyle? style}) {
        // Only while a translation is on screen: under "Show original"
        // every line is English anyway.
        final entry = shown?.lines[id];
        final kept = entry != null && entry.kept ? entry.rejection : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              controller.text(recipe, id, original),
              key: ValueKey('line-$id'),
              style: style,
            ),
            if (kept != null)
              _KeptNote(id: id, reason: lineRejectionSentence(kept)),
          ],
        );
      }

      return ListView(
        key: const ValueKey('recipe-language-view'),
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Text('Cook in your language', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text(
            'Recipe steps, ingredients and coach answers use this language. '
            'The app itself stays in English.',
          ),
          const SizedBox(height: 12),
          SegmentedButton<CookLanguage>(
            key: const ValueKey('language-choice'),
            segments: [
              for (final l in cookLanguages)
                ButtonSegment(
                  value: l,
                  label: Text(
                    l.nativeName,
                    key: ValueKey('language-${l.code}'),
                  ),
                ),
            ],
            selected: {language},
            showSelectedIcon: false,
            onSelectionChanged: (choice) => unawaited(
              controller.select(
                choice.single,
                recipe: recipe,
                sessionId: sessionId(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (controller.busy)
            Semantics(
              liveRegion: true,
              child: Row(
                key: const ValueKey('translation-busy'),
                children: [
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Translating into ${language.nativeName}…'),
                  ),
                  TextButton(
                    key: const ValueKey('translation-cancel'),
                    onPressed: controller.cancel,
                    child: const Text('Stop'),
                  ),
                ],
              ),
            ),
          if (!language.isSource && relevant) ...[
            if (finished.status == TranslationStatus.blocked)
              _Notice(
                key: const ValueKey('translation-blocked'),
                text:
                    '${_blockedSentence(finished.blocked)} '
                    'Showing the recipe as written.',
              )
            else ...[
              _AiLabel(translation: finished),
              SwitchListTile(
                key: const ValueKey('show-original'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Show original'),
                value: controller.showOriginal,
                onChanged: (v) => controller.showOriginal = v,
              ),
              if (finished.keptCount > 0 && !controller.showOriginal)
                _Notice(
                  key: const ValueKey('translation-kept-count'),
                  text: finished.status == TranslationStatus.partial
                      ? 'Part of the recipe could not be translated; those '
                            'lines stay in English.'
                      : '${finished.keptCount} '
                            '${finished.keptCount == 1 ? 'line stays' : 'lines stay'} '
                            'in English because a check did not pass.',
                ),
            ],
          ],
          const SizedBox(height: 8),
          line(
            RecipeLineIds.title,
            recipe.title,
            style: theme.textTheme.headlineSmall,
          ),
          if (recipe.summary.trim().isNotEmpty)
            line(RecipeLineIds.summary, recipe.summary),
          const SizedBox(height: 16),
          Text('Ingredients', style: theme.textTheme.titleMedium),
          for (final i in recipe.ingredients)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  '),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        line(
                          RecipeLineIds.ingredientName(i.id),
                          i.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (i.qty.trim().isNotEmpty)
                          line(RecipeLineIds.ingredientQty(i.id), i.qty),
                        if (i.allergens.isNotEmpty)
                          Text(
                            'Allergens: ${i.allergens.join(', ')}',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Text('Steps', style: theme.textTheme.titleMedium),
          for (final (index, s) in recipe.steps.indexed)
            Card(
              key: ValueKey('translated-step-${s.id}'),
              color: s.id == currentStepId ? const Color(0xffe4ebdf) : null,
              margin: const EdgeInsets.only(top: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.id == currentStepId
                          ? 'Step ${index + 1} · Now'
                          : 'Step ${index + 1}',
                      style: theme.textTheme.labelMedium,
                    ),
                    line(
                      RecipeLineIds.stepTitle(s.id),
                      s.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    line(RecipeLineIds.stepInstruction(s.id), s.instruction),
                    if (s.cue.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('Look for:', style: theme.textTheme.labelSmall),
                      line(RecipeLineIds.stepCue(s.id), s.cue),
                    ],
                  ],
                ),
              ),
            ),
          if (!language.isSource) ...[
            const SizedBox(height: 16),
            Text(translationSafetyNote, style: theme.textTheme.bodySmall),
          ],
        ],
      );
    },
  );
}

String _blockedSentence(RouteReason? reason) => reason == null
    ? "The translation couldn't run."
    : routeReasonSentence(reason);

class _AiLabel extends StatelessWidget {
  const _AiLabel({required this.translation});
  final RecipeTranslation translation;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('ai-translation-label'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.auto_awesome_outlined, size: 18),
          const SizedBox(width: 6),
          const Text(
            'AI translation',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(translationOriginSentence(translation.legs))),
        ],
      ),
      if (translation.legs.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: InferenceSourceBadge(legs: translation.legs),
        ),
    ],
  );
}

class _KeptNote extends StatelessWidget {
  const _KeptNote({required this.id, required this.reason});
  final String id;
  final String reason;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: reason,
    child: Text(
      'kept in English',
      key: ValueKey('kept-$id'),
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(fontStyle: FontStyle.italic),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
