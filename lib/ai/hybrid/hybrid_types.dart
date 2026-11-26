// App-side hybrid types. DESIGN.md §5; card SS-061 implements the dispatcher,
// policy, consent gate and ledger behind these. Feature tracks code against
// [HybridDispatcher] and test with [FakeHybridDispatcher].

import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

/// Cloud routes G1 approved for this build. Compiled in; default is none.
enum CloudRoute { hybridFallback, research, nearby, live }

class CloudRoutes {
  const CloudRoutes(this.approved);

  /// Reads `--dart-define=CLOUD_ROUTES=hybridFallback,research,...`.
  factory CloudRoutes.fromEnvironment() =>
      CloudRoutes.parse(const String.fromEnvironment('CLOUD_ROUTES'));

  factory CloudRoutes.parse(String value) => CloudRoutes({
    for (final name in value.split(','))
      for (final route in CloudRoute.values)
        if (route.name == name.trim()) route,
  });

  final Set<CloudRoute> approved;
  bool allows(CloudRoute route) => approved.contains(route);
}

/// The cook's privacy settings. Read live at every send; never cache.
abstract class PrivacySettings {
  bool localOnly(String feature);
}

enum DataKind { text, image, audio, location }

/// Consent is for one exact payload in one session, and is used once.
class ConsentAsk {
  const ConsentAsk({
    required this.feature,
    required this.kinds,
    required this.payloadDigest,
    required this.sessionId,
  });
  final String feature;
  final Set<DataKind> kinds;
  final String payloadDigest;
  final String sessionId;
}

class ConsentGrant {
  const ConsentGrant(this.ask);
  final ConsentAsk ask;
}

abstract class ConsentGate {
  /// Null when the cook declines.
  Future<ConsentGrant?> request(ConsentAsk ask);
}

enum Provenance { sdkOnDevice, sdkCloud, cloudAdapter, simulated, unknown }

/// One attempt to run a task. Every attempt is a leg, including blocked
/// fallbacks and failed sends.
class InferenceLeg {
  const InferenceLeg({
    required this.requestId,
    required this.feature,
    required this.mode,
    required this.kinds,
    required this.transferPermitted,
    required this.provenance,
    this.modelLabel,
    this.error,
  });
  final String requestId;
  final String feature;
  final HybridMode? mode;
  final Set<DataKind> kinds;
  final bool transferPermitted;
  final Provenance provenance;
  final String? modelLabel;
  final HybridErrorCode? error;
}

/// Why a task could not run, or why it went where it did. One cook-facing
/// sentence each lives in the trust UI (SS-070).
enum RouteReason {
  onDevice,
  localOnlySetting,
  cloudNotApproved,
  audioNeedsCloud,
  imageNeedsCloud,
  tooLargeForDevice,
  languageNotSupported,
  modelNotReady,
  modelDownloading,
  noLocalModel,
  offline,
  consentDeclined,
  cancelled,
  cloudRetryAfterCheck,
}

class DispatchResult {
  const DispatchResult({this.text, required this.legs, this.blocked});

  /// Null when blocked or failed.
  final String? text;

  /// Every attempt, in order.
  final List<InferenceLeg> legs;
  final RouteReason? blocked;

  bool get ok => text != null;
  InferenceLeg? get finalLeg => legs.isEmpty ? null : legs.last;
}

/// Returned synchronously, before the first await.
class HybridOperation {
  HybridOperation(this.operationId, this.result, this._cancel);
  final String operationId;
  final Future<DispatchResult> result;
  final void Function() _cancel;

  /// Stops the current send and any later fallback or retry.
  void cancel() => _cancel();
}

/// Returns null when the text passes, or a short reason when it does not.
typedef ResultValidator = String? Function(String text);

/// The only sender of hybrid requests (DESIGN.md §5).
abstract class HybridDispatcher {
  /// [grant] is consent the feature already obtained for this exact payload
  /// (e.g. one watch frame). It is used only if its `payloadDigest` equals
  /// `hybridPayloadDigest(task)` and its `sessionId` equals [sessionId], and
  /// at most once; otherwise the dispatcher asks its [ConsentGate].
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  });
}

/// For feature tests: returns scripted [DispatchResult]s and records tasks.
class FakeHybridDispatcher implements HybridDispatcher {
  final List<HybridTask> tasks = [];

  /// The grant passed with each task, in the same order as [tasks].
  final List<ConsentGrant?> grants = [];
  final List<String> cancelledOperations = [];
  final List<DispatchResult Function(HybridTask)> script = [];
  Duration delay = Duration.zero;
  int _seq = 0;

  void enqueue(String text, {Provenance provenance = Provenance.sdkOnDevice}) =>
      script.add((task) => DispatchResult(
        text: text,
        legs: [
          InferenceLeg(
            requestId: 'fake-$_seq',
            feature: task.feature,
            mode: HybridMode.preferOnDevice,
            kinds: {
              DataKind.text,
              if (task.hasImage) DataKind.image,
              if (task.hasAudio) DataKind.audio,
            },
            transferPermitted: provenance != Provenance.sdkOnDevice,
            provenance: provenance,
          ),
        ],
      ));

  void enqueueBlocked(RouteReason reason) =>
      script.add((_) => DispatchResult(legs: const [], blocked: reason));

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    tasks.add(task);
    grants.add(grant);
    final id = 'op-${++_seq}';
    var cancelled = false;
    // Build the scripted result now, while this operation's sequence number
    // is current, so concurrent operations get distinct leg request ids.
    final next = script.isEmpty ? null : script.removeAt(0);
    final scripted = next?.call(task);
    Future<DispatchResult> run() async {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (cancelled) {
        return const DispatchResult(legs: [], blocked: RouteReason.cancelled);
      }
      if (scripted == null) {
        throw StateError('FakeHybridDispatcher: no scripted result');
      }
      return scripted;
    }

    return HybridOperation(id, run(), () {
      cancelled = true;
      cancelledOperations.add(id);
    });
  }
}
