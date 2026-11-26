// First-run states (DESIGN.md §6, card SS-071).
//
// Combines what the hybrid plugin reports with things it cannot know: camera
// permission, connectivity, App Check (attestation) failure and provider
// quota. Every state carries one cook-facing message and one next action.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

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
  const ReadinessItem(this.state, this.level, this.message, this.action);
  final ReadinessState state;
  final ReadinessLevel level;
  final String message;
  final ReadinessAction action;
}

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
      ReadinessAction a,
    ) => items.add(ReadinessItem(s, l, message, a));

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
    if (bridgeMissing) {
      add(
        ReadinessState.bridgeUnavailable,
        noLocalLevel,
        "On-device AI isn't available here.$cloudNote",
        noLocalAction,
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
              "This device can't run on-device AI.",
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
          add(
            state,
            noLocalLevel,
            '$message$cloudNote',
            ReadinessAction.showEnableSteps,
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
            child: _ReadinessCard(
              item: readiness.items[i],
              primary: i == 0,
              onAction: onAction,
            ),
          ),
      ],
    ),
  );
}

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
    final (color, icon) = switch (item.level) {
      ReadinessLevel.blocking => (const Color(0xfffbe8c9), Icons.error_outline),
      ReadinessLevel.limited => (const Color(0xfffff0d6), Icons.info_outline),
      ReadinessLevel.info => (
        const Color(0xffe4ebdf),
        Icons.check_circle_outline,
      ),
    };
    final button = primary
        ? FilledButton(
            key: ValueKey('readiness-action-${item.state.name}'),
            onPressed: () => onAction(item.action),
            child: Text(item.action.label),
          )
        : TextButton(
            key: ValueKey('readiness-action-${item.state.name}'),
            onPressed: () => onAction(item.action),
            child: Text(item.action.label),
          );
    return Card(
      key: ValueKey('readiness-${item.state.name}'),
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon),
                const SizedBox(width: 10),
                Expanded(child: Text(item.message)),
              ],
            ),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: button),
          ],
        ),
      ),
    );
  }
}
