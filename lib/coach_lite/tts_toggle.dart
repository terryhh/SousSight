// The speaker toggle on Coach Lite answers (SS-077). Hidden where the
// platform cannot speak. The caption says where the voice runs before the
// cook turns it on.

import 'package:flutter/material.dart';

import 'tts.dart';

String readAloudCaption(VoiceLocality locality) => switch (locality) {
  VoiceLocality.deviceEngine => "Uses this device's text-to-speech voice.",
  VoiceLocality.browserLocal =>
    'Uses a voice your browser reports as on this device.',
  VoiceLocality.browserMayUseNetwork =>
    'This browser may use an online voice service, which would receive the '
        'answer text.',
};

class CoachLiteSpeakerToggle extends StatelessWidget {
  const CoachLiteSpeakerToggle({super.key, required this.speaker});

  final CoachLiteSpeaker speaker;

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
              '${readAloudCaption(speaker.locality)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );
    },
  );
}
