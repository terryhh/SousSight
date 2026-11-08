import 'package:flutter/material.dart';

/// Steps shown in the "From pantry to plate" section.
const howItWorksSteps = [
  ('Scan', 'Show or tell SousSight what you got from the pantry.'),
  ('Pick a meal', 'Choose a simple recipe that fits what you have.'),
  (
    'Cook with a live coach',
    'Talk and show your food; the coach answers by voice and builds helpful panels.',
  ),
  (
    'Ask & research',
    'Questions get grounded answers from Google Search; the coach asks you when it needs facts.',
  ),
  (
    'Text the household',
    'Review a short "dinner is ready" text before it is sent.',
  ),
];

/// Technologies listed in the "Built with" section.
const howItWorksTechnologies = [
  'Gemini Live API (voice + vision, function calling)',
  'Gemini Flash via Firebase AI Logic (structured output, Grounding with Google Search, Grounding with Google Maps)',
  'Flutter GenUI / A2UI',
  'Firebase Auth + App Check (reCAPTCHA Enterprise)',
  'Cloud Firestore',
  'Cloud Functions on Cloud Run',
  'Secret Manager',
  'Firebase Hosting',
  'Vonage Messages API with signed status webhooks',
];

/// Small info button that opens the How it works sheet.
class HowItWorksButton extends StatelessWidget {
  const HowItWorksButton({super.key, this.isDemo = false});

  final bool isDemo;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('how-it-works-button'),
    tooltip: 'How it works',
    icon: const Icon(Icons.info_outline),
    onPressed: () => showHowItWorks(context, isDemo: isDemo),
  );
}

Future<void> showHowItWorks(BuildContext context, {bool isDemo = false}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, controller) =>
            HowItWorksSheet(isDemo: isDemo, controller: controller),
      ),
    );

class HowItWorksSheet extends StatelessWidget {
  const HowItWorksSheet({super.key, this.isDemo = false, this.controller});

  final bool isDemo;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
    Widget bullet(String text, {IconData icon = Icons.check_circle_outline}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(text)),
            ],
          ),
        );

    return ListView(
      key: const ValueKey('how-it-works-sheet'),
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Semantics(
          header: true,
          child: Text(
            'How SousSight works',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (isDemo) ...[
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0D6),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.science_outlined, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Simulated mode: this rehearsal does not use the camera, '
                      'microphone, Gemini, or Vonage. Responses are scripted and '
                      'no messages are sent.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        heading('From pantry to plate'),
        for (final (index, (title, body)) in howItWorksSteps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$title\n',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: body),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        heading('Built with'),
        for (final tech in howItWorksTechnologies)
          bullet(tech, icon: Icons.build_circle_outlined),
        heading('Your privacy'),
        bullet(
          'Pantry photos, voice clips and typed lists you choose to send go to '
          'Google Gemini once to identify ingredients. During cooking, camera '
          'and audio stream to Gemini only while the live coach is on. '
          'SousSight does not store photos, audio or transcripts; only your '
          'confirmed cooking progress is saved.',
          icon: Icons.lock_outline,
        ),
        bullet('No account needed.', icon: Icons.lock_outline),
        heading('Safety'),
        bullet('You confirm everything; the coach suggests, you decide.'),
        bullet(
          "Vision can't certify internal temperature, freshness, or allergens. "
          'Use a thermometer and read package labels.',
          icon: Icons.warning_amber_rounded,
        ),
        bullet('Nothing is sent without your review.'),
        heading('Under the hood'),
        _DevFestXRayCard(isDemo: isDemo),
      ],
    );
  }
}

class _DevFestXRayCard extends StatelessWidget {
  const _DevFestXRayCard({required this.isDemo});

  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('devfest-x-ray-card'),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.terminal, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ARCHITECTURE AT A GLANCE',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _diagRow(
              'Gemini Live Protocol',
              isDemo ? 'Rehearsal Fake' : 'WebSocket w/ Ephemeral Auth',
            ),
            _diagRow('Audio Capture & Playback', '16 kHz Mono In · 24 kHz PCM Out'),
            _diagRow('Video Frame Ingestion', '1 fps JPEG (≤768px, client-rendered)'),
            _diagRow(
              'GenUI / A2UI Safety',
              'Schema-validated trusted catalog; no model-written code or HTML',
            ),
            _diagRow(
              'Grounding Engines',
              'Google Search (cited sources) & Google Maps (grounded places)',
            ),
            _diagRow('Client Secret Isolation', 'Zero long-lived keys in web bundle'),
            _diagRow(
              'Budget Guardrail',
              '8 min session cap · 3 min idle watchdog · 15s watch',
            ),
          ],
        ),
      ),
    );
  }

  Widget _diagRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '• $label',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Text(
            value,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
      ],
    ),
  );
}
