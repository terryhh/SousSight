import 'dart:async';
import 'dart:collection';

import 'contract.dart';

/// Scriptable fake for tests and Rehearsal mode. Records every request.
/// Card SS-061 extends it; keep the existing members stable.
class FakeHybridInference implements HybridInference {
  FakeHybridInference({
    HybridCapabilities? capabilities,
    this.textAvailability = const HybridAvailability(
      status: OnDeviceStatus.available,
    ),
    this.imageAvailability = const HybridAvailability(
      status: OnDeviceStatus.available,
    ),
  }) : capabilitiesValue = capabilities ?? fakeWebCapabilities;

  HybridCapabilities capabilitiesValue;
  HybridAvailability textAvailability;
  HybridAvailability imageAvailability;
  HybridConfig? config;

  final List<HybridRequest> requests = [];
  final List<String> cancelled = [];

  /// Each scripted response is a [HybridResult] (requestId is replaced), a
  /// [HybridException] to throw, or a function `(HybridRequest) -> Object`.
  final Queue<Object> script = Queue<Object>();
  Duration delay = Duration.zero;

  void enqueueText(String text, {InferenceSource source = InferenceSource.onDevice}) =>
      script.add(HybridResult(requestId: '', text: text, source: source));

  @override
  Future<void> configure(HybridConfig config) async => this.config = config;

  @override
  Future<HybridCapabilities> capabilities() async => capabilitiesValue;

  @override
  Future<HybridAvailability> availability({required bool withImage}) async =>
      withImage ? imageAvailability : textAvailability;

  @override
  Stream<double?> prepare({required bool withImage}) =>
      Stream<double?>.fromIterable(const [0.5, 1.0]);

  @override
  Future<HybridResult> generate(HybridRequest request) async {
    requests.add(request);
    // Reserve this call's scripted answer now, so a cancelled or timed-out
    // call can never hand its answer to a later request.
    final reserved = script.isEmpty ? null : script.removeFirst();
    Future<HybridResult> respond() async {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (cancelled.contains(request.requestId)) {
        throw const HybridException(HybridErrorCode.cancelled, 'cancelled');
      }
      if (reserved == null) {
        throw const HybridException(HybridErrorCode.failed, 'No scripted response');
      }
      var next = reserved;
      if (next is Object Function(HybridRequest)) next = next(request);
      if (next is HybridException) throw next;
      final r = next as HybridResult;
      return HybridResult(
        requestId: request.requestId,
        text: r.text,
        source: r.source,
        modelLabel: r.modelLabel,
      );
    }

    // Contract: complete or throw timeout within task.timeout; a late
    // outcome is discarded.
    return respond().timeout(
      request.task.timeout,
      onTimeout: () => throw const HybridException(
        HybridErrorCode.timeout,
        'timed out',
      ),
    );
  }

  @override
  Future<void> cancel(String requestId) async => cancelled.add(requestId);
}

const fakeWebCapabilities = HybridCapabilities(
  platform: 'web',
  local: LocalModelLimits(
    modelFamily: 'Gemini Nano',
    supportsImage: true,
    supportsJsonSchema: true,
    maxTotalTokens: 9216,
    defaultOutputReserve: 512,
    imageTokenEstimate: 1000,
    validatedLanguages: ['en', 'es', 'ja', 'de', 'fr'],
  ),
  supportedModes: {
    HybridMode.preferOnDevice,
    HybridMode.onlyOnDevice,
    HybridMode.preferInCloud,
    HybridMode.onlyInCloud,
  },
);

const fakeIosCapabilities = HybridCapabilities(
  platform: 'ios',
  local: LocalModelLimits(
    modelFamily: 'Apple Foundation Models',
    supportsImage: false,
    supportsJsonSchema: false,
    maxTotalTokens: 4096,
    defaultOutputReserve: 256,
    imageTokenEstimate: 0,
    validatedLanguages: ['en'],
  ),
  supportedModes: {
    HybridMode.preferOnDevice,
    HybridMode.onlyOnDevice,
    HybridMode.onlyInCloud,
  },
);
