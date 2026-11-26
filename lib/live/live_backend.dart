// The one place that picks the Live coach transport (DESIGN.md §6 SS-074).
//
// `--dart-define=LIVE_BACKEND=aiLogic|ephemeral|none`. A missing or unknown
// value means `none`: Live controls are hidden and Coach Lite is offered.
//
// The choice is a compile-time constant, so a `none` or `aiLogic` build does
// not contain the legacy ephemeral transport at all (the compiler drops the
// branch). tool/check_web_bundle.sh (SS-079) checks the built bundle for it.

import '../ai/hybrid/hybrid_types.dart';
import '../data/live_token_provider.dart';
import '../learner/demo_live.dart';
import 'ephemeral_live_transport.dart';
import 'firebase_live_transport.dart';
import 'live_types.dart';

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
LiveTransportFactory? liveTransportFactory({
  required bool isDemo,
  CloudRoutes? cloudRoutes,
}) {
  if (isDemo) return DemoLiveTransport.new;
  if (kLiveEphemeral) {
    return () => EphemeralGeminiLiveTransport(tokenProvider: fetchLiveToken);
  }
  if (kLiveAiLogic &&
      (cloudRoutes ?? CloudRoutes.fromEnvironment()).allows(CloudRoute.live)) {
    return FirebaseLiveTransport.new;
  }
  return null;
}
