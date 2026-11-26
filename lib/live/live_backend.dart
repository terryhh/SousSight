// The one place that picks the Live coach transport (DESIGN.md §6 SS-074).
//
// `--dart-define=LIVE_BACKEND=aiLogic|ephemeral|none`. A missing or unknown
// value means `none`: Live controls are hidden and Coach Lite is offered.
//
// The choice is a compile-time constant, so a `none` or `aiLogic` build does
// not contain the legacy ephemeral transport at all (the compiler drops the
// branch). tool/check_web_bundle.sh (SS-079) checks the built bundle for it.

import '../ai/hybrid/hybrid_types.dart';
import '../data/live_session.dart';
import '../data/live_token_provider.dart';
import '../learner/demo_live.dart';
import 'ephemeral_live_transport.dart';
import 'firebase_live_transport.dart';
import 'live_backend_guard.dart';
import 'live_tools.dart';
import 'live_types.dart';

export 'live_backend_guard.dart' show LiveLegRecorder, LiveUnavailable;

enum LiveBackend {
  /// Gemini Live through Firebase AI Logic. Whether it works on web with App
  /// Check enforced is gate G3; until then a judged web build uses [none].
  aiLogic,

  /// The legacy direct Gemini Live socket with a minted ephemeral token.
  /// Never in the judged build; only when explicitly set.
  ephemeral,

  /// No Live coach.
  none,
}

const kLiveBackendDefine = String.fromEnvironment('LIVE_BACKEND');

/// Compile-time switches. Keep these `const` so unused transports are
/// tree-shaken out of the build.
const bool kLiveEphemeral = kLiveBackendDefine == 'ephemeral';
const bool kLiveAiLogic = kLiveBackendDefine == 'aiLogic';

LiveBackend parseLiveBackend(String value) => switch (value.trim()) {
  'aiLogic' => LiveBackend.aiLogic,
  'ephemeral' => LiveBackend.ephemeral,
  _ => LiveBackend.none,
};

/// The backend this build was compiled with.
const LiveBackend configuredLiveBackend = kLiveEphemeral
    ? LiveBackend.ephemeral
    : kLiveAiLogic
    ? LiveBackend.aiLogic
    : LiveBackend.none;

/// The Live transport for this build, or null when there is no Live coach.
///
/// Rehearsal always uses the simulated transport. `aiLogic` is a cloud route,
/// so it also needs `CLOUD_ROUTES` to contain `live`; otherwise no Live.
///
/// For `aiLogic`, [recordCloudLeg] receives one leg per connect and per
/// resume (pass `HybridRuntime.recordCloudLeg`), [privacy] is read before
/// each, and [reserveSession] defaults to the `liveSession` function.
LiveTransportFactory? liveTransportFactory({
  required bool isDemo,
  CloudRoutes? cloudRoutes,
  PrivacySettings? privacy,
  LiveLegRecorder? recordCloudLeg,
  LiveSessionReserver? reserveSession,
}) {
  if (isDemo) return DemoLiveTransport.new;
  // Each branch is behind a const, so dart2js keeps only the configured one.
  if (kLiveEphemeral) {
    return () => EphemeralGeminiLiveTransport(tokenProvider: fetchLiveToken);
  }
  if (kLiveAiLogic) {
    return aiLogicLiveTransportFactory(
      cloudRoutes: cloudRoutes ?? CloudRoutes.fromEnvironment(),
      privacy: privacy,
      recordCloudLeg: recordCloudLeg,
      reserveSession: reserveSession ?? reserveLiveSession,
    );
  }
  return null;
}

/// The `aiLogic` branch of [liveTransportFactory], callable from tests.
/// Null when the `live` cloud route is not approved: Live controls are hidden
/// and Coach Lite is offered. Each transport reserves its session with
/// [reserveSession] before connecting and is guarded again at connect time.
LiveTransportFactory? aiLogicLiveTransportFactory({
  required CloudRoutes cloudRoutes,
  required LiveSessionReserver reserveSession,
  PrivacySettings? privacy,
  LiveLegRecorder? recordCloudLeg,
  String model = kLiveModel,
  LiveSessionOpener? openSession,
}) {
  if (!cloudRoutes.allows(CloudRoute.live)) return null;
  return () => FirebaseLiveTransport(
    model: model,
    openSession: openSession,
    guard: LiveCloudGuard(
      cloudRoutes: cloudRoutes,
      privacy: privacy,
      reserve: reserveSession,
      recordLeg: recordCloudLeg,
    ),
  );
}
