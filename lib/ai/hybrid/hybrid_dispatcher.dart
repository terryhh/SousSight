// The only sender of hybrid requests (DESIGN.md §5).

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import 'hybrid_types.dart';
import 'inference_ledger.dart';
import 'inference_policy.dart';
import 'payload_digest.dart';

/// Sends a cloud-only request with the Dart `firebase_ai` client when the
/// bridge cannot (§5 step 4). Its legs are recorded as
/// [Provenance.cloudAdapter]. The real implementation wraps `firebase_ai`;
/// it must honour [HybridRequest.task] exactly and never be called directly
/// by features.
abstract class CloudFallbackSender {
  Future<HybridResult> send(HybridRequest request);

  /// Best effort; a late result is discarded by the dispatcher anyway.
  Future<void> cancel(String requestId);
}

/// Production [HybridDispatcher].
///
/// Before every send (first attempt, Dart cloud fallback, semantic retry) it
/// checks, in order: the operation is not cancelled; `PrivacySettings.localOnly`
/// as it is now; [CloudRoutes]; and, when the send may upload and consent is
/// needed, a [ConsentGrant] for this payload digest and session that has not
/// been used. The checks run again after the consent prompt returns.
class DefaultHybridDispatcher implements HybridDispatcher {
  DefaultHybridDispatcher({
    required this._inference,
    required this._privacy,
    required CloudRoutes cloudRoutes,
    required this._consent,
    required this._ledger,
    CloudFallbackSender? cloudFallback,
    bool Function()? isOnline,
    RemoteRouting? Function()? remoteRouting,
    String Function()? languageTag,
    String Function()? newId,
  }) : _routes = cloudRoutes,
       _adapter = cloudFallback,
       _isOnline = isOnline ?? (() => true),
       _remote = remoteRouting ?? (() => null),
       _language = languageTag ?? (() => 'en'),
       _newId = newId ?? _defaultIds();

  final HybridInference _inference;
  final PrivacySettings _privacy;
  final CloudRoutes _routes;
  final ConsentGate _consent;
  final InferenceLedger _ledger;
  final CloudFallbackSender? _adapter;
  final bool Function() _isOnline;
  final RemoteRouting? Function() _remote;
  final String Function() _language;
  final String Function() _newId;

