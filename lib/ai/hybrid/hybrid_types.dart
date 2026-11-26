// App-side hybrid types. DESIGN.md §5; card SS-061 implements the dispatcher,
// policy, consent gate and ledger behind these. Feature tracks code against
// [HybridDispatcher] and test with [FakeHybridDispatcher].

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart' show protected;

/// A [HybridException] for a request that was refused before anything was
/// sent (for example, a check after the startup wait). The dispatcher records
/// its leg as not sent rather than "may have been sent".
class NotSentException extends HybridException {
  const NotSentException(super.code, super.message);
}

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
final class ConsentAsk {
  const ConsentAsk({
    required this.feature,
    required this.kinds,
    required this.payloadDigest,
    required this.sessionId,
    this.mode,
  });
  final String feature;
  final Set<DataKind> kinds;
  final String payloadDigest;
  final String sessionId;

  /// The route a yes takes, when the asker knows it (the dispatcher does):
  /// `onlyInCloud` sends at once; a `prefer…` mode may still finish on the
  /// device. Null: the feature's default route decides the wording.
  final HybridMode? mode;
}

/// The cook's "allow once" for one [ConsentAsk]. The only way to obtain one
/// is [ConsentGate.request], which asks the cook through
/// [ConsentGate.confirm]; feature code cannot make, extend or implement its
/// own, and there is no other minting call. Each grant remembers the gate
/// that issued it, and the dispatcher accepts only grants its own gate
/// issued ([ConsentGate.issued]).
final class ConsentGrant {
  const ConsentGrant._(this.ask, this._issuer);
  final ConsentAsk ask;
  final ConsentGate _issuer;
}

abstract class ConsentGate {
  const ConsentGate();

  /// Shows the cook [ask] (with [preview], the exact photo, when given) and
  /// completes true only for "Allow once". It returns no grant, so calling
  /// it directly authorizes nothing.
  @protected
  Future<bool> confirm(ConsentAsk ask, {Uint8List? preview});

  /// Asks the cook; a grant for exactly [ask], issued by this gate, when
  /// they allow it, else null. Any error is a decline.
  Future<ConsentGrant?> request(ConsentAsk ask, {Uint8List? preview}) async {
    // The gate owns what the cook sees and what the grant covers: one frozen
    // snapshot, taken before the prompt, so the caller cannot widen it later.
    // Copied field by field here (ConsentAsk is final; nothing overridable
    // is called), with an unmodifiable copy of [ConsentAsk.kinds].
    final shown = ConsentAsk(
      feature: ask.feature,
      kinds: Set.unmodifiable(ask.kinds),
      payloadDigest: ask.payloadDigest,
      sessionId: ask.sessionId,
      mode: ask.mode,
    );
    try {
      return await confirm(shown, preview: preview)
          ? ConsentGrant._(shown, this)
          : null;
    } catch (_) {
      return null;
    }
  }

  /// True when [grant] came from this gate's prompt. A gate that shows its
  /// prompt through another gate overrides this to ask that gate.
  bool issued(ConsentGrant grant) => identical(grant._issuer, this);
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
      script.add(
        (task) => DispatchResult(
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
        ),
      );

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
