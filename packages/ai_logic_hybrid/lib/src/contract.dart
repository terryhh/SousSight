// The bridge contract. See docs/buildhybridai/DESIGN.md §4; change that first.

import 'dart:typed_data';

/// Where a request may run. Values travel over channels as their Dart names.
enum HybridMode { preferOnDevice, onlyOnDevice, preferInCloud, onlyInCloud }

/// What the hybrid SDK reported. Never inferred by the bridge.
enum InferenceSource { onDevice, cloud }

enum OnDeviceStatus { available, downloadable, downloading, unavailable }

/// Android local model selection. Names are the wire values.
enum AndroidModelOption {
  /// Default. Once per app run, uses [preview] (Gemini Nano 4) only if it
  /// answers a tiny on-device probe, else [stable]. A preview that fails
  /// mid-session switches to [stable] and retries once, on-device only.
  auto,
  preview,
  previewFast,
  stable;

  /// Parses a wire or dart-define value. Null, blank or unknown → [auto].
  static AndroidModelOption fromName(String? name) {
    final trimmed = name?.trim();
    for (final option in values) {
      if (option.name == trimmed) return option;
    }
    return auto;
  }

  /// A concrete option a backend reported, or null (absent, unknown or
  /// [auto], which is never a concrete model).
  static AndroidModelOption? _reported(Object? name) {
    for (final option in values) {
      if (option != auto && option.name == name) return option;
    }
    return null;
  }
}

/// Set once, before first use. Status, download and generation all use it.
class HybridConfig {
  const HybridConfig({
    required this.cloudModel,
    this.androidModel = AndroidModelOption.auto,
    this.languages = const ['en'],
  });

  final String cloudModel;
  final AndroidModelOption androidModel;
  final List<String> languages;

  Map<String, Object?> toMap() => {
    'cloudModel': cloudModel,
    'androidModel': androidModel.name,
    'languages': languages,
  };
}

/// Limits of the LOCAL model only. Cloud requests are not bound by these.
class LocalModelLimits {
  const LocalModelLimits({
    required this.modelFamily,
    required this.supportsImage,
    required this.supportsJsonSchema,
    required this.maxTotalTokens,
    required this.defaultOutputReserve,
    required this.imageTokenEstimate,
    required this.validatedLanguages,
    this.modelOption,
  });

  final String modelFamily;

  /// Android: the concrete option in use (what [AndroidModelOption.auto]
  /// chose); null before it has chosen and on other platforms.
  final AndroidModelOption? modelOption;
  final bool supportsImage;
  final bool supportsJsonSchema;

  /// Prompt plus output.
  final int maxTotalTokens;
  final int defaultOutputReserve;

  /// Budget charged per image. Unproven until gate G2b measures it.
  final int imageTokenEstimate;
  final List<String> validatedLanguages;

  factory LocalModelLimits.fromMap(Map<Object?, Object?> m) => LocalModelLimits(
    modelFamily: m['modelFamily'] as String,
    supportsImage: m['supportsImage'] as bool,
    supportsJsonSchema: m['supportsJsonSchema'] as bool,
    maxTotalTokens: m['maxTotalTokens'] as int,
    defaultOutputReserve: m['defaultOutputReserve'] as int,
    imageTokenEstimate: m['imageTokenEstimate'] as int,
    validatedLanguages: [
      for (final l in (m['validatedLanguages'] as List)) l as String,
    ],
    modelOption: AndroidModelOption._reported(m['modelOption']),
  );

  Map<String, Object?> toMap() => {
    'modelFamily': modelFamily,
    'modelOption': modelOption?.name,
    'supportsImage': supportsImage,
    'supportsJsonSchema': supportsJsonSchema,
    'maxTotalTokens': maxTotalTokens,
    'defaultOutputReserve': defaultOutputReserve,
    'imageTokenEstimate': imageTokenEstimate,
    'validatedLanguages': validatedLanguages,
  };
}

class HybridCapabilities {
  const HybridCapabilities({
    required this.platform,
    required this.local,
    this.maxImages = 1,
    this.maxImageBytes = 1024 * 1024,
    this.maxImageDimension = 768,
    required this.supportedModes,
  });

  /// What a backend reports when its bridge could not initialize.
  const HybridCapabilities.none()
    : platform = 'none',
      local = null,
      maxImages = 1,
      maxImageBytes = 1024 * 1024,
      maxImageDimension = 768,
      supportedModes = const {};

  /// 'web' | 'android' | 'ios' | 'none'
  final String platform;

  /// Null when there is no local model or no bridge.
  final LocalModelLimits? local;

  /// Attachment limits for every route.
  final int maxImages;
  final int maxImageBytes;
  final int maxImageDimension;

  /// Empty when the bridge could not initialize. Unmapped modes fail closed.
  final Set<HybridMode> supportedModes;

  factory HybridCapabilities.fromMap(Map<Object?, Object?> m) =>
      HybridCapabilities(
        platform: m['platform'] as String,
        local: m['local'] == null
            ? null
            : LocalModelLimits.fromMap(m['local'] as Map<Object?, Object?>),
        maxImages: m['maxImages'] as int,
        maxImageBytes: m['maxImageBytes'] as int,
        maxImageDimension: m['maxImageDimension'] as int,
        supportedModes: {
          for (final name in (m['supportedModes'] as List))
            HybridMode.values.byName(name as String),
        },
      );

