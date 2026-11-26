// App-wide hybrid inference wiring (card SS-083, DESIGN.md §5).
//
// One HybridInference (configured once), one DefaultHybridDispatcher, one
// session ledger, one set of privacy preferences and one consent dialog are
// shared by the pantry flow, the cooking screen and the trust sheets.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';

import '../ai/cooking_research_client.dart';
import '../ai/hybrid/hybrid_dispatcher.dart';
import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart';
import '../ai/hybrid/inference_ledger.dart';
import '../config/remote_policy.dart';
import '../core/cloud_send.dart';
import '../label/household_allergens.dart';
import '../label/label_check_controller.dart';
import '../trust/ledger_source.dart';
import '../trust/privacy_preferences.dart';
import 'cloud_send_recorder.dart';
import 'network_reachability.dart';
import 'consent_copy.dart';
import 'online_status.dart';

export 'consent_copy.dart';

/// Cloud model for hybrid fallback and the Dart cloud adapter. Defaults to
/// the research model so one Flash model id is configured for every non-Live
/// call; DESIGN.md §7 says the default stands only after G1 confirms it.
const kHybridCloudModel = String.fromEnvironment(
  'HYBRID_CLOUD_MODEL',
  defaultValue: kCookingResearchModel,
);

/// Android on-device model: `--dart-define=ANDROID_MODEL=stable|preview|
/// previewFast`. Unset or unknown means stable, the device's supported
/// Gemini Nano; preview (Nano 4) is an explicit opt-in.
final kAndroidModel = AndroidModelOption.fromName(
  const String.fromEnvironment('ANDROID_MODEL'),
);

/// Who the cook is told a cloud request goes to.
const kCloudRecipient = "Google's Gemini model, through Firebase AI Logic";

/// Delegates to [inner], but every call that needs the configuration waits
/// for the one [HybridInference.configure] call made at startup. A failed
/// configure is not retried here; `generate` then fails as the bridge says.
///
/// The wait is bounded, and one deadline covers it all: `generate` has the
/// task's own timeout for configure plus generation together. The backend is
/// handed only what remains of that budget, and when the budget runs out the
/// request is cancelled and `generate` throws
/// `HybridException(HybridErrorCode.timeout)`; a late answer is dropped.
/// [capabilities] and [availability] take at most [configureWait] in all (on
/// web, configure includes an unbounded `import()`); past that they report
/// no local model, as for a missing bridge. A request that times out during
/// startup is never forwarded.
///
/// Routing waits for configuration too ([capabilities] awaits it), so a
/// decision is made against the policy as it is once the backend is ready.
/// [mayForward], when given, is checked again after the wait, immediately
/// before a request that may upload is forwarded: a late change (the
/// Remote Config kill switch, local-only) refuses it with
/// [HybridErrorCode.blocked] instead of sending.
class ConfiguredHybridInference implements HybridInference {
  ConfiguredHybridInference(
    this.inner,
    HybridConfig config, {
    this.mayForward,
    this.stillWanted,
    this.configureWait = const Duration(seconds: 10),
    this._stopwatch = Stopwatch.new,
  }) : _configured = inner
           .configure(config)
           .then<void>(
             (_) {},
             onError: (Object error) =>
                 debugPrint('Hybrid configure failed (${error.runtimeType})'),
           );

  final HybridInference inner;
  final Future<void> _configured;
  final bool Function(HybridRequest request)? mayForward;

  /// Read after the startup wait for every request, any mode: false when the
  /// caller no longer wants it sent (the dispatcher's run was cancelled, its
  /// session ended, or its privacy or connectivity checks now refuse).
  final bool Function(HybridRequest request)? stillWanted;

  /// Measures how much of a request's budget startup spent. Injectable so
  /// fake-time tests can observe the remaining budget handed to [inner].
  final Stopwatch Function() _stopwatch;

  /// The longest [capabilities] waits for the startup configure.
  final Duration configureWait;

  /// Completes when the startup configure has settled (either way).
  Future<void> get configured => _configured;

  @override
  Future<void> configure(HybridConfig config) => inner.configure(config);

  /// Discovery ([capabilities], [availability]) is bounded as a whole by
  /// [configureWait]: the wait for configure plus the backend's own answer
  /// (on web, `availability` awaits the same `import()` as configure). Past
  /// that it reports what a missing bridge reports, so no caller hangs and
  /// no caller has to survive an exception to show the trust controls.
  Future<T> _discover<T>(Future<T> Function() call, T missing) => _configured
      .then((_) => call())
      .timeout(
        configureWait,
        onTimeout: () {
          debugPrint('Hybrid startup still pending; reporting no local model.');
          return missing;
        },
      );

