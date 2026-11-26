// First-run states (DESIGN.md §6, card SS-071).
//
// Combines what the hybrid plugin reports with things it cannot know: camera
// permission, connectivity, App Check (attestation) failure and provider
// quota. Every state carries one cook-facing message and one next action.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

import 'trust_motion.dart';

enum CameraAccess { granted, notAsked, denied, noCamera }

enum ReadinessState {
  attestationFailed,
  quotaReached,
  offline,
  noAiAvailable,
  cameraDenied,
  noCamera,
  bridgeUnavailable,
  deviceNotSupported,
  appleIntelligenceOff,
  notEnrolled,
  onDeviceUnavailable,
  modelDownloadable,
  modelDownloading,
  photosNeedSetup,
  photosNeedSetting,
  photosNeedCloud,
  ready,
}

/// What the cook can do next. The app maps each to a handler.
enum ReadinessAction {
  reload('Reload'),
  keepCooking('Keep cooking'),
  tryAgainLater('Try again later'),
  checkConnection('Try again'),
  allowCamera('Allow camera'),
  typeInstead('Type instead'),
  useCloudHelp('Continue with cloud help'),
  openOnDeviceSetup('Set up on-device AI'),
  showDownloadProgress('Show progress'),
  showEnableSteps('Show me how'),
  cookWithoutAi('Cook from a recipe'),
  dismiss('Got it'),
  startCooking('Start cooking');

  const ReadinessAction(this.label);
  final String label;
}

/// blocking: no AI help can run. limited: some help is missing. info: worth
/// knowing, nothing to fix.
enum ReadinessLevel { blocking, limited, info }

class ReadinessItem {
  const ReadinessItem(
    this.state,
    this.level,
    this.message,
    this.action, {
    this.title = '',
    this.cloudPath = false,
  });
  final ReadinessState state;
  final ReadinessLevel level;

  /// A few words the card leads with, e.g. "You're offline".
  final String title;
  final String message;
  final ReadinessAction action;

  /// True when this item describes help coming from Google cloud on
  /// purpose (no on-device model, cloud approved and reachable). The panel
  /// styles it as a chosen path, not a warning.
  final bool cloudPath;
}

/// The short lead for each state's card. Specific, never alarming.
String readinessTitle(ReadinessState state) => switch (state) {
  ReadinessState.attestationFailed => 'Cloud help is paused',
  ReadinessState.quotaReached => "Today's cloud allowance is used up",
  ReadinessState.offline => "You're offline",
  ReadinessState.noAiAvailable => 'Cook from a recipe for now',
  ReadinessState.cameraDenied => 'Camera access is off',
  ReadinessState.noCamera => 'No camera found',
  ReadinessState.bridgeUnavailable => "On-device AI isn't available here",
  ReadinessState.deviceNotSupported => "This device can't run on-device AI",
  ReadinessState.appleIntelligenceOff => 'Turn on Apple Intelligence',
  ReadinessState.notEnrolled => 'One more step for on-device AI',
  ReadinessState.onDeviceUnavailable => "On-device AI isn't ready yet",
  ReadinessState.modelDownloadable => 'Set up on-device AI',
  ReadinessState.modelDownloading => 'On-device AI is downloading',
  ReadinessState.photosNeedSetup => 'Photo checks need setting up',
  ReadinessState.photosNeedSetting => 'Photo checks need one setting',
  ReadinessState.photosNeedCloud => "Photos can't be read here",
  ReadinessState.ready => 'Ready when you are',
};

/// A specific icon for each state, so cards differ by more than colour.
IconData readinessIcon(ReadinessState state) => switch (state) {
  ReadinessState.attestationFailed => Icons.gpp_maybe_outlined,
  ReadinessState.quotaReached => Icons.hourglass_empty,
  ReadinessState.offline => Icons.wifi_off,
  ReadinessState.noAiAvailable => Icons.menu_book_outlined,
  ReadinessState.cameraDenied => Icons.no_photography_outlined,
  ReadinessState.noCamera => Icons.no_photography_outlined,
  ReadinessState.bridgeUnavailable ||
  ReadinessState.deviceNotSupported ||
  ReadinessState.onDeviceUnavailable => Icons.memory_outlined,
  ReadinessState.appleIntelligenceOff ||
  ReadinessState.notEnrolled => Icons.settings_suggest_outlined,
  ReadinessState.modelDownloadable => Icons.download_outlined,
  ReadinessState.modelDownloading => Icons.downloading,
  ReadinessState.photosNeedSetup ||
  ReadinessState.photosNeedSetting ||
  ReadinessState.photosNeedCloud => Icons.photo_camera_outlined,
  ReadinessState.ready => Icons.check_circle_outline,
};