  Map<String, Object?> toMap() => {
    'platform': platform,
    'local': local?.toMap(),
    'maxImages': maxImages,
    'maxImageBytes': maxImageBytes,
    'maxImageDimension': maxImageDimension,
    'supportedModes': [for (final m in supportedModes) m.name],
  };
}

class HybridAvailability {
  const HybridAvailability({
    required this.status,
    this.reason,
    this.modelLabel,
    this.modelOption,
  });

  final OnDeviceStatus status;

  /// Stable code, e.g. unsupported_browser, bridge_unavailable,
  /// device_not_eligible, apple_intelligence_off, model_not_ready, not_enrolled.
  final String? reason;

  /// Exact base model name when the platform reports one.
  final String? modelLabel;

  /// Android: the concrete option this answer is about (what
  /// [AndroidModelOption.auto] chose). Null elsewhere.
  final AndroidModelOption? modelOption;

  factory HybridAvailability.fromMap(Map<Object?, Object?> m) =>
      HybridAvailability(
        status: OnDeviceStatus.values.byName(m['status'] as String),
        reason: m['reason'] as String?,
        modelLabel: m['modelLabel'] as String?,
        modelOption: AndroidModelOption._reported(m['modelOption']),
      );
}

sealed class HybridPart {
  const HybridPart();
  Map<String, Object?> toMap();
}

class HybridText extends HybridPart {
  const HybridText(this.text);
  final String text;
  @override
  Map<String, Object?> toMap() => {'type': 'text', 'text': text};
}

class HybridInlineData extends HybridPart {
  const HybridInlineData(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
  @override
  Map<String, Object?> toMap() => {
    'type': 'inlineData',
    'mimeType': mimeType,
    'bytes': bytes,
  };
}

/// What a feature asks for. It carries no mode: the app's dispatcher sets it.
class HybridTask {
  const HybridTask({
    required this.feature,
    this.systemInstruction,
    required this.parts,
    this.jsonSchema,
    required this.maxOutputTokens,
    required this.timeout,
  });

  /// Ledger key, e.g. 'pantry_scan', 'local_watch'.
  final String feature;
  final String? systemInstruction;

  /// Single turn.
  final List<HybridPart> parts;

  /// JSON Schema subset: type, properties, required, items, enum, minItems,
  /// maxItems, description. Lowercase types.
  final Map<String, Object?>? jsonSchema;
  final int maxOutputTokens;
  final Duration timeout;

  /// True when an attachment is an image (by MIME type), not any attachment.
  bool get hasImage => parts.any(
    (p) => p is HybridInlineData && p.mimeType.startsWith('image/'),
  );

  /// True when an attachment is audio. Audio never runs on-device.
  bool get hasAudio => parts.any(
    (p) => p is HybridInlineData && p.mimeType.startsWith('audio/'),
  );
}

/// What the plugin receives. Built only by the app's dispatcher.
class HybridRequest {
  const HybridRequest({
    required this.requestId,
    required this.mode,
    required this.task,
  });

  final String requestId;
  final HybridMode mode;
  final HybridTask task;

  Map<String, Object?> toMap() => {
    'requestId': requestId,
    'mode': mode.name,
    'feature': task.feature,
    'systemInstruction': task.systemInstruction,
    'parts': [for (final p in task.parts) p.toMap()],
    'jsonSchema': task.jsonSchema,
    'maxOutputTokens': task.maxOutputTokens,
    'timeoutMs': task.timeout.inMilliseconds,
  };
}

class HybridResult {
  const HybridResult({
    required this.requestId,
    required this.text,
    required this.source,
    this.modelLabel,
  });

  final String requestId;
  final String text;

  /// The SDK's own report, never inferred.
  final InferenceSource source;

  /// Observed model name if the SDK exposes one, else null. Never the
  /// requested option presented as an observation.
  final String? modelLabel;

  factory HybridResult.fromMap(Map<Object?, Object?> m) => HybridResult(
    requestId: m['requestId'] as String,
    text: m['text'] as String,
    source: InferenceSource.values.byName(m['source'] as String),
    modelLabel: m['modelLabel'] as String?,
  );
}

enum HybridErrorCode {
  unavailable,
  unsupportedInput,
  unsupportedMode,
  busy,
  quota,
  blocked,
  network,
  attestation,
  timeout,
  cancelled,
  failed,
}

class HybridException implements Exception {
  const HybridException(this.code, this.message);
  final HybridErrorCode code;
  final String message;
  @override
  String toString() => 'HybridException(${code.name}): $message';
}

/// One Dart API over each platform's official Firebase AI Logic hybrid SDK.
///
/// Rules (DESIGN.md §4): never throws for a missing bridge; availability is per
/// modality; modes are never widened; `source` comes from the SDK; generate
/// completes or throws within `task.timeout`; attachment limits apply to every
/// route, local limits only to a local run.
abstract class HybridInference {
  Future<void> configure(HybridConfig config);
  Future<HybridCapabilities> capabilities();
  Future<HybridAvailability> availability({required bool withImage});

  /// Starts work at call time, not on listen. Emits 0..1 (null if unknown),
  /// completes when ready, errors with [HybridException]. Not cancellable.
  Stream<double?> prepare({required bool withImage});
  Future<HybridResult> generate(HybridRequest request);
  Future<void> cancel(String requestId);
}
