// Shared wording and colours for the trust surface (SS-070).

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';

/// Short label for where one leg ran. [localModel] is shown for on-device
/// legs: the observed model label if the SDK gave one, else the model family
/// from capabilities, else nothing.
String provenanceLabel(Provenance provenance, {String? localModel}) =>
    switch (provenance) {
      Provenance.sdkOnDevice =>
        localModel == null || localModel.isEmpty
            ? 'On this device'
            : 'On this device · $localModel',
      Provenance.sdkCloud => 'Cloud · Gemini',
      Provenance.cloudAdapter => 'Cloud',
      Provenance.simulated => 'Simulated',
      Provenance.unknown => 'May have been sent',
    };

/// Longer explanation used in the details sheet.
String provenanceExplanation(Provenance provenance) => switch (provenance) {
  Provenance.sdkOnDevice =>
    'The Firebase AI Logic SDK reported that this ran on your device.',
  Provenance.sdkCloud =>
    'The Firebase AI Logic SDK reported that this ran on Gemini in the cloud.',
  Provenance.cloudAdapter =>
    "Sent to the cloud by SousSight's own Firebase AI Logic client.",
  Provenance.simulated =>
    'Simulated for this rehearsal. No model ran and nothing was sent.',
  Provenance.unknown =>
    "This was allowed to leave, then stopped with an error, so we can't "
        "tell whether it was sent.",
};

IconData provenanceIcon(Provenance provenance) => switch (provenance) {
  Provenance.sdkOnDevice => Icons.phone_android,
  Provenance.sdkCloud || Provenance.cloudAdapter => Icons.cloud_outlined,
  Provenance.simulated => Icons.science_outlined,
  Provenance.unknown => Icons.help_outline,
};

/// Background, border and foreground colours, matching the cooking theme.
({Color background, Color border, Color foreground}) provenanceColors(
  Provenance provenance,
) => switch (provenance) {
  Provenance.sdkOnDevice => (
    background: const Color(0xffe4ebdf),
    border: const Color(0xff285b43),
    foreground: const Color(0xff1c4231),
  ),
  Provenance.sdkCloud || Provenance.cloudAdapter => (
    background: const Color(0xffe3ecf5),
    border: const Color(0xff3c6a92),
    foreground: const Color(0xff1f3d57),
  ),
  Provenance.simulated => (
    background: const Color(0xfffff0d6),
    border: const Color(0xffd08a1e),
    foreground: const Color(0xff5c3300),
  ),
  Provenance.unknown => (
    background: const Color(0xfffbe8c9),
    border: const Color(0xffbf5b32),
    foreground: const Color(0xff6b2a10),
  ),
};

/// Whether the SDK or our own client reported that the leg went to the cloud.
bool reportedAsSent(Provenance provenance) =>
    provenance == Provenance.sdkCloud || provenance == Provenance.cloudAdapter;

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
  'coach_lite': 'Coach Lite',
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
  HybridErrorCode.quota => 'cloud allowance used up',
  HybridErrorCode.attestation => "app couldn't be verified",
  HybridErrorCode.busy => 'device was busy',
  HybridErrorCode.blocked => 'blocked by safety filters',
  HybridErrorCode.unavailable => 'model not available',
  HybridErrorCode.unsupportedInput => "couldn't take this input",
  HybridErrorCode.unsupportedMode => "couldn't run that way",
  HybridErrorCode.failed => "didn't finish",
};
