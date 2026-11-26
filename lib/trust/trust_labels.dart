// Shared wording and colours for the trust surface (SS-070).

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';

/// What one leg amounts to for the cook. Derived from the whole leg, not
/// provenance alone: an `unknown` leg could only have left the device if it
/// was allowed to.
enum LegOutcome {
  /// The SDK reported an on-device run.
  onDevice,

  /// The SDK reported a cloud run.
  cloudSdk,

  /// SousSight's own cloud client sent it.
  cloudAdapter,

  /// Allowed to leave, then failed: whether it was sent is not known.
  maybeSent,

  /// Not allowed to leave, and failed or was blocked: nothing left.
  notFinishedLocal,

  /// Rehearsal only.
  simulated,
}

LegOutcome legOutcome(InferenceLeg leg) => switch (leg.provenance) {
  Provenance.sdkOnDevice => LegOutcome.onDevice,
  Provenance.sdkCloud => LegOutcome.cloudSdk,
  Provenance.cloudAdapter => LegOutcome.cloudAdapter,
  Provenance.simulated => LegOutcome.simulated,
  Provenance.unknown =>
    // A bridge's own pre-send refusal proves nothing left; any other error
    // on a request allowed to leave does not.
    leg.transferPermitted && leg.error != HybridErrorCode.rejectedBeforeSend
        ? LegOutcome.maybeSent
        : LegOutcome.notFinishedLocal,
};

/// What practice mode (rehearsal) calls a pretend answer, on every surface.
const kPracticeLabel = 'Practice mode (pretend answers)';

/// Short, plain label for one outcome. Model names stay out of it (SS-089):
/// they appear only in the details sheet, via [legModelName].
String outcomeLabel(LegOutcome outcome) => switch (outcome) {
  LegOutcome.onDevice => 'On this device',
  LegOutcome.cloudSdk ||
  LegOutcome.cloudAdapter => "Sent online to Google's AI",
  LegOutcome.maybeSent => 'May have been sent',
  // Also a local-only leg that is still running: never "didn't finish".
  LegOutcome.notFinishedLocal =>
    'Running or stopped · nothing left this device',
  LegOutcome.simulated => kPracticeLabel,
};

/// Short label for one leg.
String legLabel(InferenceLeg leg) => outcomeLabel(legOutcome(leg));

/// The model that ran an on-device leg, for the details sheet only: the
/// observed model label if the SDK gave one, else [localModel] (the family
/// from capabilities), else null. Null for every other outcome.
String? legModelName(InferenceLeg leg, {String? localModel}) {
  if (legOutcome(leg) != LegOutcome.onDevice) return null;
  final name = leg.modelLabel ?? localModel;
  return name == null || name.isEmpty ? null : name;
}

/// The explanation for one leg. Any statement about sending comes from the
/// leg's transfer facts, never from an on-device result alone: a leg that
/// was allowed to leave may have been sent even if the answer came from the
/// device (the #265 rule, Codex #221).
String legExplanation(InferenceLeg leg) {
  final outcome = legOutcome(leg);
  final base = outcomeExplanation(outcome);
  if (outcome != LegOutcome.onDevice) return base;
  return leg.transferPermitted
      ? '$base It was allowed to go online, so it may also have been sent.'
      : '$base It was not allowed to leave this device.';
}

/// Longer explanation used in the details sheet.
String outcomeExplanation(LegOutcome outcome) => switch (outcome) {
  // Makes no transfer claim: see [legExplanation] (Codex #221).
  LegOutcome.onDevice =>
    "Google's AI tools reported that this ran on your device.",
  LegOutcome.cloudSdk =>
    "Google's AI tools reported that this was sent online to Google's AI.",
  LegOutcome.cloudAdapter => "SousSight sent this online to Google's AI.",
  LegOutcome.maybeSent =>
    // Also shown while a request is still running (unknown provenance, no
    // error yet), so it must not say the request stopped.
    'This was allowed to leave this device and is not confirmed either way: '
        'it may still be running, or it stopped before saying whether it was '
        'sent.',
  LegOutcome.notFinishedLocal =>
    // Also a request that was allowed to leave but refused before sending,
    // so it must not claim the request was not allowed to leave.
    'This is still running, or it stopped without finishing. Nothing left '
        'this device: it was not allowed to leave, or it was refused before '
        'sending.',
  LegOutcome.simulated =>
    'Practice mode: a pretend answer. No AI ran and nothing was sent.',
};

