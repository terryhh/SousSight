// The speaker toggle on Coach Lite answers (SS-077). Hidden where the
// platform cannot speak. The caption says where the voice runs before the
// cook turns it on.

import 'package:flutter/material.dart';

import 'tts.dart';

/// The caption, given where the voice runs and whether the cook's
/// local-only setting applies to Coach Lite.
/// In [practice] mode read-aloud is always local-only and says so.
String readAloudCaption(
  VoiceLocality locality, {
  bool localOnly = false,
  bool silencedForLocalOnly = false,
  bool practice = false,
}) {
  if (practice) {
    return silencedForLocalOnly ||
            locality == VoiceLocality.browserMayUseNetwork
        ? "Practice mode: this browser reports no voice on this device, so "
              "answers aren't read aloud. Nothing is sent to an online voice."
        : 'Practice mode: only a voice on this device is used, never an '
              'online one.';
  }
  if (localOnly &&
      (silencedForLocalOnly ||
          locality == VoiceLocality.browserMayUseNetwork)) {
    return "On-device only is on and this browser reports no on-device "
        "voice, so answers aren't read aloud.";
  }
  return _localityCaption(locality);
}

String _localityCaption(VoiceLocality locality) => switch (locality) {
  VoiceLocality.deviceEngine => "Uses this device's text-to-speech voice.",
  VoiceLocality.browserLocal =>
    'Uses a voice your browser reports as on this device.',
  VoiceLocality.browserMayUseNetwork =>
    'This browser may use an online voice service, which would receive the '
        'answer text.',
};

class CoachLiteSpeakerToggle extends StatelessWidget {
  const CoachLiteSpeakerToggle({
    super.key,
    required this.speaker,
    this.practice = false,
  });

  final CoachLiteSpeaker speaker;

  /// Practice mode: the caption says read-aloud is local-only.
  final bool practice;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: speaker,
    builder: (context, _) {
      if (!speaker.available) return const SizedBox.shrink();
      final on = speaker.enabled;
      return Row(
        children: [
          IconButton(
            key: const ValueKey('coach-lite-read-aloud'),
            isSelected: on,
            icon: const Icon(Icons.volume_off_outlined),
            selectedIcon: const Icon(Icons.volume_up),
            tooltip: on ? 'Stop reading answers aloud' : 'Read answers aloud',
            onPressed: () => speaker.setEnabled(!on),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '${on ? 'Reading answers aloud.' : 'Read answers aloud: off.'} '
              '${readAloudCaption(speaker.locality, localOnly: speaker.localOnly, silencedForLocalOnly: speaker.silencedForLocalOnly, practice: practice)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );
    },
  );
}