class ReadinessInput {
  const ReadinessInput({
    required this.capabilities,
    required this.text,
    required this.image,
    required this.camera,
    required this.online,
    required this.cloudApproved,
    this.attestationFailed = false,
    this.quotaReached = false,
  });

  final HybridCapabilities capabilities;
  final HybridAvailability text;
  final HybridAvailability image;
  final CameraAccess camera;
  final bool online;

  /// `CloudRoutes.allows(CloudRoute.hybridFallback)`.
  final bool cloudApproved;

  /// The latest cloud call failed with `HybridErrorCode.attestation`.
  final bool attestationFailed;

  /// The latest cloud call failed with `HybridErrorCode.quota`.
  final bool quotaReached;

  /// Sets [attestationFailed] / [quotaReached] from the LATEST cloud call's
  /// outcome. Pass null after a successful call: earlier errors are cleared,
  /// never carried forward.
  ReadinessInput withCloudError(HybridErrorCode? code) => ReadinessInput(
    capabilities: capabilities,
    text: text,
    image: image,
    camera: camera,
    online: online,
    cloudApproved: cloudApproved,
    attestationFailed: code == HybridErrorCode.attestation,
    quotaReached: code == HybridErrorCode.quota,
  );
}

class AppReadiness {
  AppReadiness._(
    this.items, {
    required this.localReady,
    required this.cloudUsable,
  });