/// One icon per outcome. On-device uses the same chip glyph as the
/// "On-device AI" button so the two read as one idea.
IconData outcomeIcon(LegOutcome outcome) => switch (outcome) {
  LegOutcome.onDevice => Icons.memory,
  LegOutcome.cloudSdk || LegOutcome.cloudAdapter => Icons.cloud,
  LegOutcome.maybeSent => Icons.question_mark,
  LegOutcome.notFinishedLocal => Icons.block,
  LegOutcome.simulated => Icons.science_outlined,
};

/// Background, border and foreground colours, matching the cooking theme.
({Color background, Color border, Color foreground}) outcomeColors(
  LegOutcome outcome,
) => switch (outcome) {
  LegOutcome.onDevice => (
    background: const Color(0xffe4ebdf),
    border: const Color(0xff285b43),
    foreground: const Color(0xff1c4231),
  ),
  LegOutcome.cloudSdk || LegOutcome.cloudAdapter => (
    background: const Color(0xffe3ecf5),
    border: const Color(0xff3c6a92),
    foreground: const Color(0xff1f3d57),
  ),
  LegOutcome.maybeSent => (
    background: const Color(0xfffbe8c9),
    border: const Color(0xffbf5b32),
    foreground: const Color(0xff6b2a10),
  ),
  LegOutcome.notFinishedLocal => (
    background: const Color(0xffefede8),
    border: const Color(0xff6f6a60),
    foreground: const Color(0xff3d3a34),
  ),
  LegOutcome.simulated => (
    background: const Color(0xfffff0d6),
    border: const Color(0xffd08a1e),
    foreground: const Color(0xff5c3300),
  ),
};

/// Whether the SDK or our own client reported that the leg went to the cloud.
bool reportedAsSent(LegOutcome outcome) =>
    outcome == LegOutcome.cloudSdk || outcome == LegOutcome.cloudAdapter;

String dataKindLabel(DataKind kind) => switch (kind) {
  DataKind.text => 'text',
  DataKind.image => 'photo',
  DataKind.audio => 'voice clip',
  DataKind.location => 'location',
};

const _kindOrder = [
  DataKind.image,
  DataKind.audio,
  DataKind.location,
  DataKind.text,
];

/// [kinds] in display order: photo, voice clip, location, text.
List<DataKind> orderedDataKinds(Set<DataKind> kinds) => [
  for (final k in _kindOrder)
    if (kinds.contains(k)) k,
];

/// "photo and text", "photo, voice clip and text".
String dataKindsPhrase(Set<DataKind> kinds) {
  final labels = [
    for (final k in _kindOrder)
      if (kinds.contains(k)) dataKindLabel(k),
  ];
  if (labels.isEmpty) return 'no data';
  if (labels.length == 1) return labels.single;
  return '${labels.sublist(0, labels.length - 1).join(', ')} and ${labels.last}';
}

const Map<String, String> featureLabels = {
  'pantry_scan': 'Pantry scan',
  'pantry_voice': 'Pantry voice note',
  'recipe_draft': 'Recipe draft',
  'local_watch': 'Watch my food',
  'local_watch_cloud_check': 'Photo check online',
  'coach_lite': 'Typed question',
  'label_check': 'Label check',
  'research': 'Research',
  'nearby': 'Nearby stores',
  'live': 'Live coach',
};

String featureLabel(String feature) {
  final known = featureLabels[feature];
  if (known != null) return known;
  final words = feature.replaceAll('_', ' ').trim();
  if (words.isEmpty) return 'Feature';
  return words[0].toUpperCase() + words.substring(1);
}

String errorLabel(HybridErrorCode error) => switch (error) {
  HybridErrorCode.timeout => 'took too long',
  HybridErrorCode.cancelled => 'stopped',
  HybridErrorCode.network => 'connection problem',
  HybridErrorCode.quota => 'online allowance used up',
  HybridErrorCode.attestation => "app couldn't be verified",
  HybridErrorCode.busy => 'device was busy',
  HybridErrorCode.blocked => 'blocked by safety filters',
  HybridErrorCode.unavailable => 'model not available',
  HybridErrorCode.unsupportedInput => "couldn't take this input",
  HybridErrorCode.unsupportedMode => "couldn't run that way",
  HybridErrorCode.failed => "didn't finish",
  HybridErrorCode.rejectedBeforeSend => 'refused before sending',
};
