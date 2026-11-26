// "Find a swap" on the recipe preview (SS-099). The question goes through the
// existing Coach Lite path (CoachLite.ask: the hybrid dispatcher, its privacy
// and consent checks, and the inference ledger). There is no new model path.
// The household allergen list is never put in the request.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/hybrid_runtime.dart';
import '../coach_lite/coach_lite.dart';
import '../core/models.dart';
import '../pantry/recipe_draft.dart' show isDraftRecipe;
import '../trust/inference_source_badge.dart';
import 'cooking_coordinator.dart' show draftRecipeContextLine;
import 'recipe_allergens.dart';
import 'recipe_preview_data.dart';

/// Shown under every swap answer.
const kSwapAllergenCaution =
    'A swap can bring in new allergens — $kCheckLabelsYourself';

/// The preview does not hand off to grounded research, so a factual answer
/// says where it can be checked.
const kSwapSourcesLater =
    'Sources aren’t checked from the preview. Ask your coach again once '
    'you’re cooking to check this against sources.';

const kSwapStale =
    'That answer was for an earlier question. Close this and ask again.';

const kSwapCoachUnavailable =
    'Coach Lite isn’t running in this mode. Start cooking and ask your coach:';

/// Coach Lite plus the session it asks under, for the preview.
class RecipeSwapCoach {
  RecipeSwapCoach({required this.coachLite, required this.sessionId});

  /// The same Coach Lite wiring the cooking screen uses.
  factory RecipeSwapCoach.forRuntime(HybridRuntime hybrid) => RecipeSwapCoach(
    coachLite: CoachLite(
      dispatcher: hybrid.dispatcher,
      privacy: hybrid.privacy,
      cloudRoutes: hybrid.cloudRoutes,
      isOnline: hybrid.isOnline,
    ),
    sessionId: () => hybrid.sessionId,
  );

  final CoachLite coachLite;

  /// Read when a question is asked, never cached.
  final String Function() sessionId;
}

/// Facts Coach Lite gets with a swap question. Cook-confirmed pantry items
/// and the recipe's own allergen tags only: never the household list.
List<String> swapContextFacts(Recipe recipe, List<String> confirmedItems) {
  final allergens = recipeAllergens(recipe);
  final items = [
    for (final item in confirmedItems)
      if (item.trim().isNotEmpty) item.trim(),
  ];
  return [
    if (items.isNotEmpty)
      'Pantry has (confirmed by the cook): ${items.join(', ')}.',
    if (allergens.isNotEmpty)
      'Recipe allergens: ${allergens.map((a) => a.label).join(', ')}. '
          'Never claim a swap is allergen-free; package labels are the '
          'source of truth.',
    'The cook has not started cooking yet; they are checking for a swap '
        'before they begin.',
    if (isDraftRecipe(recipe)) draftRecipeContextLine,
  ];
}

