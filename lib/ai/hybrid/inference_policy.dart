// Routing and privacy rules (PLAN.md §4, DESIGN.md §5). Pure Dart, no I/O:
// everything a decision depends on is in [RouteInput].

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import 'hybrid_types.dart';
import 'payload_digest.dart';

/// Optional per-feature overrides from Remote Config (SS-076). Defaults ship
/// in the app; a missing value means "use the feature default".
///
/// Overrides are applied last, after `localOnly`, cloud approval, hard limits
/// and availability, so they can never loosen any of those. A feature whose
/// default is `onlyOnDevice` (local watch, Coach Lite, label check) ignores
/// them entirely: it cannot be widened remotely. They also cannot
/// push a feature to the cloud: only on-device-first modes
/// ([HybridMode.onlyOnDevice], [HybridMode.preferOnDevice]) are honoured, and
/// a cloud-primary value is ignored. Remote Config can tighten or relax the
/// SDK's own fallback for an on-device-first feature, and nothing more.
class RemoteRouting {
  const RemoteRouting({this.modes = const {}});

  /// Feature key → mode.
  final Map<String, HybridMode> modes;

  HybridMode? modeFor(String feature) {
    final mode = modes[feature];
    return mode == HybridMode.onlyOnDevice || mode == HybridMode.preferOnDevice
        ? mode
        : null;
  }
}

/// When an upload of this feature's payload needs a per-payload
/// [ConsentGrant].
enum UploadConsent {
  /// When it carries an image, audio or location.
  media,

  /// Always, whatever it carries.
  always,

  /// Never: the feature is labelled as cloud before the cook acts, so the
  /// action itself is the consent.
  none,
}

/// A feature's built-in route (PLAN.md §4).
class FeatureRoute {
  const FeatureRoute(
    this.defaultMode, {
    required this.cloudWhenLocalCannot,
    required this.semanticRetry,
    this.consent = UploadConsent.media,
    this.cloudReason = RouteReason.noLocalModel,
    this.cloudOnlyWithImage = false,
    this.parentFeature,
  });

  /// The mode used when nothing above it in the precedence applies.
  final HybridMode defaultMode;

  /// When a hard limit (audio, image, size, language, mode support) rules the
  /// local model out and uploads are permitted, run `onlyInCloud` instead of
  /// stopping.
  final bool cloudWhenLocalCannot;

  /// One `onlyInCloud` retry when the caller's validator rejects an on-device
  /// answer.
  final bool semanticRetry;
  final UploadConsent consent;

  /// [cloudWhenLocalCannot] applies only to a request that carries an image
  /// (the consented photo). Anything else a hard limit rules out locally is
  /// blocked, so a typed alternative never goes to the cloud quietly.
  final bool cloudOnlyWithImage;

  /// A sub-step of another feature (a watch's cloud check). The parent's
  /// local-only setting applies to it too.
  final String? parentFeature;

  /// The reason given when a cloud-first default is what sends it to the
  /// cloud (no hard limit or availability reason applies).
  final RouteReason cloudReason;

  bool get cloudOnly => defaultMode == HybridMode.onlyInCloud;
}