  @override
  Future<HybridCapabilities> capabilities() =>
      _discover(inner.capabilities, const HybridCapabilities.none());

  @override
  Future<HybridAvailability> availability({required bool withImage}) =>
      _discover(
        () => inner.availability(withImage: withImage),
        const HybridAvailability(
          status: OnDeviceStatus.unavailable,
          reason: 'bridge_unavailable',
        ),
      );

  /// Not awaited: on web the download must start inside the cook's tap.
  @override
  Stream<double?> prepare({required bool withImage}) =>
      inner.prepare(withImage: withImage);

  /// One deadline for startup and generation together: the task's timeout,
  /// measured from this call. It is enforced by a single timer, so a slow
  /// configure, a slow backend or both together cannot stretch it.
  @override
  Future<HybridResult> generate(HybridRequest request) {
    final budget = request.task.timeout;
    final clock = _stopwatch()..start();
    var expired = false;
    var sent = false;
    final id = request.requestId;
    final cancelled = Completer<void>();
    _waiting[id] = cancelled;

    Future<HybridResult> run() async {
      // Configure races cancellation (and, below, the deadline): a configure
      // that never settles cannot hold a cancelled request.
      try {
        await Future.any([_configured, cancelled.future]);
      } finally {
        if (identical(_waiting[id], cancelled)) _waiting.remove(id);
      }
      // Cancelled while waiting for configure: the backend never had this
      // request, so it is never forwarded.
      if (cancelled.isCompleted) {
        throw const NotSentException(
          HybridErrorCode.cancelled,
          'Cancelled before it was sent.',
        );
      }
      // The deadline may have passed while configure was running; a request
      // that timed out during startup is never forwarded.
      if (expired) throw _expiredUnsent;
      final remaining = budget - clock.elapsed;
      // The bridge carries whole milliseconds; under 1ms nothing can run.
      if (remaining.inMilliseconds <= 0) throw _expiredUnsent;
      // The final check, after the wait and immediately before the send:
      // the caller's run must still be current (its session, cancellation,
      // privacy and connectivity), for every mode.
      final current = stillWanted;
      if (current != null && !current(request)) {
        throw const NotSentException(
          HybridErrorCode.cancelled,
          'The request was no longer wanted when startup finished.',
        );
      }
      final check = mayForward;
      if (request.mode != HybridMode.onlyOnDevice &&
          check != null &&
          !check(request)) {
        throw const NotSentException(
          HybridErrorCode.blocked,
          'Cloud help was turned off before this request was sent.',
        );
      }
      sent = true;
      // Only what is left of the one budget; startup already spent the rest.
      final HybridResult result;
      try {
        result = await inner.generate(_withTimeout(request, remaining));
      } catch (_) {
        if (clock.elapsed >= budget) throw _expired;
        rethrow;
      }
      // A busy isolate can deliver the outcome before the deadline timer
      // runs; the monotonic clock decides, so a late answer is never used.
      if (clock.elapsed >= budget) throw _expired;
      return result;
    }

    return run().timeout(
      budget,
      onTimeout: () {
        expired = true;
        if (identical(_waiting[id], cancelled)) _waiting.remove(id);
        // A backend that overruns is stopped; its late answer or error is
        // dropped by the abandoned future.
        if (!sent) throw _expiredUnsent;
        unawaited(
          Future.sync(() => inner.cancel(request.requestId))
              .catchError((Object _) {}),
        );
        throw _expired;
      },
    );
  }

  static HybridRequest _withTimeout(HybridRequest r, Duration timeout) =>
      HybridRequest(
        requestId: r.requestId,
        mode: r.mode,
        task: HybridTask(
          feature: r.task.feature,
          systemInstruction: r.task.systemInstruction,
          parts: r.task.parts,
          jsonSchema: r.task.jsonSchema,
          maxOutputTokens: r.task.maxOutputTokens,
          timeout: timeout,
        ),
      );

  static const _expiredUnsent = NotSentException(
    HybridErrorCode.timeout,
    'Hybrid inference was still starting up at the request deadline.',
  );

  static const _expired = HybridException(
    HybridErrorCode.timeout,
    'Hybrid inference ran past the request deadline.',
  );