  factory AppReadiness.evaluate(ReadinessInput input) {
    final local = input.capabilities.local;
    final localReady =
        local != null && input.text.status == OnDeviceStatus.available;
    final cloudUsable =
        input.cloudApproved &&
        input.online &&
        !input.attestationFailed &&
        !input.quotaReached;
    final stillWorks = localReady ? ' On-device help still works.' : '';
    final items = <ReadinessItem>[];
    void add(
      ReadinessState s,
      ReadinessLevel l,
      String message,
      ReadinessAction a, {
      String? title,
      bool cloudPath = false,
    }) => items.add(
      ReadinessItem(
        s,
        l,
        message,
        a,
        title: title ?? readinessTitle(s),
        cloudPath: cloudPath,
      ),
    );

    // Cloud-side problems only matter when cloud help is part of this build.
    if (input.cloudApproved && input.attestationFailed) {
      add(
        ReadinessState.attestationFailed,
        localReady ? ReadinessLevel.limited : ReadinessLevel.blocking,
        "We couldn't verify this copy of SousSight, so cloud help is paused."
        '$stillWorks',
        ReadinessAction.reload,
      );
    }
    if (input.cloudApproved && input.quotaReached) {
      add(
        ReadinessState.quotaReached,
        localReady ? ReadinessLevel.limited : ReadinessLevel.blocking,
        "Today's cloud allowance is used up.$stillWorks",
        localReady
            ? ReadinessAction.keepCooking
            : ReadinessAction.tryAgainLater,
      );
    }
    if (!input.online) {
      add(
        ReadinessState.offline,
        localReady ? ReadinessLevel.limited : ReadinessLevel.blocking,
        localReady
            ? "You're offline. On-device help keeps working; cloud help comes "
                  'back when you reconnect.'
            : "You're offline, and this device has no on-device model ready. "
                  'Reconnect to get help.',
        localReady
            ? ReadinessAction.keepCooking
            : ReadinessAction.checkConnection,
      );
    }

    // On-device model.
    final reason = input.text.reason;
    final bridgeMissing =
        input.capabilities.platform == 'none' ||
        local == null ||
        reason == 'bridge_unavailable';
    final cloudNote = cloudUsable
        ? ' SousSight will use cloud help and show you when it does.'
        : '';
    final noLocalLevel = cloudUsable
        ? ReadinessLevel.limited
        : ReadinessLevel.blocking;
    final noLocalAction = cloudUsable
        ? ReadinessAction.useCloudHelp
        : ReadinessAction.showEnableSteps;
    // With cloud help approved and reachable, no on-device model is a path
    // the app takes on purpose, said plainly.
    const cloudPathMessage =
        "Your device doesn't have on-device AI yet — answers will come from "
        "Google cloud, and we'll show you each time.";
    const cloudPathTitle = 'Answers will come from Google cloud';
    if (bridgeMissing) {
      add(
        ReadinessState.bridgeUnavailable,
        noLocalLevel,
        cloudUsable ? cloudPathMessage : "On-device AI isn't available here.",
        noLocalAction,
        title: cloudUsable ? cloudPathTitle : null,
        cloudPath: cloudUsable,
      );
    } else {
      switch (input.text.status) {
        case OnDeviceStatus.available:
          break;
        case OnDeviceStatus.downloadable:
          add(
            ReadinessState.modelDownloadable,
            noLocalLevel,
            'On-device AI is ready to set up. It downloads once, then your '
            'photos and notes can stay on this device.',
            ReadinessAction.openOnDeviceSetup,
          );
        case OnDeviceStatus.downloading:
          add(
            ReadinessState.modelDownloading,
            cloudUsable ? ReadinessLevel.info : ReadinessLevel.blocking,
            'On-device AI is downloading.$cloudNote',
            ReadinessAction.showDownloadProgress,
          );
        case OnDeviceStatus.unavailable:
          final (state, message) = switch (reason) {
            'device_not_eligible' || 'unsupported_browser' => (
              ReadinessState.deviceNotSupported,
              cloudUsable
                  ? cloudPathMessage
                  : "This device can't run on-device AI.",
            ),
            'apple_intelligence_off' => (
              ReadinessState.appleIntelligenceOff,
              'Turn on Apple Intelligence to keep help on this iPhone.',
            ),
            'not_enrolled' => (
              ReadinessState.notEnrolled,
              'This phone needs the AICore developer preview for on-device '
                  'help.',
            ),
            _ => (
              ReadinessState.onDeviceUnavailable,
              "On-device AI isn't ready on this device.",
            ),
          };
          // An unsupported device cannot be fixed by the cook: with cloud
          // help available, carrying on is the next action.
          final unsupportedWithCloud =
              state == ReadinessState.deviceNotSupported && cloudUsable;
          add(
            state,
            noLocalLevel,
            unsupportedWithCloud ? message : '$message$cloudNote',
            unsupportedWithCloud
                ? ReadinessAction.useCloudHelp
                : ReadinessAction.showEnableSteps,
            title: unsupportedWithCloud ? cloudPathTitle : null,
            cloudPath: unsupportedWithCloud,
          );
      }
    }

    // Photos, once text runs locally.
    if (localReady && input.camera != CameraAccess.noCamera) {
      if (!local.supportsImage) {
        add(
          ReadinessState.photosNeedCloud,
          ReadinessLevel.info,
          cloudUsable
              ? "${local.modelFamily} reads text only, so photo features use "
                    'the cloud.'
              : "${local.modelFamily} reads text only, so photo features "
                    "can't run here. Typing works.",
          cloudUsable ? ReadinessAction.dismiss : ReadinessAction.typeInstead,
          title: cloudUsable ? 'Photos use Google cloud' : null,
          cloudPath: cloudUsable,
        );
      } else {
        switch (input.image.status) {
          case OnDeviceStatus.available:
            break;
          case OnDeviceStatus.downloadable || OnDeviceStatus.downloading:
            add(
              ReadinessState.photosNeedSetup,
              ReadinessLevel.limited,
              'Text help is ready. Photo checks still need setting up.',
              ReadinessAction.openOnDeviceSetup,
            );
          case OnDeviceStatus.unavailable:
            add(
              ReadinessState.photosNeedSetting,
              ReadinessLevel.limited,
              input.capabilities.platform == 'web'
                  ? 'Text help runs on this device. Photo checks need a '
                        'Chrome setting.'
                  : "Text help runs on this device, but photo checks can't "
                        'run here yet.',
              ReadinessAction.showEnableSteps,
            );
        }
      }
    }

    // Camera.
    switch (input.camera) {
      case CameraAccess.denied:
        add(
          ReadinessState.cameraDenied,
          ReadinessLevel.limited,
          'Camera access is off. You can type what you have, or allow the '
          'camera in your browser or phone settings.',
          ReadinessAction.allowCamera,
        );
      case CameraAccess.noCamera:
        add(
          ReadinessState.noCamera,
          ReadinessLevel.limited,
          'No camera found. You can type what you have instead.',
          ReadinessAction.typeInstead,
        );
      case CameraAccess.granted || CameraAccess.notAsked:
        break;
    }

    if (!localReady && !cloudUsable) {
      add(
        ReadinessState.noAiAvailable,
        ReadinessLevel.blocking,
        "AI help can't run right now. You can still cook from a recipe "
        'with real timers.',
        ReadinessAction.cookWithoutAi,
      );
    }

    if (items.every((i) => i.level == ReadinessLevel.info)) {
      add(
        ReadinessState.ready,
        ReadinessLevel.info,
        localReady
            ? 'On-device AI is ready. SousSight shows you whenever something '
                  'goes to the cloud.'
            : 'Cloud help is ready. SousSight shows you whenever something '
                  'goes to the cloud.',
        ReadinessAction.startCooking,
        title: localReady ? 'On-device AI is ready' : 'Cloud help is ready',
        cloudPath: !localReady,
      );
    }

    // Stable sort: most serious first, insertion order within a level.
    final ordered = [
      for (final level in ReadinessLevel.values)
        ...items.where((i) => i.level == level),
    ];
    return AppReadiness._(
      List.unmodifiable(ordered),
      localReady: localReady,
      cloudUsable: cloudUsable,
    );
  }

