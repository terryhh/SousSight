// The label-check sheet (DESIGN.md §6 SS-069). Says only what the label
// mentions; never that a food is free of an allergen or safe.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../trust/inference_source_badge.dart';
import 'label_check.dart';
import 'label_check_controller.dart';

/// Opens the sheet with [controller] and disposes the controller when the
/// sheet closes. Create a new controller for each opening.
///
/// [takePhoto] returns one JPEG (at most 1 MB and 768 px on its longer side),
/// or null if the cook backed out. Without it only the typed path is shown.
Future<void> showLabelCheckSheet(
  BuildContext context, {
  required LabelCheckController controller,
  Future<Uint8List?> Function()? takePhoto,
}) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: LabelCheckSheet(controller: controller, takePhoto: takePhoto),
      ),
    );
  } finally {
    controller.dispose();
  }
}

class LabelCheckSheet extends StatefulWidget {
  const LabelCheckSheet({super.key, required this.controller, this.takePhoto});

  final LabelCheckController controller;
  final Future<Uint8List?> Function()? takePhoto;

  @override
  State<LabelCheckSheet> createState() => _LabelCheckSheetState();
}

class _LabelCheckSheetState extends State<LabelCheckSheet> {
  final _typed = TextEditingController();
  bool _typing = false;

  LabelCheckController get _c => widget.controller;

  @override
  void dispose() {
    // Closing the sheet cancels the check; a late result is dropped.
    _c.close();
    _typed.dispose();
    super.dispose();
  }

  /// The controller owns the capture, so a photo that arrives after the sheet
  /// closed, the session changed or a newer check started is discarded.
  Future<void> _photo() async {
    final take = widget.takePhoto;
    if (take == null) return;
    await _c.captureAndCheck(take);
  }

  void _showTyping() => setState(() => _typing = true);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final busy = _c.busy;
        return ListView(
          key: const ValueKey('label-check-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          children: [
            Semantics(
              header: true,
              child: Text(
                'Label check',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Show me a package's allergen statement and I'll tell you which "
              'allergens it mentions.',
            ),
            const SizedBox(height: 16),
            _HouseholdPicker(controller: _c),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (widget.takePhoto != null)
                  FilledButton.icon(
                    key: const ValueKey('label-take-photo'),
                    onPressed: busy ? null : _photo,
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Take a photo'),
                  ),
                if (!_typing)
                  OutlinedButton.icon(
                    key: const ValueKey('label-type-instead'),
                    onPressed: busy ? null : _showTyping,
                    icon: const Icon(Icons.keyboard_outlined),
                    label: const Text('Type the label'),
                  ),
              ],
            ),
            if (_typing) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('label-typed-field'),
                controller: _typed,
                enabled: !busy,
                minLines: 2,
                maxLines: 6,
                maxLength: kMaxTypedLabelLength,
                decoration: const InputDecoration(
                  labelText: 'Ingredients or allergen statement',
                  hintText: 'e.g. Contains: milk, soy. May contain peanuts.',
                  border: OutlineInputBorder(),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  key: const ValueKey('label-check-typed'),
                  onPressed: busy ? null : () => _c.checkTyped(_typed.text),
                  child: const Text('Check typed label'),
                ),
              ),
            ],
            const SizedBox(height: 16),
            ..._status(context),
          ],
        );
      },
    );
  }

  List<Widget> _status(BuildContext context) {
    final c = _c;
    final notice = c.notice;
    final out = <Widget>[];
    if (c.busy) {
      out.addAll([
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Text(switch (c.phase) {
          LabelCheckPhase.awaitingConsent => 'Waiting for your answer…',
          LabelCheckPhase.capturing => 'Taking the photo…',
          LabelCheckPhase.checking => 'Reading the label…',
          _ => 'Getting ready…',
        }),
      ]);
    }
    if (c.phase == LabelCheckPhase.awaitingChoice) {
      out.add(
        _ChoiceCard(
          notice: notice,
          typedAvailable: c.typedPathAvailable,
          cloudOffered: c.cloudPhotoOffered,
          onType: () {
            c.discardPhoto();
            _showTyping();
          },
          onSend: c.sendPhotoToCloud,
          onDiscard: c.discardPhoto,
        ),
      );
      return out;
    }
    final result = c.result;
    if (result != null) {
      out.add(_ReadingView(reading: result.reading, matches: c.matches));
    } else if (notice != null) {
      out.add(Text(notice, key: const ValueKey('label-notice')));
    }
    if (c.legs.isNotEmpty) {
      out.addAll([
        const SizedBox(height: 12),
        InferenceSourceBadge(
          legs: c.legs,
          localModelFamily: c.localModelFamily,
          reason: c.blockedReason,
        ),
      ]);
    }
    return out;
  }
}

class _HouseholdPicker extends StatelessWidget {
  const _HouseholdPicker({required this.controller});

  final LabelCheckController controller;

  @override
  Widget build(BuildContext context) {
    final household = controller.household;
    final selected = household.allergens;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Your household's allergens",
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final allergen in kLabelAllergens)
              FilterChip(
                key: ValueKey('household-$allergen'),
                label: Text(allergen),
                selected: selected.contains(allergen),
                onSelected: (value) => household.setAllergen(allergen, value),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(kHouseholdStaysHereWording, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.notice,
    required this.typedAvailable,
    required this.cloudOffered,
    required this.onType,
    required this.onSend,
    required this.onDiscard,
  });

  final String? notice;
  final bool typedAvailable;
  final bool cloudOffered;
  final VoidCallback onType;
  final Future<void> Function() onSend;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('label-choice'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (notice != null) Text(notice!),
            const SizedBox(height: 8),
            Text(
              typedAvailable
                  ? "You can type the label instead. I'll check it with this "
                        "device's model."
                  : "Typed labels can't run on this device either.",
              style: theme.textTheme.bodyMedium,
            ),
            if (cloudOffered)
              Text(
                'Or send just this one photo to Gemini in the cloud. '
                "I'll ask before anything is sent.",
                style: theme.textTheme.bodyMedium,
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (typedAvailable)
                  FilledButton(
                    key: const ValueKey('label-choice-type'),
                    onPressed: onType,
                    child: const Text('Type the label'),
                  ),
                if (cloudOffered)
                  OutlinedButton.icon(
                    key: const ValueKey('label-choice-cloud'),
                    onPressed: () => unawaited(onSend()),
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Send this photo to the cloud'),
                  ),
                TextButton(
                  key: const ValueKey('label-choice-discard'),
                  onPressed: onDiscard,
                  child: const Text('Discard photo'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadingView extends StatelessWidget {
  const _ReadingView({required this.reading, required this.matches});

  final LabelReading reading;
  final List<String> matches;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (reading.saysNothingFound) {
      return Text(
        kUnreadableWording,
        key: const ValueKey('label-unreadable'),
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (matches.isNotEmpty) ...[
          Semantics(
            liveRegion: true,
            child: DecoratedBox(
              key: const ValueKey('label-matches'),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'On your household list: ${matches.join(', ')}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          '$kMentionsPrefix${reading.allergensMentioned.join(', ')}.',
          key: const ValueKey('label-mentions'),
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (reading.quote.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'What I read: “${reading.quote}”',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
        const SizedBox(height: 8),
        const Text(kReadItYourselfWording),
      ],
    );
  }
}