  /// Requests still waiting for the startup configure, each with the signal
  /// that cancels it.
  final Map<String, Completer<void>> _waiting = {};

  @override
  Future<void> cancel(String requestId) async {
    final waiting = _waiting.remove(requestId);
    if (waiting != null) {
      // Not forwarded yet: stop it here; the backend has no such request.
      if (!waiting.isCompleted) waiting.complete();
      return;
    }
    return inner.cancel(requestId);
  }
}

/// Lets the trust UI read the dispatcher's [InferenceLedger].
class InferenceLedgerSource implements LedgerSource {
  InferenceLedgerSource(this.ledger);
  final InferenceLedger ledger;

  @override
  List<InferenceLeg> get legs => ledger.legs;

  @override
  void addListener(VoidCallback listener) => ledger.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => ledger.removeListener(listener);
}

/// [ConsentGate] as a modal dialog: says exactly which kinds of data would go
/// to whom, then [kConsentAllowLabel] or [kConsentDeclineLabel]. No context,
/// a dismissed dialog, or anything but [kConsentAllowLabel] is a decline.
class DialogConsentGate extends ConsentGate {
  DialogConsentGate({
    required this.navigatorKey,
    required this.cloudModel,
    this.remoteRouting,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final String cloudModel;

  /// The live Remote Config routing, read each time the prompt opens, so the
  /// copy follows the route the dispatcher will take.
  final RemoteRouting? Function()? remoteRouting;

  /// The prompt; [preview] is the exact photo that would be sent.
  @override
  @protected
  Future<bool> confirm(ConsentAsk ask, {Uint8List? preview}) async {
    final image = preview;
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    final copy = consentCopy(ask, remote: remoteRouting?.call());
    final allowed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        key: const ValueKey('consent-dialog'),
        icon: const Icon(Icons.cloud_upload_outlined),
        title: Text(copy.title),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(copy.body),
            if (image != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  image,
                  key: const ValueKey('consent-preview'),
                  height: 160,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('consent-decline'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(copy.decline),
          ),
          FilledButton(
            key: const ValueKey('consent-allow'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(copy.allow),
          ),
        ],
      ),
    );
    return allowed == true;
  }
}

/// Shows [frame] (the exact photo) in the [DialogConsentGate] prompt. The
/// grant comes from [gate] itself, so it is [gate]'s.
class FramePreviewConsentGate extends ConsentGate {
  FramePreviewConsentGate(this.gate, this.frame);
  final DialogConsentGate gate;
  final Uint8List? Function() frame;

  /// Never used: [request] asks [gate].
  @override
  @protected
  Future<bool> confirm(ConsentAsk ask, {Uint8List? preview}) async => false;

  @override
  Future<ConsentGrant?> request(ConsentAsk ask, {Uint8List? preview}) =>
      gate.request(ask, preview: preview ?? frame());

  /// The prompt is [gate]'s, so its grants are [gate]'s.
  @override
  bool issued(ConsentGrant grant) => gate.issued(grant);
}

/// The dispatcher's Dart cloud adapter (§5 step 4): a cloud-only request
/// through the existing `firebase_ai` client, used only when the bridge cannot
/// carry it. Recorded by the dispatcher as [Provenance.cloudAdapter].
class FirebaseAiCloudSender implements CloudFallbackSender {
  FirebaseAiCloudSender({required this.model, CloudGenerate? generate})
    : _generate = generate ?? _generateWithFirebase;

  final String model;
  final CloudGenerate _generate;
  final Set<String> _cancelled = {};

  @override
  Future<HybridResult> send(HybridRequest request) async {
    final task = request.task;
    final content = Content.multi([
      for (final part in task.parts)
        switch (part) {
          HybridText(:final text) => TextPart(text),
          HybridInlineData(:final bytes, :final mimeType) => InlineDataPart(
            mimeType,
            bytes,
          ),
        },
    ]);
    final config = GenerationConfig(
      maxOutputTokens: task.maxOutputTokens,
      responseMimeType: task.jsonSchema == null ? null : 'application/json',
      responseJsonSchema: task.jsonSchema,
    );
    final CloudReply? reply;
    try {
      reply = await _generate(
        model: model,
        systemInstruction: task.systemInstruction,
        content: content,
        config: config,
      ).timeout(task.timeout);
    } on TimeoutException {
      throw const HybridException(HybridErrorCode.timeout, 'cloud timeout');
    } on QuotaExceeded {
      throw const HybridException(HybridErrorCode.quota, 'cloud quota');
    } on FirebaseAIException catch (e) {
      throw HybridException(HybridErrorCode.failed, e.message);
    }
    if (_cancelled.remove(request.requestId)) {
      throw const HybridException(HybridErrorCode.cancelled, 'cancelled');
    }
    final text = reply?.text;
    if (text == null || text.isEmpty) {
      throw const HybridException(HybridErrorCode.failed, 'empty cloud reply');
    }
    return HybridResult(
      requestId: request.requestId,
      text: text,
      source: InferenceSource.cloud,
      modelLabel: cloudModelLabel(reply?.modelVersion, requested: model),
    );
  }