  /// Most serious first. Never empty.
  final List<ReadinessItem> items;
  final bool localReady;
  final bool cloudUsable;

  ReadinessItem get primary => items.first;
  bool get canUseAi => localReady || cloudUsable;
  Set<ReadinessState> get states => {for (final i in items) i.state};
}

/// Shows the readiness items, most serious first, each with its next action.
class ReadinessPanel extends StatelessWidget {
  const ReadinessPanel({
    super.key,
    required this.readiness,
    required this.onAction,
  });

  final AppReadiness readiness;
  final void Function(ReadinessAction action) onAction;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    child: Column(
      key: const ValueKey('readiness-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < readiness.items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ArrivalTransition(
              signature: readiness.items[i].state,
              child: _ReadinessCard(
                item: readiness.items[i],
                primary: i == 0,
                onAction: onAction,
              ),
            ),
          ),
      ],
    ),
  );
}

/// Colours for one card: warm for something to fix, blue for the chosen
/// cloud path, green for ready.
({Color background, Color accent, Color foreground}) _readinessColors(
  ReadinessItem item,
) {
  if (item.cloudPath) {
    return (
      background: const Color(0xffe3ecf5),
      accent: const Color(0xff3c6a92),
      foreground: const Color(0xff1f3d57),
    );
  }
  return switch (item.level) {
    ReadinessLevel.blocking => (
      background: const Color(0xfffbe8c9),
      accent: const Color(0xffbf5b32),
      foreground: const Color(0xff6b2a10),
    ),
    ReadinessLevel.limited => (
      background: const Color(0xfffff0d6),
      accent: const Color(0xffb7791f),
      foreground: const Color(0xff5c3300),
    ),
    ReadinessLevel.info => (
      background: const Color(0xffe4ebdf),
      accent: const Color(0xff285b43),
      foreground: const Color(0xff1c4231),
    ),
  };
}

