// What every Firebase AI Logic Live send checks and records (DESIGN.md §5 and
// §6 SS-074). Live sends outside the hybrid dispatcher, so it does its own
// route check and writes its own ledger legs: one per connect AND one per
// resume, each written immediately before that socket opens.

import '../ai/hybrid/hybrid_types.dart';
import '../data/live_session.dart';

/// The ledger feature for Live legs (`lib/trust/trust_labels.dart`).
const kLiveFeature = 'live';

/// What a Live socket carries: the cook's voice, camera frames and the
/// recipe/system text.
const kLiveLegKinds = {DataKind.audio, DataKind.image, DataKind.text};

/// Same shape as `HybridRuntime.recordCloudLeg`.
typedef LiveLegRecorder = void Function(String feature, Set<DataKind> kinds);

/// Thrown by `connect` when Live may not start. [message] is one cook-facing
/// sentence that offers Coach Lite; the transport opened no socket.
class LiveUnavailable implements Exception {
  const LiveUnavailable(this.message, {this.retryAfter});
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

class LiveCloudGuard {
  LiveCloudGuard({
    required this.cloudRoutes,
    required this.reserve,
    this.privacy,
    this.recordLeg,
  });

  final CloudRoutes cloudRoutes;
  final LiveSessionReserver reserve;

  /// Read at every check; a local-only `live` setting blocks Live.
  final PrivacySettings? privacy;
  final LiveLegRecorder? recordLeg;

  static const blockedMessage =
      'The Live coach is off for this build or your privacy settings. '
      'Type a question for Coach Lite instead.';

  /// Read now, never cached: the approved route and the cook's setting.
  bool get allowed =>
      cloudRoutes.allows(CloudRoute.live) &&
      !(privacy?.localOnly(kLiveFeature) ?? false);

  /// Before a new session: route check, then the server reservation. Throws
  /// [LiveUnavailable] when either says no. Does not write a leg; call
  /// [admit] immediately before the socket opens.
  Future<void> reserveSession() async {
    if (!allowed) throw const LiveUnavailable(blockedMessage);
    final LiveSessionReservation reservation;
    try {
      reservation = await reserve();
    } catch (_) {
      throw const LiveUnavailable(
        'Live coaching is unavailable right now. Try again shortly, or type a '
        'question for Coach Lite.',
      );
    }
    switch (reservation) {
      case LiveSessionGranted():
        return;
      case LiveSessionDenied(:final message, :final retryAfter):
        throw LiveUnavailable(message, retryAfter: retryAfter);
    }
  }

  /// Immediately before a socket opens (connect or resume): re-checks the
  /// route and the cook's setting, then writes the leg. False means do not
  /// open it; nothing was recorded.
  bool admit() {
    if (!allowed) return false;
    recordLeg?.call(kLiveFeature, kLiveLegKinds);
    return true;
  }
}