/// Feature defaults. Unknown features fail closed to on-device only.
const featureRoutes = <String, FeatureRoute>{
  // Typed list or photo. Photo goes to the cloud on iOS (no local image
  // support), with consent.
  'pantry_scan': FeatureRoute(
    HybridMode.preferOnDevice,
    cloudWhenLocalCannot: true,
    semanticRetry: true,
  ),
  // Audio is never supported on-device.
  'pantry_voice': FeatureRoute(
    HybridMode.onlyInCloud,
    cloudWhenLocalCannot: true,
    semanticRetry: false,
    consent: UploadConsent.none,
    cloudReason: RouteReason.audioNeedsCloud,
  ),
  // On-device first; one cloud retry on semantic rejection, but not when the
  // SDK already answered from the cloud.
  'recipe_draft': FeatureRoute(
    HybridMode.preferOnDevice,
    cloudWhenLocalCannot: true,
    semanticRetry: true,
  ),
  // The privacy hero. Sending an "unsure" frame to the cloud is a separate,
  // explicitly consented feature action, not a fallback.
  'local_watch': FeatureRoute(
    HybridMode.onlyOnDevice,
    cloudWhenLocalCannot: false,
    semanticRetry: false,
  ),
  // That separate action: one "unsure" frame checked in the cloud, only with
  // a grant for that frame's digest.
  'local_watch_cloud_check': FeatureRoute(
    HybridMode.onlyInCloud,
    cloudWhenLocalCannot: true,
    semanticRetry: false,
    consent: UploadConsent.always,
    cloudReason: RouteReason.cloudRetryAfterCheck,
    parentFeature: 'local_watch',
  ),
  // On-device; cloud only if the panel fails validation and the cook is
  // online.
  'coach_lite': FeatureRoute(
    HybridMode.onlyOnDevice,
    cloudWhenLocalCannot: false,
    semanticRetry: true,
  ),
  // On-device only by default; iOS (no local image) photo → cloud with
  // consent, or the typed-label path.
  'label_check': FeatureRoute(
    HybridMode.onlyOnDevice,
    cloudWhenLocalCannot: true,
    semanticRetry: false,
    // Always: a typed label that hits a local hard limit (e.g. language)
    // must not reach the cloud without the cook's OK.
    consent: UploadConsent.always,
    cloudOnlyWithImage: true,
  ),
  // Recipe text into the cook's language (SS-106). On-device first; the
  // cloud only through the hybridFallback route, when nothing restricts it:
  // a language or size the local model cannot handle, a model that is not
  // ready, or one retry when the on-device answer is malformed. Text only,
  // so the default media consent asks for no prompt; every leg is ledgered.
  'recipe_translate': FeatureRoute(
    HybridMode.preferOnDevice,
    cloudWhenLocalCannot: true,
    semanticRetry: true,
  ),
};

const _unknownFeature = FeatureRoute(
  HybridMode.onlyOnDevice,
  cloudWhenLocalCannot: false,
  semanticRetry: false,
);

FeatureRoute featureRouteFor(String feature) =>
    featureRoutes[feature] ?? _unknownFeature;

/// The cook's local-only setting as it applies to [feature]: its own, or its
/// parent feature's for a sub-step. Read live; never cache the result.
bool localOnlyFor(PrivacySettings privacy, String feature) {
  if (privacy.localOnly(feature)) return true;
  final parent = featureRouteFor(feature).parentFeature;
  return parent != null && privacy.localOnly(parent);
}

class RouteInput {
  const RouteInput({
    required this.feature,
    this.hasImage = false,
    this.hasAudio = false,
    this.hasLocation = false,
    required this.estimatedTokens,
    required this.languageTag,
    required this.localOnly,
    required this.online,
    required this.cloudApproved,
    required this.capabilities,
    required this.status,
    this.remote,
  });

  final String feature;
  final bool hasImage, hasAudio, hasLocation;

  /// §4 token budget; see [estimateLocalTokens].
  final int estimatedTokens;

  /// BCP 47, e.g. `en` or `en-US`.
  final String languageTag;
  final bool localOnly;
  final bool online;

  /// `CloudRoutes.allows(CloudRoute.hybridFallback)`.
  final bool cloudApproved;
  final HybridCapabilities capabilities;

  /// For this request's modality.
  final OnDeviceStatus status;
  final RemoteRouting? remote;

  Set<DataKind> get kinds => {
    DataKind.text,
    if (hasImage) DataKind.image,
    if (hasAudio) DataKind.audio,
    if (hasLocation) DataKind.location,
  };
}

class RouteDecision {
  const RouteDecision({
    required this.mode,
    required this.reason,
    required this.mayUpload,
    required this.needsConsent,
  });

  const RouteDecision.blocked(this.reason)
    : mode = null,
      mayUpload = false,
      needsConsent = false;