  @override
  Future<void> cancel(String requestId) async => _cancelled.add(requestId);
}

/// The ledger's model label for a cloud answer: the model version the SDK
/// reported, else the configured alias marked as requested, never the alias
/// presented as an observation.
String cloudModelLabel(String? reported, {required String requested}) =>
    (reported != null && reported.trim().isNotEmpty)
    ? reported.trim()
    : 'requested: $requested';

/// A cloud answer and, when the SDK reports one, the model version that
/// produced it.
class CloudReply {
  const CloudReply(this.text, {this.modelVersion});
  final String? text;
  final String? modelVersion;
}

typedef CloudGenerate = Future<CloudReply?> Function({
  required String model,
  required String? systemInstruction,
  required Content content,
  required GenerationConfig config,
});

/// Call only after Firebase and App Check have been initialized by the app.
/// `firebase_ai` 5.1's `GenerateContentResponse` exposes no model version,
/// so none is reported and the label says `requested: <alias>`.
Future<CloudReply?> _generateWithFirebase({
  required String model,
  required String? systemInstruction,
  required Content content,
  required GenerationConfig config,
}) async {
  final generative = FirebaseAI.googleAI().generativeModel(
    model: model,
    systemInstruction: systemInstruction == null
        ? null
        : Content.system(systemInstruction),
    generationConfig: config,
  );
  return CloudReply((await generative.generateContent([content])).text);
}

/// The shared hybrid services for one app run.
class HybridRuntime {
  HybridRuntime({
    required this.inference,
    required this.privacy,
    required this.cloudRoutes,
    required this.ledger,
    required this.dispatcher,
    required this.consent,
    required this.navigatorKey,
    required this.isOnline,
    this.cloudModel = kHybridCloudModel,
    this.reachable,
  }) : ledgerSource = InferenceLedgerSource(ledger);

  /// Production wiring. [inference] defaults to the platform backend,
  /// configured once with [cloudModel].
  ///
  /// [remote] (SS-076) supplies the cloud model chosen at startup, the
  /// per-feature routing overrides (read at every decision) and the
  /// `hybrid_enabled` kill switch, applied on top of [cloudRoutes]. It can
  /// only tighten them.
  factory HybridRuntime.create({
    HybridInference? inference,
    CloudRoutes? cloudRoutes,
    PrivacyPreferences? privacy,
    CloudFallbackSender? cloudFallback,
    bool Function()? isOnline,
    String cloudModel = kHybridCloudModel,
    GlobalKey<NavigatorState>? navigatorKey,
    RemotePolicy? remote,
    Future<bool> Function()? reachable,
  }) {
    if (remote != null) cloudModel = remote.cloudModel;
    final key = navigatorKey ?? GlobalKey<NavigatorState>();
    final prefs = privacy ?? InMemoryPrivacyPreferences();
    final compiledRoutes = cloudRoutes ?? CloudRoutes.fromEnvironment();
    final routes = remote?.gate(compiledRoutes) ?? compiledRoutes;
    final online = isOnline ?? deviceOnline;
    // On Android and iOS `deviceOnline` has no signal; production asks the
    // OS (best effort). A caller that injects [isOnline] owns connectivity.
    final probe = reachable ?? (isOnline == null ? networkReachable : null);
    late final DefaultHybridDispatcher dispatcher;
    final configured = ConfiguredHybridInference(
      inference ?? defaultHybridInference(),
      HybridConfig(cloudModel: cloudModel, androidModel: kAndroidModel),
      // The same checks the dispatcher made, read again after the wait.
      mayForward: (request) =>
          routes.allows(CloudRoute.hybridFallback) &&
          !localOnlyFor(prefs, request.task.feature) &&
          online(),
      // The dispatcher's own run checks (cancelled, session, privacy,
      // connectivity), read again immediately before the send.
      stillWanted: (request) => dispatcher.stillAllowed(request.requestId),
    );
    final ledger = InferenceLedger(sessionId: _newRunId());
    final consent = DialogConsentGate(
      navigatorKey: key,
      cloudModel: cloudModel,
      remoteRouting: remote?.routing,
    );
    late final HybridRuntime runtime;
    return runtime = HybridRuntime(
      inference: configured,
      privacy: prefs,
      cloudRoutes: routes,
      ledger: ledger,
      consent: consent,
      navigatorKey: key,
      isOnline: online,
      cloudModel: cloudModel,
      reachable: probe,
      dispatcher: dispatcher = DefaultHybridDispatcher(
        inference: configured,
        privacy: prefs,
        cloudRoutes: routes,
        consent: consent,
        ledger: ledger,
        cloudFallback:
            cloudFallback ?? FirebaseAiCloudSender(model: cloudModel),
        isOnline: online,
        reachable: probe,
        remoteRouting: remote?.routing,
        // A pending prompt or retry for meal A never sends once meal B (or
        // a new pantry flow) is the session.
        currentSession: () => runtime.sessionId,
      ),
    );
  }

