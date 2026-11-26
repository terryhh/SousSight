import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart';
import '../live/live_backend.dart';

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
  'Firebase AI Logic hybrid inference (on-device Gemini Nano in Chrome, Gemini in the cloud)',
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
  const HowItWorksSheet({
    super.key,
    this.isDemo = false,
    this.controller,
    this.cloudRoutes,
    this.liveBackend,
  });

  final bool isDemo;
  final ScrollController? controller;

  /// Defaults: this build's CLOUD_ROUTES and LIVE_BACKEND.
  final CloudRoutes? cloudRoutes;
  final LiveBackend? liveBackend;

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
          'Pantry photos, voice clips and typed lists are read on this device '
          'when the on-device model can, and go to Google cloud AI only where '
          '"Where the AI runs" below says so. Camera and audio stream to Gemini '
          'only while the Live coach is on. SousSight does not store photos, '
          'audio or transcripts; only your confirmed cooking progress is saved.',
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
        heading('Where the AI runs'),
        HybridRoutingSection(
          isDemo: isDemo,
          cloudRoutes: cloudRoutes ?? CloudRoutes.fromEnvironment(),
          liveBackend: liveBackend ?? configuredLiveBackend,
        ),
      ],
    );
  }
}

/// One row of the "Where the AI runs" section.
typedef RoutingRow = ({String feature, String where});

const _cloud = 'Google cloud AI (Gemini, through Firebase AI Logic)';

/// What runs on this device and what may go to the cloud, derived from the
/// dispatcher's routing table ([featureRoutes]), the cloud routes this build
/// approves, and the Live backend it was compiled with. Never hand-written,
/// so it cannot drift from what the code does.
List<RoutingRow> hybridRoutingRows({
  required CloudRoutes cloudRoutes,
  required LiveBackend liveBackend,
}) {
  final cloudOk = cloudRoutes.allows(CloudRoute.hybridFallback);
  String describe(FeatureRoute route) {
    final retry = route.semanticRetry && cloudOk
        ? ' If an on-device answer fails its checks, it is retried once in '
              'the cloud.'
        : '';
    final ask = switch (route.consent) {
      UploadConsent.always => ' Only after you allow that exact request.',
      UploadConsent.media => ' Photos are sent only after you allow them.',
      UploadConsent.none => ' The button says so before you send.',
    };
    switch (route.defaultMode) {
      case HybridMode.onlyInCloud || HybridMode.preferInCloud:
        return cloudOk
            ? '$_cloud.$ask'
            : 'Off in this build (needs the cloud).';
      case HybridMode.onlyOnDevice when !route.cloudWhenLocalCannot:
        return 'On this device only.$retry';
      case HybridMode.onlyOnDevice:
        return cloudOk
            ? 'On this device. If this device cannot run it, $_cloud.$ask'
            : 'On this device only.';
      case HybridMode.preferOnDevice:
        return cloudOk
            ? 'On this device when the on-device model is ready; otherwise '
                  '$_cloud.$ask$retry'
            : 'On this device only (cloud help is off in this build).';
    }
  }

  const shown = [
    ('pantry_scan', 'Pantry scan (typed list, photo)'),
    ('pantry_voice', 'Pantry voice note'),
    ('recipe_draft', 'Recipe draft'),
    ('local_watch', 'Watch my food'),
    ('local_watch_cloud_check', 'Watch: "Ask the cloud about this photo"'),
    ('coach_lite', 'Coach Lite (typed questions)'),
    ('label_check', 'Label check'),
  ];
  return [
    for (final (feature, label) in shown)
      (feature: label, where: describe(featureRouteFor(feature))),
    (
      feature: 'Live coach (voice and camera)',
      where: switch (liveBackend) {
        LiveBackend.aiLogic when cloudRoutes.allows(CloudRoute.live) =>
          'Google cloud (Gemini Live, through Firebase AI Logic). Camera and '
              'microphone stream only while you have it on.',
        LiveBackend.ephemeral =>
          'Google cloud (Gemini Live, direct connection). Camera and '
              'microphone stream only while you have it on.',
        _ => 'Off in this build. Typed questions go to Coach Lite.',
      },
    ),
    (
      feature: 'Grounded research',
      where: cloudRoutes.allows(CloudRoute.research)
          ? 'Google cloud with Google Search grounding, only when you or the '
                'coach ask a factual question.'
          : 'Off in this build.',
    ),
    (
      feature: 'Nearby stores',
      where:
          'Google cloud with Google Maps grounding, only when you ask. Sends '
          'your approximate location once.',
    ),
  ];
}

class HybridRoutingSection extends StatelessWidget {
  const HybridRoutingSection({
    super.key,
    required this.isDemo,
    required this.cloudRoutes,
    required this.liveBackend,
  });

  final bool isDemo;
  final CloudRoutes cloudRoutes;
  final LiveBackend liveBackend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = hybridRoutingRows(
      cloudRoutes: cloudRoutes,
      liveBackend: liveBackend,
    );
    return Column(
      key: const ValueKey('how-it-works-hybrid'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isDemo
              ? 'In this rehearsal everything is simulated. In the real app:'
              : 'SousSight runs AI on this device first, with Gemini Nano in '
                    "Chrome, and uses the cloud only where it says so. Each "
                    'answer shows where it ran; "What was sent" lists every '
                    'request in this session. Your "keep on this device" '
                    'switches in On-device AI override everything below.',
        ),
        const SizedBox(height: 12),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${row.feature}\n',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: row.where),
                ],
              ),
              style: theme.textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }
}