  /// Null: cannot run. Show [reason] and the next step.
  final HybridMode? mode;
  final RouteReason reason;

  /// True for every mode except `onlyOnDevice`.
  final bool mayUpload;
  final bool needsConsent;

  bool get blocked => mode == null;

  @override
  String toString() =>
      'RouteDecision(${mode?.name ?? 'blocked'}, ${reason.name}, '
      'mayUpload: $mayUpload, needsConsent: $needsConsent)';
}

/// Precedence, highest first (DESIGN.md §5): `localOnly` → `cloudApproved`
/// (and being online) → hard limits → availability → remote overrides →
/// feature default.
///
/// `localOnly`, `!cloudApproved` and offline can only yield `onlyOnDevice` or
/// a block: `preferOnDevice` may fall back to the cloud inside the SDK.
RouteDecision decideRoute(RouteInput input) {
  final route = featureRouteFor(input.feature);
  final hardLimit = _localHardLimit(input);
  final notReady = _availabilityBlock(input.status);

  final restriction = input.localOnly
      ? RouteReason.localOnlySetting
      : !input.cloudApproved
      ? RouteReason.cloudNotApproved
      : !input.online
      ? RouteReason.offline
      : null;

  if (restriction != null) {
    // A hard limit means the request needs the cloud, and the restriction is
    // what the cook can change. A not-ready model is the better explanation
    // when the request would otherwise run locally.
    // A cloud-only feature (the cook asked for a cloud check) is not quietly
    // run on-device instead.
    if (hardLimit != null || route.cloudOnly) {
      return RouteDecision.blocked(restriction);
    }
    if (notReady != null) return RouteDecision.blocked(notReady);
    return _local(HybridMode.onlyOnDevice, RouteReason.onDevice);
  }

  if (hardLimit != null) {
    final cloudAllowed =
        route.cloudWhenLocalCannot &&
        (!route.cloudOnlyWithImage || input.hasImage);
    return cloudAllowed
        ? _cloud(
            input,
            HybridMode.onlyInCloud,
            route.cloudOnly ? route.cloudReason : hardLimit,
          )
        : RouteDecision.blocked(hardLimit);
  }

  // A feature that is on-device only by design is never widened remotely.
  final wanted = route.defaultMode == HybridMode.onlyOnDevice
      ? HybridMode.onlyOnDevice
      : input.remote?.modeFor(input.feature) ?? route.defaultMode;

  if (notReady != null) {
    // preferOnDevice is exactly the hybrid SDK's job here: it answers from
    // the cloud while the local model is missing or downloading.
    if (wanted == HybridMode.preferOnDevice &&
        input.capabilities.supportedModes.contains(HybridMode.preferOnDevice)) {
      return _cloud(input, HybridMode.preferOnDevice, notReady);
    }
    if (wanted == HybridMode.onlyInCloud ||
        wanted == HybridMode.preferInCloud) {
      // Availability of the local model does not matter to a cloud send.
      return _cloud(input, HybridMode.onlyInCloud, route.cloudReason);
    }
    return RouteDecision.blocked(notReady);
  }

  switch (wanted) {
    case HybridMode.onlyOnDevice:
      return _local(HybridMode.onlyOnDevice, RouteReason.onDevice);
    case HybridMode.preferOnDevice:
      // A backend without preferOnDevice still runs the request locally.
      return input.capabilities.supportedModes.contains(
            HybridMode.preferOnDevice,
          )
          ? _cloud(input, HybridMode.preferOnDevice, RouteReason.onDevice)
          : _local(HybridMode.onlyOnDevice, RouteReason.onDevice);
    case HybridMode.preferInCloud:
    case HybridMode.onlyInCloud:
      // Only reachable for a cloud-first feature with no hard limit.
      return _cloud(input, HybridMode.onlyInCloud, route.cloudReason);
  }
}

