// "What it should look like" on the cooking screen (SS-098).
//
// Reviewed recipes show their pre-made images. AI-drafted recipes get a
// "Show me what it should look like" button that asks the cloud through an
// [IllustrationController]. The controller is owned by the cooking session,
// not by this widget, so its cache and per-session cap survive a layout
// change that rebuilds this widget. Every image carries [kIllustrationLabel]
// and the compare-the-look copy.

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../pantry/recipe_draft.dart' show isDraftRecipe;
import '../trust/trust_labels.dart' show errorLabel;
import 'illustration_controller.dart';
import 'illustration_prompts.dart';
import 'premade_illustrations.dart';

class StepIllustrations extends StatefulWidget {
  const StepIllustrations({
    super.key,
    required this.recipe,
    required this.step,
    required this.sessionId,
    required this.showPlate,
    this.controller,
  });

  final Recipe recipe;
  final RecipeStep step;

  /// Null until the cooking session exists; on-demand requests wait for it.
  final String? sessionId;

  /// Also show the finished plate (the last step, or a finished cook).
  final bool showPlate;

  /// The cooking session's on-demand controller, owned and disposed by the
  /// session. Null in builds without hybrid services (rehearsal), which
  /// then show pre-made images only.
  final IllustrationController? controller;

  @override
  State<StepIllustrations> createState() => _StepIllustrationsState();
}

class _StepIllustrationsState extends State<StepIllustrations> {
  IllustrationController? get _onDemand =>
      isDraftRecipe(widget.recipe) ? widget.controller : null;

  void _bind() {
    final controller = _onDemand;
    if (controller == null) return;
    final session = widget.sessionId;
    if (session == null) {
      controller.endSession();
      return;
    }
    // Binding to the same place again is a no-op, so a rebuilt widget keeps
    // the session's cache, cap and in-flight work.
    controller.bind(
      sessionId: session,
      recipe: widget.recipe,
      stepId: widget.step.id,
    );
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(StepIllustrations oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _onDemand;
    final targets = <IllustrationTarget>[
      StepTarget(widget.step.id),
      if (widget.showPlate) const PlateTarget(),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final target in targets)
          _IllustrationSlot(
            recipe: widget.recipe,
            target: target,
            controller: controller,
          ),
      ],
    );
  }
}

String _title(IllustrationTarget target, IllustrationSubject subject) =>
    switch ((target, subject)) {
      (PlateTarget(), _) => 'The finished plate',
      (_, IllustrationSubject.ingredientsLaidOut) =>
        'The ingredients, laid out',
      _ => 'What it should look like',
    };

/// Beside every bundled image: nothing was generated or sent for it.
const kPremadeSourceCopy =
    'Made ahead with Google AI for this reviewed recipe and shipped with the '
    'app. Nothing was sent for it.';

class _IllustrationSlot extends StatelessWidget {
  const _IllustrationSlot({
    required this.recipe,
    required this.target,
    required this.controller,
  });

  final Recipe recipe;
  final IllustrationTarget target;
  final IllustrationController? controller;

