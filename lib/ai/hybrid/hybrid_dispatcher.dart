// The only sender of hybrid requests (DESIGN.md §5).

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart' show setEquals;

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
    this._reachable,
    RemoteRouting? Function()? remoteRouting,
    String Function()? languageTag,
    String Function()? newId,
    this._currentSession,
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

  /// Live send checks for requests handed to the backend, by request id.
  final Map<String, bool Function()> _sendChecks = {};

  /// Whether the request [requestId] may still be sent now: its run is not
  /// cancelled or stale and its privacy, route and connectivity checks pass.
  /// For a backend that waits (startup configure) before it sends. Unknown
  /// ids (not from this dispatcher) are not this dispatcher's to refuse.
  bool stillAllowed(String requestId) => _sendChecks[requestId]?.call() ?? true;

  /// The app's current session (meal or pantry flow), when known. A run for
  /// any other session is stale: it never sends, and a grant for it is void.
  final String Function()? _currentSession;

  /// True when [run] no longer belongs to the live session or ledger: the
  /// next meal started, or the cook went back to the pantry.
  bool _stale(_Run run) =>
      _ledger.generation != run.ledgerGeneration ||
      (_currentSession != null && _currentSession() != run.sessionId);
  final bool Function() _isOnline;

  /// A native connectivity probe (Android/iOS), awaited before routing and
  /// before every attempt that may upload. Null: [_isOnline] alone decides.
  final Future<bool> Function()? _reachable;

  Future<void> _probe(_Run run) async {
    final probe = _reachable;
    if (probe == null) return;
    try {
      run.reachable = await probe();
    } catch (_) {
      run.reachable = true; // unknown: let the request decide
    }
  }

  bool _online(_Run run) => _isOnline() && run.reachable;
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
      ledgerGeneration: _ledger.generation,
    );
    return HybridOperation(_newId(), _dispatch(op, run, validate), op.cancel);
  }

  Future<DispatchResult> _dispatch(
    _Operation op,
    _Run run,
    ResultValidator? validate,
  ) async {
    final task = run.task;
    // A request for a session that is no longer current (meal A after meal
    // B started) is never routed, let alone sent.
    if (_stale(run)) return run.cancelled();
    final caps = await _safe(
      _inference.capabilities,
      const HybridCapabilities.none(),
    );
    await _probe(run);
    if (op.cancelled || _stale(run)) return run.cancelled();
    final availability = await _safe(
      () => _inference.availability(withImage: run.hasImage),
      const HybridAvailability(status: OnDeviceStatus.unavailable),
    );
    if (op.cancelled || _stale(run)) return run.cancelled();

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
        online: _online(run),
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
    await _probe(run);
    if (op.cancelled || _stale(run)) {
      return const _Blocked(RouteReason.cancelled);
    }
    final decision = decideCloudRetry(
      feature: run.task.feature,
      kinds: run.kinds,
      localOnly: localOnlyFor(_privacy, run.task.feature),
      cloudApproved: _routes.allows(CloudRoute.hybridFallback),
      online: _online(run),
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
    if (outcome case _Blocked(:final reason, :final recorded)
        when reason != RouteReason.cancelled && !recorded) {
      _recordBlocked(run, reason);
    }
    return outcome;
  }

  bool _adapterApplies(_Failed failed, HybridMode mode, _Run run) {
    if (_adapter == null || mode == HybridMode.onlyOnDevice) return false;
    if (failed.code == HybridErrorCode.unavailable) return true;
    return (failed.code == HybridErrorCode.unsupportedInput ||
            failed.code == HybridErrorCode.rejectedBeforeSend) &&
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
      if (op.cancelled || _stale(run)) return RouteReason.cancelled;
      if (!mayUpload) return null;
      if (localOnlyFor(_privacy, feature)) return RouteReason.localOnlySetting;
      if (!_routes.allows(CloudRoute.hybridFallback)) {
        return RouteReason.cloudNotApproved;
      }
      // Connectivity too: the device may have gone offline while the consent
      // prompt was open. An offline refusal sends nothing.
      if (!_online(run)) return RouteReason.offline;
      return null;
    }

    final early = liveCheck();
    if (early != null) return _Blocked(early);

    ConsentGrant? grant;
    if (mayUpload && needsConsent) {
      // A grant the feature supplied is used if it fits (and is unspent);
      // otherwise the cook is asked.
      final offered = carriedGrant ?? run.suppliedGrant;
      grant = offered != null && _grantFits(offered, run)
          ? offered
          : await _askConsent(run, mode);
      // The cook may have changed a setting, cancelled or lost the network
      // while the prompt was open: re-read native reachability too.
      await _probe(run);
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
    // begin() notifies ledger listeners synchronously, and one may cancel,
    // switch on local-only or go offline: check again immediately before
    // the send. A refusal here sends nothing and settles the leg unsent.
    _Blocked unsent(RouteReason refused) {
      final error = switch (refused) {
        RouteReason.cancelled => HybridErrorCode.cancelled,
        RouteReason.offline => HybridErrorCode.network,
        _ => HybridErrorCode.blocked,
      };
      _ledger.withdraw(entry, error: error);
      run.legs.add(
        InferenceLeg(
          requestId: requestId,
          feature: feature,
          mode: mode,
          kinds: run.kinds,
          transferPermitted: false,
          provenance: Provenance.unknown,
          error: error,
        ),
      );
      return _Blocked(refused, recorded: true);
    }

    if (liveCheck() case final refused?) return unsent(refused);
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

    // A backend that waits before sending (startup configure) asks again
    // through [stillAllowed] immediately before it sends.
    _sendChecks[requestId] = () => liveCheck() == null;
    try {
      final request = HybridRequest(
        requestId: requestId,
        mode: mode,
        task: run.task,
      );
      final result = viaAdapter
          ? await _adapter!.send(request)
          : await _inference.generate(request);
      // An answer for a run whose session ended is recorded but never used.
      if (_stale(run)) {
        finish(Provenance.unknown, error: HybridErrorCode.cancelled);
        return const _Blocked(RouteReason.cancelled);
      }
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
    } on NotSentException catch (e) {
      // Refused before anything was sent (after the backend's startup wait).
      final reason =
          liveCheck() ??
          (e.code == HybridErrorCode.cancelled ? RouteReason.cancelled : null);
      if (reason != null) return unsent(reason);
      _ledger.withdraw(entry, error: e.code);
      run.legs.add(
        InferenceLeg(
          requestId: requestId,
          feature: feature,
          mode: mode,
          kinds: run.kinds,
          transferPermitted: false,
          provenance: Provenance.unknown,
          error: e.code,
        ),
      );
      return _Failed(e.code, sent: true);
    } on HybridException catch (e) {
      // Whether data left on a send allowed to upload is not known.
      finish(Provenance.unknown, error: e.code);
      if (op.cancelled || e.code == HybridErrorCode.cancelled) {
        return const _Blocked(RouteReason.cancelled);
      }
      // The grant stays spent once a request reached the backend: nothing
      // proves a rejection came before any transfer (a backend could report
      // unsupportedInput after sending), so a fallback asks the cook again.
      // Only rejectedBeforeSend, a bridge's explicit proof that nothing was
      // sent (SS-105), refunds the grant and carries it to the adapter.
      final refund =
          e.code == HybridErrorCode.rejectedBeforeSend && grant != null;
      if (refund) _spent.remove(grant);
      return _Failed(e.code, sent: true, unspentGrant: refund ? grant : null);
    } catch (_) {
      finish(Provenance.unknown, error: HybridErrorCode.failed);
      if (op.cancelled) return const _Blocked(RouteReason.cancelled);
      return const _Failed(HybridErrorCode.failed, sent: true);
    } finally {
      _sendChecks.remove(requestId);
      op.inFlight = null;
      op.cancelInFlight = null;
    }
  }

  /// Asks for [mode], the route this attempt takes, so the prompt says
  /// plainly when a yes sends at once.
  Future<ConsentGrant?> _askConsent(_Run run, HybridMode mode) async {
    try {
      return await _consent.request(
        ConsentAsk(
          feature: run.task.feature,
          kinds: run.kinds,
          payloadDigest: run.digest,
          sessionId: run.sessionId,
          mode: mode,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// A grant fits only what the cook was shown: this feature, exactly these
  /// kinds of data, this payload digest and this session. It must also be
  /// unused and issued by this dispatcher's own gate (a grant from any other
  /// gate is not the cook's answer to this prompt, so the cook is asked).
  bool _grantFits(ConsentGrant grant, _Run run) =>
      _consent.issued(grant) &&
      !_spent.contains(grant) &&
      grant.ask.feature == run.task.feature &&
      setEquals(grant.ask.kinds, run.kinds) &&
      grant.ask.payloadDigest == run.digest &&
      grant.ask.sessionId == run.sessionId;

  /// A fallback or retry that the checks stopped. Nothing was sent. When no
  /// earlier leg exists (the bridge was never reached) this is the first
  /// attempt, which, like a blocked decision, leaves no leg.
  void _recordBlocked(_Run run, RouteReason reason) {
    if (run.legs.isEmpty) return;
    // Never write an old run's leg into the next session's ledger.
    if (_stale(run)) return;
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
    required this.ledgerGeneration,
    this.suppliedGrant,
  });

  final HybridTask task;
  final String sessionId;

  /// The ledger generation this run started under. A new session (the next
  /// meal, a new pantry flow) ends the run: no fallback or retry sends this
  /// payload under the next session's ledger.
  final int ledgerGeneration;

  /// SHA-256 of the serialized task; computed only when consent is needed.
  late final String digest = hybridPayloadDigest(task);
  final Set<DataKind> kinds;
  final ConsentGrant? suppliedGrant;
  final List<InferenceLeg> legs = [];

  /// The latest native connectivity probe for this run (true when none).
  bool reachable = true;

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

  /// A grant refunded on `rejectedBeforeSend`, which the fallback may use.
  final ConsentGrant? unspentGrant;
}

class _Blocked extends _Outcome {
  const _Blocked(this.reason, {this.recorded = false});
  final RouteReason reason;

  /// The attempt already left its own unsent leg (refused after admission).
  final bool recorded;
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
        // The MIME type is normalized here, once: `Image/JPEG ` is an image
        // for routing, consent, the digest and the ledger alike.
        HybridInlineData(:final bytes, :final mimeType) => HybridInlineData(
          Uint8List.fromList(bytes),
          normalizeMimeType(mimeType),
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