/// The decision for a semantic retry (§5 step 5) or a Dart cloud fallback
/// (§5 step 4): always `onlyInCloud`, and only when uploads are permitted.
RouteDecision decideCloudRetry({
  required String feature,
  required Set<DataKind> kinds,
  required bool localOnly,
  required bool cloudApproved,
  required bool online,
  RouteReason reason = RouteReason.cloudRetryAfterCheck,
}) {
  if (localOnly) {
    return const RouteDecision.blocked(RouteReason.localOnlySetting);
  }
  if (!cloudApproved) {
    return const RouteDecision.blocked(RouteReason.cloudNotApproved);
  }
  if (!online) return const RouteDecision.blocked(RouteReason.offline);
  return RouteDecision(
    mode: HybridMode.onlyInCloud,
    reason: reason,
    mayUpload: true,
    needsConsent: consentRequired(feature, kinds),
  );
}

/// Whether an upload of this payload needs a per-payload grant, per the
/// feature's [UploadConsent]. By default media (image, audio, location) needs
/// one; text may fall back without a prompt and is still recorded in the
/// ledger. The pantry voice clip is labelled as cloud before the cook records
/// (none); a watch frame's cloud check always needs one (always).
bool consentRequired(String feature, Set<DataKind> kinds) =>
    switch (featureRouteFor(feature).consent) {
      UploadConsent.none => false,
      UploadConsent.always => true,
      UploadConsent.media =>
        kinds.contains(DataKind.image) ||
            kinds.contains(DataKind.audio) ||
            kinds.contains(DataKind.location),
    };

/// §4 token budget for a local run: (system instruction + all text parts +
/// serialized schema) characters / 4, plus `imageTokenEstimate` per image,
/// plus `maxOutputTokens`.
int estimateLocalTokens(HybridTask task, {required int imageTokenEstimate}) {
  var chars = task.systemInstruction?.length ?? 0;
  var images = 0;
  for (final p in task.parts) {
    if (p is HybridText) chars += p.text.length;
    if (isImagePart(p)) images++;
  }
  if (task.jsonSchema != null) chars += jsonEncode(task.jsonSchema).length;
  return (chars / 4).ceil() +
      images * imageTokenEstimate +
      task.maxOutputTokens;
}

/// Used when the bridge reports no local limits.
const defaultImageTokenEstimate = 1000;

RouteReason? _localHardLimit(RouteInput input) {
  final local = input.capabilities.local;
  if (input.hasAudio) return RouteReason.audioNeedsCloud;
  if (local == null ||
      !input.capabilities.supportedModes.contains(HybridMode.onlyOnDevice)) {
    return RouteReason.noLocalModel;
  }
  if (input.hasImage && !local.supportsImage) {
    return RouteReason.imageNeedsCloud;
  }
  if (input.estimatedTokens > local.maxTotalTokens) {
    return RouteReason.tooLargeForDevice;
  }
  if (!_languageSupported(input.languageTag, local.validatedLanguages)) {
    return RouteReason.languageNotSupported;
  }
  return null;
}

bool _languageSupported(String tag, List<String> validated) {
  final t = tag.toLowerCase();
  final primary = t.split(RegExp('[-_]')).first;
  return validated.any((v) {
    final l = v.toLowerCase();
    return l == t || l == primary;
  });
}

RouteReason? _availabilityBlock(OnDeviceStatus status) => switch (status) {
  OnDeviceStatus.available => null,
  OnDeviceStatus.downloading => RouteReason.modelDownloading,
  OnDeviceStatus.downloadable => RouteReason.modelNotReady,
  OnDeviceStatus.unavailable => RouteReason.noLocalModel,
};

RouteDecision _local(HybridMode mode, RouteReason reason) => RouteDecision(
  mode: mode,
  reason: reason,
  mayUpload: false,
  needsConsent: false,
);

RouteDecision _cloud(RouteInput input, HybridMode mode, RouteReason reason) =>
    RouteDecision(
      mode: mode,
      reason: reason,
      mayUpload: true,
      needsConsent: consentRequired(input.feature, input.kinds),
    );