  @override
  Widget build(BuildContext context) {
    final prompt = illustrationPrompt(recipe, target);
    final asset = premadeIllustrationAsset(recipe, target);
    if (asset != null && prompt != null) {
      return IllustrationFrame(
        title: _title(target, prompt.subject),
        prompt: prompt,
        source: kPremadeSourceCopy,
        sourceIcon: Icons.inventory_2_outlined,
        image: Image.asset(
          asset,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    }
    if (prompt == null) {
      // Meat, poultry, fish and eggs are never pictured where doneness could
      // be implied; say why instead of showing nothing.
      return recipeHasAnimalProtein(recipe)
          ? _Note(
              kIllustrationNoDonenessCopy,
              key: ValueKey('${target.key}-no-picture'),
            )
          : const SizedBox.shrink();
    }
    final controller = this.controller;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _onDemand(context, controller, prompt),
    );
  }

  Widget _onDemand(
    BuildContext context,
    IllustrationController controller,
    IllustrationPrompt prompt,
  ) {
    final title = _title(target, prompt.subject);
    final state = controller.stateFor(target);
    switch (state) {
      case IllustrationReady(:final image, :final source):
        return IllustrationFrame(
          title: title,
          prompt: prompt,
          source: source.describe(),
          sourceIcon: Icons.cloud_outlined,
          image: Image.memory(
            image.bytes,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        );
      case IllustrationLoading(:final sending):
        return _Note(
          sending
              ? 'Drawing an AI illustration in the cloud…'
              : 'Waiting for your answer. Nothing is sent until you allow it.',
          busy: true,
          key: const ValueKey('illustration-loading'),
        );
      case IllustrationBlocked(reason: IllustrationBlock.noPicture):
        return _Note(
          illustrationBlockText(IllustrationBlock.noPicture),
          key: const ValueKey('illustration-blocked-noPicture'),
        );
      case IllustrationFailed(:final code):
        return _ask(
          controller,
          prompt,
          label: target is PlateTarget
              ? 'Try again: show the finished plate'
              : 'Try again: show me what it should look like',
          lastOutcome: "Couldn't make an illustration (${errorLabel(code)}).",
        );
      case IllustrationBlocked(:final reason):
        // Recoverable: offline, settings, a declined prompt or the cap. The
        // button follows the live state, so reconnecting offers it again
        // (with a fresh consent prompt).
        return _ask(
          controller,
          prompt,
          lastOutcome: reason == IllustrationBlock.consentDeclined
              ? illustrationBlockText(reason)
              : null,
        );
      case IllustrationIdle():
        // A build without the images route offers nothing to press.
        if (controller.availability() == IllustrationBlock.cloudNotApproved) {
          return const SizedBox.shrink();
        }
        return _ask(controller, prompt);
    }
  }

  Widget _ask(
    IllustrationController controller,
    IllustrationPrompt prompt, {
    String? label,
    String? lastOutcome,
  }) {
    final block = controller.availability();
    return _Ask(
      label:
          label ??
          switch ((target, prompt.subject)) {
            (PlateTarget(), _) => 'Show me the finished plate',
            (_, IllustrationSubject.ingredientsLaidOut) =>
              'Show me the ingredients laid out',
            _ => 'Show me what it should look like',
          },
      notice: block != null ? illustrationBlockText(block) : lastOutcome,
      detail: _detail(controller, prompt),
      onPressed: block == null
          ? () => controller.request(recipe, target)
          : null,
    );
  }

  String _detail(
    IllustrationController controller,
    IllustrationPrompt prompt,
  ) => [
    'Uses Google cloud AI (${controller.model}). '
        '${controller.remaining} of ${controller.cap} left this cook.',
    if (prompt.subject == IllustrationSubject.ingredientsLaidOut)
      kIllustrationNoDonenessCopy,
  ].join(' ');
}

/// An illustration with its label and safety copy.
class IllustrationFrame extends StatelessWidget {
  const IllustrationFrame({
    super.key,
    required this.title,
    required this.prompt,
    required this.image,
    required this.source,
    required this.sourceIcon,
  });

  /// Where this picture came from: shipped with the app, or made just now
  /// in the cloud (from its ledger leg).
  final String source;
  final IconData sourceIcon;

  final String title;
  final IllustrationPrompt prompt;
  final Widget image;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Card(
      key: ValueKey('illustration-${prompt.target.key}'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Semantics(
                    image: true,
                    label: '$title. $kIllustrationLabel.',
                    excludeSemantics: true,
                    child: image,
                  ),
                  const Positioned(
                    left: 8,
                    top: 8,
                    right: 8,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: IllustrationLabelBadge(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  key: const ValueKey('illustration-source'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(sourceIcon, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        source,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(kIllustrationCompareCopy),
                if (prompt.subject == IllustrationSubject.ingredientsLaidOut)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(kIllustrationNoDonenessCopy),
                  ),
                if (prompt.heated)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(kIllustrationHeatCopy),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The visible "AI illustration — not a photo of your food" label.
class IllustrationLabelBadge extends StatelessWidget {
  const IllustrationLabelBadge({super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xE6FFFFFF),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.brush_outlined, size: 16, color: Color(0xFF3A3A3A)),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              kIllustrationLabel,
              style: TextStyle(
                color: Color(0xFF1F1F1F),
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Ask extends StatelessWidget {
  const _Ask({
    required this.label,
    required this.detail,
    required this.onPressed,
    this.notice,
  });
  final String label;
  final String detail;
  final String? notice;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.image_outlined),
          label: Text(label),
        ),
        const SizedBox(height: 4),
        if (notice case final notice?)
          Semantics(liveRegion: true, child: Text(notice)),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key, this.busy = false});
  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}
