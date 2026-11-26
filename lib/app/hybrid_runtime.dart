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

/// Who the cook is told a cloud request goes to.
const kCloudRecipient = "Google's Gemini model, through Firebase AI Logic";

/// Delegates to [inner], but every call that needs the configuration waits
/// for the one [HybridInference.configure] call made at startup. A failed
/// configure is not retried here; `generate` then fails as the bridge says.
///
/// Routing waits for configuration too ([capabilities] awaits it), so a
/// decision is made against the policy as it is once the backend is ready.
/// [mayForward], when given, is checked again after the wait, immediately
/// before a request that may upload is forwarded: a late change (the
/// Remote Config kill switch, local-only) refuses it with
/// [HybridErrorCode.blocked] instead of sending.
class ConfiguredHybridInference implements HybridInference {
  ConfiguredHybridInference(this.inner, HybridConfig config, {this.mayForward})
    : _configured = inner
          .configure(config)
          .then<void>(
            (_) {},
            onError: (Object error) =>
                debugPrint('Hybrid configure failed (${error.runtimeType})'),
          );

  final HybridInference inner;
  final Future<void> _configured;
  final bool Function(HybridRequest request)? mayForward;

  /// Completes when the startup configure has settled (either way).
  Future<void> get configured => _configured;

  @override
  Future<void> configure(HybridConfig config) => inner.configure(config);

  @override
  Future<HybridCapabilities> capabilities() async {
    await _configured;
    return inner.capabilities();
  }

  @override
  Future<HybridAvailability> availability({required bool withImage}) =>
      inner.availability(withImage: withImage);

  /// Not awaited: on web the download must start inside the cook's tap.
  @override
  Stream<double?> prepare({required bool withImage}) =>
      inner.prepare(withImage: withImage);

  @override
  Future<HybridResult> generate(HybridRequest request) async {
    await _configured;
    final check = mayForward;
    if (request.mode != HybridMode.onlyOnDevice &&
        check != null &&
        !check(request)) {
      throw const HybridException(
        HybridErrorCode.blocked,
        'Cloud help was turned off before this request was sent.',
      );
    }
    return inner.generate(request);
  }

  @override
  Future<void> cancel(String requestId) => inner.cancel(requestId);
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
class DialogConsentGate implements ConsentGate {
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

  @override
  Future<ConsentGrant?> request(ConsentAsk ask) =>
      requestWithPreview(ask, null);

  /// The same prompt, showing the exact photo that would be sent.
  Future<ConsentGrant?> requestWithPreview(
    ConsentAsk ask,
    Uint8List? image,
  ) async {
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
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
    return allowed == true ? ConsentGrant(ask) : null;
  }
}

/// Shows [frame] (the exact photo) in the [DialogConsentGate] prompt.
class FramePreviewConsentGate implements ConsentGate {
  FramePreviewConsentGate(this.gate, this.frame);
  final DialogConsentGate gate;
  final Uint8List? Function() frame;

  @override
  Future<ConsentGrant?> request(ConsentAsk ask) =>
      gate.requestWithPreview(ask, frame());
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
    final String? text;
    try {
      text = await _generate(
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
    if (text == null || text.isEmpty) {
      throw const HybridException(HybridErrorCode.failed, 'empty cloud reply');
    }
    return HybridResult(
      requestId: request.requestId,
      text: text,
      source: InferenceSource.cloud,
      modelLabel: model,
    );
  }

  @override
  Future<void> cancel(String requestId) async => _cancelled.add(requestId);
}

typedef CloudGenerate = Future<String?> Function({
  required String model,
  required String? systemInstruction,
  required Content content,
  required GenerationConfig config,
});

/// Call only after Firebase and App Check have been initialized by the app.
Future<String?> _generateWithFirebase({
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
  return (await generative.generateContent([content])).text;
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
  }) {
    if (remote != null) cloudModel = remote.cloudModel;
    final key = navigatorKey ?? GlobalKey<NavigatorState>();
    final prefs = privacy ?? InMemoryPrivacyPreferences();
    final compiledRoutes = cloudRoutes ?? CloudRoutes.fromEnvironment();
    final routes = remote?.gate(compiledRoutes) ?? compiledRoutes;
    final configured = ConfiguredHybridInference(
      inference ?? defaultHybridInference(),
      HybridConfig(cloudModel: cloudModel),
      // The same checks the dispatcher made, read again after the wait.
      mayForward: (request) =>
          routes.allows(CloudRoute.hybridFallback) &&
          !localOnlyFor(prefs, request.task.feature),
    );
    final online = isOnline ?? deviceOnline;
    final ledger = InferenceLedger(sessionId: _newRunId());
    final consent = DialogConsentGate(
      navigatorKey: key,
      cloudModel: cloudModel,
      remoteRouting: remote?.routing,
    );
    return HybridRuntime(
      inference: configured,
      privacy: prefs,
      cloudRoutes: routes,
      ledger: ledger,
      consent: consent,
      navigatorKey: key,
      isOnline: online,
      cloudModel: cloudModel,
      dispatcher: DefaultHybridDispatcher(
        inference: configured,
        privacy: prefs,
        cloudRoutes: routes,
        consent: consent,
        ledger: ledger,
        cloudFallback:
            cloudFallback ?? FirebaseAiCloudSender(model: cloudModel),
        isOnline: online,
        remoteRouting: remote?.routing,
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

  /// Binds the ledger to a cooking session. The first cooking session keeps
  /// the pantry legs that led to it; a later, different session (New cook)
  /// starts an empty ledger.
  void bindCookingSession(String id) {
    final previous = _cookingSessionId;
    _cookingSessionId = id;
    if (previous != null && previous != id) ledger.startSession(id);
  }

  /// Ledger hook for cloud senders outside the dispatcher (grounded
  /// research, the Live coach). They record at their own send boundary.
  late final CloudSendRecorder cloudSends = LedgerCloudSendRecorder(ledger);

  static String _newRunId() =>
      'run-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}