  /// Grants are used once: a grant that paid for a send is spent.
  final Set<ConsentGrant> _spent = HashSet<ConsentGrant>.identity();

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    final op = _Operation();
    // Everything below (routing, digest, consent, every send) uses this
    // snapshot, taken before the first await: a caller mutating its bytes,
    // parts or schema later cannot change what a grant covers or what is sent.
    final snapshot = snapshotTask(task);
    final run = _Run(
      task: snapshot,
      sessionId: sessionId,
      kinds: taskDataKinds(snapshot),
      suppliedGrant: grant,
    );
    return HybridOperation(_newId(), _dispatch(op, run, validate), op.cancel);
  }

  Future<DispatchResult> _dispatch(
    _Operation op,
    _Run run,
    ResultValidator? validate,
  ) async {
    final task = run.task;
    final caps = await _safe(
      _inference.capabilities,
      const HybridCapabilities.none(),
    );
    if (op.cancelled) return run.cancelled();
    final availability = await _safe(
      () => _inference.availability(withImage: run.hasImage),
      const HybridAvailability(status: OnDeviceStatus.unavailable),
    );
    if (op.cancelled) return run.cancelled();

    final decision = decideRoute(
      RouteInput(
        feature: task.feature,
        hasImage: run.hasImage,
        hasAudio: task.hasAudio,
        estimatedTokens: estimateLocalTokens(
          task,
          imageTokenEstimate:
              caps.local?.imageTokenEstimate ?? defaultImageTokenEstimate,
        ),
        languageTag: _language(),
        localOnly: localOnlyFor(_privacy, task.feature),
        online: _isOnline(),
        cloudApproved: _routes.allows(CloudRoute.hybridFallback),
        capabilities: caps,
        status: availability.status,
        remote: _remote(),
      ),
    );
    final mode = decision.mode;
    if (mode == null) {
      return DispatchResult(legs: const [], blocked: decision.reason);
    }

    // 1. First attempt, through the bridge when it can carry this mode.
    _Outcome first;
    if (caps.supportedModes.contains(mode)) {
      first = await _attempt(
        op,
        run,
        mode,
        needsConsent: decision.needsConsent,
        viaAdapter: false,
      );
    } else {
      // Bridge unavailable: nothing was sent.
      first = const _Failed(HybridErrorCode.unavailable, sent: false);
    }

    switch (first) {
      case _Blocked(:final reason):
        return run.result(blocked: reason);
      case _Failed failed:
        if (op.cancelled) return run.cancelled();
        if (!_adapterApplies(failed, mode, run)) {
          return run.result(blocked: failed.sent ? null : decision.reason);
        }
        // 2. Dart cloud fallback.
        final fallback = await _cloudSend(
          op,
          run,
          reason: decision.reason,
          viaAdapter: true,
          carriedGrant: failed.unspentGrant,
        );
        return _finish(op, run, fallback, validate, allowRetry: false);
      case _Ok():
        return _finish(op, run, first, validate, allowRetry: true);
    }
  }

  /// Validates a result and, when an on-device answer is rejected, makes the
  /// one semantic retry (§5 step 5).
  Future<DispatchResult> _finish(
    _Operation op,
    _Run run,
    _Outcome outcome,
    ResultValidator? validate, {
    required bool allowRetry,
  }) async {
    switch (outcome) {
      case _Blocked(:final reason):
        return run.result(blocked: reason);
      case _Failed():
        return op.cancelled ? run.cancelled() : run.result();
      case _Ok(:final text, :final provenance):
        if (validate == null || validate(text) == null) {
          return run.result(text: text);
        }
        final retryable =
            allowRetry &&
            provenance == Provenance.sdkOnDevice &&
            featureRouteFor(run.task.feature).semanticRetry;
        if (!retryable) return run.result();
        final retry = await _cloudSend(
          op,
          run,
          reason: RouteReason.cloudRetryAfterCheck,
          viaAdapter: false,
        );
        return _finish(op, run, retry, validate, allowRetry: false);
    }
  }

  /// A cloud-only send for a fallback or retry. Re-decides with the live
  /// settings, then goes through the bridge if it can carry `onlyInCloud`,
  /// else the Dart adapter.
  Future<_Outcome> _cloudSend(
    _Operation op,
    _Run run, {
    required RouteReason reason,
    required bool viaAdapter,
    ConsentGrant? carriedGrant,
  }) async {
    if (op.cancelled) return const _Blocked(RouteReason.cancelled);
    final decision = decideCloudRetry(
      feature: run.task.feature,
      kinds: run.kinds,
      localOnly: localOnlyFor(_privacy, run.task.feature),
      cloudApproved: _routes.allows(CloudRoute.hybridFallback),
      online: _isOnline(),
      reason: reason,
    );
    if (decision.blocked) {
      _recordBlocked(run, decision.reason);
      return _Blocked(decision.reason);
    }
    var useAdapter = viaAdapter;
    if (!useAdapter) {
      final caps = await _safe(
        _inference.capabilities,
        const HybridCapabilities.none(),
      );
      useAdapter = !caps.supportedModes.contains(HybridMode.onlyInCloud);
    }
    if (useAdapter && _adapter == null) {
      return const _Failed(HybridErrorCode.unavailable, sent: false);
    }
    final outcome = await _attempt(
      op,
      run,
      HybridMode.onlyInCloud,
      needsConsent: decision.needsConsent,
      viaAdapter: useAdapter,
      carriedGrant: carriedGrant,
    );
    if (outcome case _Blocked(:final reason)
        when reason != RouteReason.cancelled) {
      _recordBlocked(run, reason);
    }
    return outcome;
  }

  bool _adapterApplies(_Failed failed, HybridMode mode, _Run run) {
    if (_adapter == null || mode == HybridMode.onlyOnDevice) return false;
    if (failed.code == HybridErrorCode.unavailable) return true;
    return failed.code == HybridErrorCode.unsupportedInput &&
        mode == HybridMode.onlyInCloud &&
        run.task.parts.any((p) => p is HybridInlineData);
  }

  /// Gate, ledger, send, record.
  Future<_Outcome> _attempt(
    _Operation op,
    _Run run,
    HybridMode mode, {
    required bool needsConsent,
    required bool viaAdapter,
    ConsentGrant? carriedGrant,
  }) async {
    final mayUpload = mode != HybridMode.onlyOnDevice;
    final feature = run.task.feature;

    RouteReason? liveCheck() {
      if (op.cancelled) return RouteReason.cancelled;
      if (!mayUpload) return null;
      if (localOnlyFor(_privacy, feature)) return RouteReason.localOnlySetting;
      if (!_routes.allows(CloudRoute.hybridFallback)) {
        return RouteReason.cloudNotApproved;
      }
      // Connectivity too: the device may have gone offline while the consent
      // prompt was open. An offline refusal sends nothing.
      if (!_isOnline()) return RouteReason.offline;
      return null;
    }

    final early = liveCheck();
    if (early != null) return _Blocked(early);

    ConsentGrant? grant;
    if (mayUpload && needsConsent) {
      // A grant the feature supplied, or one an unsent attempt did not spend,
      // is used if it fits; otherwise the cook is asked.
      final offered = carriedGrant ?? run.suppliedGrant;
      grant = offered != null && _grantFits(offered, run)
          ? offered
          : await _askConsent(run);
      // The cook may have changed a setting or cancelled while the prompt
      // was open.
      final late = liveCheck();
      if (late != null) return _Blocked(late);
      if (grant == null || !_grantFits(grant, run)) {
        return const _Blocked(RouteReason.consentDeclined);
      }
      _spent.add(grant);
    }

    final requestId = _newId();
    final pendingLeg = InferenceLeg(
      requestId: requestId,
      feature: feature,
      mode: mode,
      kinds: run.kinds,
      transferPermitted: mayUpload,
      provenance: Provenance.unknown,
    );
    final entry = _ledger.begin(pendingLeg);
    op.inFlight = requestId;
    op.cancelInFlight = viaAdapter ? _adapter!.cancel : _inference.cancel;

    InferenceLeg finish(
      Provenance provenance, {
      String? label,
      HybridErrorCode? error,
    }) {
      _ledger.complete(
        entry,
        provenance: provenance,
        modelLabel: label,
        error: error,
      );
      final leg = InferenceLeg(
        requestId: requestId,
        feature: feature,
        mode: mode,
        kinds: run.kinds,
        transferPermitted: mayUpload,
        provenance: provenance,
        modelLabel: label,
        error: error,
      );
      run.legs.add(leg);
      return leg;
    }

    try {
      final request = HybridRequest(
        requestId: requestId,
        mode: mode,
        task: run.task,
      );
      final result = viaAdapter
          ? await _adapter!.send(request)
          : await _inference.generate(request);
      final provenance = viaAdapter
          ? Provenance.cloudAdapter
          : result.source == InferenceSource.onDevice
          ? Provenance.sdkOnDevice
          : Provenance.sdkCloud;
      if (!viaAdapter &&
          mode == HybridMode.onlyOnDevice &&
          provenance != Provenance.sdkOnDevice) {
        // The backend widened the mode. Record what it reported; never use it.
        finish(
          provenance,
          label: result.modelLabel,
          error: HybridErrorCode.failed,
        );
        return const _Failed(HybridErrorCode.failed, sent: true);
      }
      finish(provenance, label: result.modelLabel);
      if (op.cancelled) return const _Blocked(RouteReason.cancelled);
      return _Ok(result.text, provenance);
    } on HybridException catch (e) {
      // Whether data left on a send allowed to upload is not known.
      finish(Provenance.unknown, error: e.code);
      if (op.cancelled || e.code == HybridErrorCode.cancelled) {
        return const _Blocked(RouteReason.cancelled);
      }
      // The contract rejects unsupportedInput before any SDK call, so the
      // grant did not pay for a transfer and may carry to the adapter.
      final refund =
          e.code == HybridErrorCode.unsupportedInput && grant != null;
      if (refund) _spent.remove(grant);
      return _Failed(e.code, sent: true, unspentGrant: refund ? grant : null);
    } catch (_) {
      finish(Provenance.unknown, error: HybridErrorCode.failed);
      if (op.cancelled) return const _Blocked(RouteReason.cancelled);
      return const _Failed(HybridErrorCode.failed, sent: true);
    } finally {
      op.inFlight = null;
      op.cancelInFlight = null;
    }
  }

  Future<ConsentGrant?> _askConsent(_Run run) async {
    try {
      return await _consent.request(
        ConsentAsk(
          feature: run.task.feature,
          kinds: run.kinds,
          payloadDigest: run.digest,
          sessionId: run.sessionId,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// The digest covers the feature and every byte that could leave, so a
  /// digest and session match is the whole test (plus "not yet used" and
  /// "issued by this dispatcher's own gate": a grant from any other gate is
  /// not the cook's answer to this prompt, so the cook is asked).
  bool _grantFits(ConsentGrant grant, _Run run) =>
      _consent.issued(grant) &&
      !_spent.contains(grant) &&
      grant.ask.payloadDigest == run.digest &&
      grant.ask.sessionId == run.sessionId;

  /// A fallback or retry that the checks stopped. Nothing was sent. When no
  /// earlier leg exists (the bridge was never reached) this is the first
  /// attempt, which, like a blocked decision, leaves no leg.
  void _recordBlocked(_Run run, RouteReason reason) {
    if (run.legs.isEmpty) return;
    final leg = InferenceLeg(
      requestId: _newId(),
      feature: run.task.feature,
      mode: HybridMode.onlyInCloud,
      kinds: run.kinds,
      transferPermitted: false,
      provenance: Provenance.unknown,
      error: reason == RouteReason.offline
          ? HybridErrorCode.network
          : HybridErrorCode.blocked,
    );
    _ledger.record(leg);
    run.legs.add(leg);
  }

  static Future<T> _safe<T>(Future<T> Function() call, T fallback) async {
    try {
      return await call();
    } catch (_) {
      return fallback;
    }
  }

  static String Function() _defaultIds() {
    var seq = 0;
    final base = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return () => 'hd-$base-${++seq}';
  }
}

class _Operation {
  bool cancelled = false;
  String? inFlight;
  Future<void> Function(String requestId)? cancelInFlight;

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    final id = inFlight;
    final cancelFn = cancelInFlight;
    if (id != null && cancelFn != null) {
      unawaited(cancelFn(id).catchError((Object _) {}));
    }
  }
}

class _Run {
  _Run({
    required this.task,
    required this.sessionId,
    required this.kinds,
    this.suppliedGrant,
  });

  final HybridTask task;
  final String sessionId;

  /// SHA-256 of the serialized task; computed only when consent is needed.
  late final String digest = hybridPayloadDigest(task);
  final Set<DataKind> kinds;
  final ConsentGrant? suppliedGrant;
  final List<InferenceLeg> legs = [];

  bool get hasImage => task.hasImage;

  DispatchResult result({String? text, RouteReason? blocked}) => DispatchResult(
    text: text,
    legs: List.unmodifiable(legs),
    blocked: blocked,
  );

  DispatchResult cancelled() => result(blocked: RouteReason.cancelled);
}

sealed class _Outcome {
  const _Outcome();
}

class _Ok extends _Outcome {
  const _Ok(this.text, this.provenance);
  final String text;
  final Provenance provenance;
}

class _Failed extends _Outcome {
  const _Failed(this.code, {required this.sent, this.unspentGrant});
  final HybridErrorCode code;

  /// False when nothing reached the bridge (bridge unavailable).
  final bool sent;
  final ConsentGrant? unspentGrant;
}

class _Blocked extends _Outcome {
  const _Blocked(this.reason);
  final RouteReason reason;
}

/// A deep copy of [task]: new byte buffers, new parts list, and an
/// unmodifiable deep copy of the schema.
HybridTask snapshotTask(HybridTask task) => HybridTask(
  feature: task.feature,
  systemInstruction: task.systemInstruction,
  parts: List.unmodifiable([
    for (final p in task.parts)
      switch (p) {
        HybridText(:final text) => HybridText(text),
        HybridInlineData(:final bytes, :final mimeType) => HybridInlineData(
          Uint8List.fromList(bytes),
          mimeType,
        ),
      },
  ]),
  jsonSchema: task.jsonSchema == null
      ? null
      : _deepCopy(task.jsonSchema) as Map<String, Object?>,
  maxOutputTokens: task.maxOutputTokens,
  timeout: task.timeout,
);

Object? _deepCopy(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable({
    for (final e in value.entries) e.key as String: _deepCopy(e.value),
  }),
  List() => List<Object?>.unmodifiable([for (final v in value) _deepCopy(v)]),
  _ => value,
};