  final HybridInference inference;
  final PrivacyPreferences privacy;
  final CloudRoutes cloudRoutes;
  final InferenceLedger ledger;
  final InferenceLedgerSource ledgerSource;
  final HybridDispatcher dispatcher;
  final DialogConsentGate consent;
  final GlobalKey<NavigatorState> navigatorKey;
  final bool Function() isOnline;
  final String cloudModel;

  /// The native connectivity probe (Android/iOS, best effort), or null when
  /// [isOnline] alone decides (web, or a caller that injected it).
  final Future<bool> Function()? reachable;

  /// The household's allergens for label check. On this device only.
  final HouseholdAllergens household = InMemoryHouseholdAllergens();

  /// A fresh label-check controller (the sheet disposes it on close).
  LabelCheckController labelCheck(String sessionId) => LabelCheckController(
    dispatcher: dispatcher,
    privacy: privacy,
    household: household,
    capabilities: inference.capabilities,
    sessionId: sessionId,
    consentGate: consent,
    cloudRoutes: cloudRoutes,
    isOnline: isOnline,
  );

  String? _cookingSessionId;

  /// The id features pass to the dispatcher for consent and the ledger.
  /// Before a cooking session exists (the pantry), it is this app run's id.
  String get sessionId => _cookingSessionId ?? ledger.sessionId;

  /// Binds the ledger to a cooking session. A session chosen from a pantry
  /// flow keeps (carries) that flow's legs; switching straight from one
  /// cooking session to a different one (New cook) starts an empty ledger.
  void bindCookingSession(String id) {
    final previous = _cookingSessionId;
    _cookingSessionId = id;
    if (previous != null && previous != id) ledger.startSession(id);
  }

  /// A new pantry flow (back from cooking to the pantry) starts a fresh
  /// ledger under a new run id, so a scan made before choosing the next meal
  /// is not recorded under the previous meal. The meal chosen next carries
  /// these legs ([bindCookingSession]). Work still running for the previous
  /// meal ends with that meal's ledger and does not send.
  void beginPantry() {
    // Every return to the pantry ends the cooking screen's right to bind,
    // even one whose session is still loading.
    _pantryEpoch++;
    if (_cookingSessionId == null) return; // already in a pantry flow
    _cookingSessionId = null;
    ledger.startSession(_newRunId());
  }

  int _pantryEpoch = 0;

  /// A [bindCookingSession] for one cooking screen, valid until the cook
  /// goes back to the pantry ([beginPantry]). A session load that finishes
  /// after that (the route was popped during initialization) is ignored, so
  /// it cannot undo the pantry reset.
  void Function(String sessionId) cookingSessionBinder() {
    final epoch = _pantryEpoch;
    return (id) {
      if (epoch == _pantryEpoch) bindCookingSession(id);
    };
  }

  /// Ledger hook for cloud senders outside the dispatcher (grounded
  /// research, the Live coach). They record at their own send boundary.
  late final CloudSendRecorder cloudSends = LedgerCloudSendRecorder(ledger);

  static String _newRunId() =>
      'run-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}
