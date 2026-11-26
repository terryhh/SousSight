import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart';
import '../data/dinner_mode.dart';
import '../live/live_backend.dart';
import 'centered_scroll.dart';

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
  'Firebase AI Logic hybrid inference (on-device Gemini Nano in Chrome, Gemini in the cloud)',
  'Vonage Messages API with signed status webhooks',
];

/// [howItWorksSteps] for this build: without a Live coach the cooking step
/// never promises one (SS-089).
List<(String, String)> howItWorksStepsFor({required bool live}) => [
  for (final step in howItWorksSteps)
    if (!live && step.$1 == 'Cook with a live coach')
      (
        'Cook step by step',
        'Follow each step with real timers and type a question any time; '
            'where this device supports it, the camera can watch for a '
            "step's visible cue.",
      )
    else
      step,
];

/// [howItWorksTechnologies] actually in this build: Gemini Live only with a
/// Live backend, Vonage only when DINNER_MODE is real (SS-089).
List<String> howItWorksTechnologiesFor({
  required bool live,
  required bool vonage,
}) => [
  for (final tech in howItWorksTechnologies)
    if ((live || !tech.startsWith('Gemini Live API')) &&
        (vonage || !tech.startsWith('Vonage')))
      tech,
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
      constraints: fullWidthSheet,
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
    this.dinnerMode,
  });

  /// Defaults to this build's DINNER_MODE.
  final DinnerMode? dinnerMode;

  /// Whether this build can start a Live coach: the same rule as the Start
  /// control (an AI Logic backend also needs the `live` cloud route).
  /// Rehearsal always has its simulated Live coach (Codex #221).
  bool get _liveAvailable {
    if (isDemo) return true;
    return switch (liveBackend ?? configuredLiveBackend) {
      LiveBackend.none => false,
      LiveBackend.ephemeral => true,
      LiveBackend.aiLogic =>
        (cloudRoutes ?? CloudRoutes.fromEnvironment()).allows(CloudRoute.live),
    };
  }

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

    return CenteredListView(
      key: const ValueKey('how-it-works-sheet'),
      controller: controller,
      bottom: 32,
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
        for (final (index, (title, body)) in howItWorksStepsFor(
          live: _liveAvailable,
        ).indexed)
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
        for (final tech in howItWorksTechnologiesFor(
          live: _liveAvailable,
          vonage:
              !isDemo &&
              (dinnerMode ?? configuredDinnerMode) == DinnerMode.real,
        ))
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

/// The dispatcher features the "Where the AI runs" section lists, with a
/// long label (feature-by-feature rows) and a short one (the two columns).
const _routedFeatures = [
  ('pantry_scan', 'Pantry scan (typed list, photo)', 'Pantry scan'),
  ('pantry_voice', 'Pantry voice note', 'Pantry voice note'),
  ('recipe_draft', 'Recipe draft', 'Recipe draft'),
  ('local_watch', 'Watch my food', 'Watch my food'),
  (
    'local_watch_cloud_check',
    'Watch: "Ask the cloud about this photo"',
    'Watch: one photo you choose',
  ),
  ('coach_lite', 'Coach Lite (typed questions)', 'Coach Lite'),
  ('label_check', 'Label check', 'Label check'),
];

/// One entry in a column of the two-column view.
typedef RoutingEntry = ({String feature, String note});

/// The two-column view of "Where the AI runs": what can run on this device,
/// what can go to Google cloud, and what is off in this build. Generated
/// from the same routing table as [hybridRoutingRows]; a feature appears in
/// the cloud column only if this build's routes let it reach the cloud.
({List<RoutingEntry> onDevice, List<RoutingEntry> cloud, List<String> off})
hybridRoutingColumns({
  required CloudRoutes cloudRoutes,
  required LiveBackend liveBackend,
}) {
  final cloudOk = cloudRoutes.allows(CloudRoute.hybridFallback);
  final onDevice = <RoutingEntry>[];
  final cloud = <RoutingEntry>[];
  final off = <String>[];
  for (final (feature, _, label) in _routedFeatures) {
    final route = featureRouteFor(feature);
    final ask = switch (route.consent) {
      UploadConsent.always => ' You allow each one.',
      UploadConsent.media => ' Photos only after you allow them.',
      UploadConsent.none => ' Labelled before you send.',
    };
    switch (route.defaultMode) {
      case HybridMode.onlyInCloud || HybridMode.preferInCloud:
        if (cloudOk) {
          cloud.add((feature: label, note: 'Always in the cloud.$ask'));
        } else {
          off.add(label);
        }
      case HybridMode.onlyOnDevice when !route.cloudWhenLocalCannot:
        onDevice.add((feature: label, note: 'Always here.'));
        if (route.semanticRetry && cloudOk) {
          cloud.add((
            feature: label,
            note: 'Once, only if the on-device answer fails its checks.',
          ));
        }
      case HybridMode.onlyOnDevice:
        onDevice.add((
          feature: label,
          note: cloudOk ? 'First choice.' : 'Always here.',
        ));
        if (cloudOk) {
          cloud.add((
            feature: label,
            note: "Only if this device can't run it.$ask",
          ));
        }
      case HybridMode.preferOnDevice:
        onDevice.add((
          feature: label,
          note: cloudOk ? 'When the model is ready.' : 'Always here.',
        ));
        if (cloudOk) {
          cloud.add((
            feature: label,
            note: "When the on-device model isn't ready.$ask",
          ));
        }
    }
  }
  final liveOn = switch (liveBackend) {
    LiveBackend.aiLogic => cloudRoutes.allows(CloudRoute.live),
    LiveBackend.ephemeral => true,
    LiveBackend.none => false,
  };
  if (liveOn) {
    cloud.add((
      feature: 'Live coach',
      note: 'Camera and microphone stream only while it is on.',
    ));
  } else {
    off.add('Live coach');
  }
  if (cloudRoutes.allows(CloudRoute.research)) {
    cloud.add((
      feature: 'Grounded research',
      note: 'Google Search, for factual questions.',
    ));
  } else {
    off.add('Grounded research');
  }
  cloud.add((
    feature: 'Nearby stores',
    note: 'Google Maps, only when you ask. Sends approximate location.',
  ));
  return (onDevice: onDevice, cloud: cloud, off: off);
}

/// On-device and cloud side by side, generated from the routing table.
class HybridRoutingColumns extends StatelessWidget {
  const HybridRoutingColumns({
    super.key,
    required this.cloudRoutes,
    required this.liveBackend,
  });

  final CloudRoutes cloudRoutes;
  final LiveBackend liveBackend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final columns = hybridRoutingColumns(
      cloudRoutes: cloudRoutes,
      liveBackend: liveBackend,
    );
    final local = _RoutingColumn(
      key: const ValueKey('routing-column-device'),
      icon: Icons.memory,
      title: 'On this device',
      subtitle: 'Nothing leaves while it runs here',
      background: const Color(0xffe4ebdf),
      accent: const Color(0xff285b43),
      foreground: const Color(0xff1c4231),
      entries: columns.onDevice,
    );
    final remote = _RoutingColumn(
      key: const ValueKey('routing-column-cloud'),
      icon: Icons.cloud,
      title: 'Google cloud',
      subtitle: 'Each cloud answer is labelled',
      background: const Color(0xffe3ecf5),
      accent: const Color(0xff3c6a92),
      foreground: const Color(0xff1f3d57),
      entries: columns.cloud,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 330
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: local),
                      const SizedBox(width: 10),
                      Expanded(child: remote),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [local, const SizedBox(height: 10), remote],
                ),
        ),
        if (columns.off.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            key: const ValueKey('routing-off'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.block,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Off in this build: ${columns.off.join(', ')}.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _RoutingColumn extends StatelessWidget {
  const _RoutingColumn({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.background,
    required this.accent,
    required this.foreground,
    required this.entries,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color background;
  final Color accent;
  final Color foreground;
  final List<RoutingEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(icon, size: 16, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
            const SizedBox(height: 8),
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.feature,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      entry.note,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
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
        if (!cloudOk) return 'On this device only.';
        return route.cloudOnlyWithImage
            ? 'On this device. A photo this device cannot read goes to '
                  '$_cloud only after you allow that exact photo; typed text '
                  'never does.'
            : 'On this device. If this device cannot run it, $_cloud.$ask';
      case HybridMode.preferOnDevice:
        return cloudOk
            ? 'On this device when the on-device model is ready; otherwise '
                  '$_cloud.$ask$retry'
            : 'On this device only (cloud help is off in this build).';
    }
  }

  return [
    for (final (feature, label, _) in _routedFeatures)
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
        const SizedBox(height: 14),
        HybridRoutingColumns(
          cloudRoutes: cloudRoutes,
          liveBackend: liveBackend,
        ),
        const SizedBox(height: 18),
        Semantics(
          header: true,
          child: Text(
            'Feature by feature',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 8),
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