Future<void> showRecipeSwapSheet(
  BuildContext context, {
  required Recipe recipe,
  required String question,
  RecipeSwapCoach? coach,
  List<String> confirmedItems = const [],
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: const Color(0xFFFFFDF8),
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (context) => RecipeSwapSheet(
    recipe: recipe,
    question: question,
    coach: coach,
    confirmedItems: confirmedItems,
  ),
);

class RecipeSwapSheet extends StatefulWidget {
  const RecipeSwapSheet({
    super.key,
    required this.recipe,
    required this.question,
    this.coach,
    this.confirmedItems = const [],
  });

  final Recipe recipe;
  final String question;
  final RecipeSwapCoach? coach;
  final List<String> confirmedItems;

  @override
  State<RecipeSwapSheet> createState() => _RecipeSwapSheetState();
}

class _RecipeSwapSheetState extends State<RecipeSwapSheet> {
  CoachLiteAnswer? _answer;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final coach = widget.coach;
    if (coach != null && widget.recipe.steps.isNotEmpty) {
      unawaited(_ask(coach));
    }
  }

  Future<void> _ask(RecipeSwapCoach coach) async {
    final lite = coach.coachLite;
    // Bind to the session this question was asked under.
    final sessionId = coach.sessionId();
    final step = widget.recipe.steps.first;
    setState(() => _busy = true);
    CoachLiteAnswer answer;
    try {
      answer = await lite.ask(
        question: widget.question,
        step: step,
        recipe: widget.recipe,
        confirmedFacts: swapContextFacts(widget.recipe, widget.confirmedItems),
        sessionId: sessionId,
        epoch: 0,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Coach Lite could not answer. Try again in a moment.';
      });
      return;
    }
    if (!mounted) return;
    // A newer question or a changed session drops the answer.
    if (coach.sessionId() != sessionId ||
        !lite.isCurrent(
          answer.stamp,
          sessionId: sessionId,
          epoch: 0,
          stepId: step.id,
        )) {
      setState(() {
        _busy = false;
        _error = kSwapStale;
      });
      return;
    }
    setState(() {
      _busy = false;
      _answer = answer;
    });
  }

  @override
  void dispose() {
    // Closing the sheet stops the question; a late answer is not shown.
    if (_busy) widget.coach?.coachLite.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final answer = _answer;
    return SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('swap-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_horiz_rounded, color: Color(0xFF285B43)),
                const SizedBox(width: 8),
                Text(
                  'Find a swap',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (widget.coach == null) ...[
              const Text(kSwapCoachUnavailable, key: ValueKey('swap-offline')),
              const SizedBox(height: 10),
            ],
            _QuestionBubble(widget.question),
            const SizedBox(height: 14),
            if (_busy)
              const Row(
                key: ValueKey('swap-busy'),
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  SizedBox(width: 10),
                  Expanded(child: Text('Coach Lite is thinking…')),
                ],
              ),
            if (_error case final error?)
              Text(error, key: const ValueKey('swap-error')),
            if (answer != null) ..._answerBody(answer),
            const SizedBox(height: 14),
            _Caution(kSwapAllergenCaution),
          ],
        ),
      ),
    );
  }

  List<Widget> _answerBody(CoachLiteAnswer answer) {
    final cards = swapAnswerCards(answer);
    return [
      for (final card in cards)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _AnswerCard(title: card.title, body: card.body),
        ),
      if (answer.handOffToResearch)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            kSwapSourcesLater,
            key: const ValueKey('swap-sources-later'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (answer.legs.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: InferenceSourceBadge(
            key: const ValueKey('swap-source'),
            legs: answer.legs,
            reason: answer.blocked,
          ),
        ),
    ];
  }
}

/// Title and body text of a Coach Lite workspace, in the root's order. The
/// "Needs a source check" notice is dropped when the answer would be handed
/// to research, because the preview does not do that hand-off.
List<({String title, String body})> swapAnswerCards(CoachLiteAnswer answer) {
  final byId = {
    for (final c in answer.components)
      if (c['id'] is String) c['id'] as String: c,
  };
  final order = switch (byId['root']?['children']) {
    final List<dynamic> ids => [for (final id in ids) '$id'],
    _ => [for (final id in byId.keys) id],
  };
  String text(Object? value) => value is String ? value.trim() : '';
  return [
    for (final id in order)
      if (byId[id] case final c?)
        if (c['component'] != 'CookingColumn' &&
            !(id == 'app_sources' && answer.handOffToResearch))
          (
            title: text(c['title']),
            body: [
              text(c['body']),
              if (text(c['observed']).isNotEmpty)
                'What you have: ${text(c['observed'])}',
              if (text(c['target']).isNotEmpty)
                'What to aim for: ${text(c['target'])}',
              if (text(c['cue']).isNotEmpty) 'Look for: ${text(c['cue'])}',
            ].where((s) => s.isNotEmpty).join('\n'),
          ),
  ];
}

class _QuestionBubble extends StatelessWidget {
  const _QuestionBubble(this.question);
  final String question;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      key: const ValueKey('swap-question'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF285B43),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(18),
          topRight: Radius.circular(18),
          bottomLeft: Radius.circular(18),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: Text(
        question,
        style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35),
      ),
    ),
  );
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFE6DDCB)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        if (title.isNotEmpty && body.isNotEmpty) const SizedBox(height: 4),
        if (body.isNotEmpty)
          Text(body, style: const TextStyle(fontSize: 15, height: 1.4)),
      ],
    ),
  );
}

class _Caution extends StatelessWidget {
  const _Caution(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('swap-caution'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF0D6),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          size: 20,
          color: Color(0xFF8A4B00),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFF5C3300), height: 1.35),
          ),
        ),
      ],
    ),
  );
}