IconData _actionIcon(ReadinessAction action) => switch (action) {
  ReadinessAction.reload || ReadinessAction.checkConnection => Icons.refresh,
  ReadinessAction.allowCamera => Icons.photo_camera_outlined,
  ReadinessAction.typeInstead => Icons.keyboard_outlined,
  ReadinessAction.useCloudHelp => Icons.cloud_outlined,
  ReadinessAction.openOnDeviceSetup => Icons.download_outlined,
  ReadinessAction.showDownloadProgress => Icons.downloading,
  ReadinessAction.showEnableSteps => Icons.list_alt_outlined,
  ReadinessAction.cookWithoutAi => Icons.menu_book_outlined,
  ReadinessAction.startCooking => Icons.arrow_forward,
  ReadinessAction.keepCooking ||
  ReadinessAction.tryAgainLater ||
  ReadinessAction.dismiss => Icons.check,
};

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({
    required this.item,
    required this.primary,
    required this.onAction,
  });

  final ReadinessItem item;
  final bool primary;
  final void Function(ReadinessAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _readinessColors(item);
    final icon = item.cloudPath
        ? Icons.cloud_outlined
        : readinessIcon(item.state);
    final label = Text(item.action.label);
    final button = primary
        ? FilledButton(
            key: ValueKey('readiness-action-${item.state.name}'),
            style: FilledButton.styleFrom(backgroundColor: colors.accent),
            onPressed: () => onAction(item.action),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_actionIcon(item.action), size: 18),
                const SizedBox(width: 8),
                label,
              ],
            ),
          )
        : TextButton(
            key: ValueKey('readiness-action-${item.state.name}'),
            style: TextButton.styleFrom(foregroundColor: colors.foreground),
            onPressed: () => onAction(item.action),
            child: label,
          );
    return DecoratedBox(
      key: ValueKey('readiness-${item.state.name}'),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.accent,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(icon, size: 20, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.title.isNotEmpty) ...[
                        Semantics(
                          header: true,
                          child: Text(
                            item.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: colors.foreground,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                      Text(
                        item.message,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.foreground,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerRight, child: button),
          ],
        ),
      ),
    );
  }
}

/// One calm line for the first screen (SS-089): what the cook can do now,
/// never a stack of warnings. The full detail lives in the "On this device"
/// sheet behind "Details". Null when there is nothing worth saying.
///
/// [pantryLocalOnly] is the cook's effective "keep Pantry scan on this
/// device" setting: with it on, the line never says the list is sent online.
String? readinessCalmLine(
  AppReadiness readiness, {
  bool pantryLocalOnly = false,
}) {
  final states = readiness.states;
  if (states.contains(ReadinessState.ready)) return null;
  // One honest line for a paused cloud, not three stacked cards (Maya).
  if (states.contains(ReadinessState.attestationFailed)) {
    return readiness.localReady
        ? "Online help is paused: this copy of SousSight couldn't be verified. "
              'Help on this device still works.'
        : "Online help is paused: this copy of SousSight couldn't be verified. "
              'Reloading the page may fix it; meanwhile pick a recipe below.';
  }
  if (states.contains(ReadinessState.quotaReached) && !readiness.localReady) {
    return "Today's online help is used up. Pick a recipe below — steps and "
        'timers still work.';
  }
  if (!readiness.canUseAi) {
    return states.contains(ReadinessState.offline)
        ? "You're offline. Pick a recipe below — steps and timers still work."
        : "Pick a recipe below to start cooking. Matching your food may not "
              'work on this device right now.';
  }
  if (readiness.items.any((i) => i.cloudPath) && !readiness.localReady) {
    return pantryLocalOnly
        ? "You chose to keep pantry scans on this device, and it can't run "
              'them here. Pick a recipe below to start cooking.'
        // No definite transfer claim here: whether a request goes online is
        // decided per request (policy, settings) and each answer says where
        // it ran (Codex #221).
        : 'Type what you have, or pick a recipe below. This device may not '
              "answer on its own; if a request goes online to Google's AI, "
              'its answer says so.';
  }
  return 'Type what you have, or pick a recipe below.';
}

/// The compact form of [ReadinessPanel]: [readinessCalmLine] and a
/// "Details" button. Renders nothing when the line is null.
class ReadinessLine extends StatelessWidget {
  const ReadinessLine({
    super.key,
    required this.readiness,
    required this.onDetails,
    this.pantryLocalOnly = false,
  });

  final AppReadiness readiness;
  final VoidCallback onDetails;

  /// See [readinessCalmLine].
  final bool pantryLocalOnly;

  @override
  Widget build(BuildContext context) {
    final line = readinessCalmLine(readiness, pantryLocalOnly: pantryLocalOnly);
    if (line == null) return const SizedBox.shrink();
    const ink = Color(0xff5c4a2e);
    return Row(
      key: const ValueKey('readiness-line'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const ExcludeSemantics(
          child: Icon(Icons.info_outline, size: 18, color: ink),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            line,
            style: const TextStyle(fontSize: 14, height: 1.35, color: ink),
          ),
        ),
        TextButton(
          key: const ValueKey('readiness-details'),
          onPressed: onDetails,
          child: const Text('Details'),
        ),
      ],
    );
  }
}
