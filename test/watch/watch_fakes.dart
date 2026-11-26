import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/live/live_types.dart';

const stepA = RecipeStep(
  id: 'a',
  title: 'Brown the onions',
  instruction: 'Cook the onions, stirring often.',
  cue: 'Onions are soft and golden at the edges.',
);
const stepB = RecipeStep(
  id: 'b',
  title: 'Simmer the sauce',
  instruction: 'Simmer until thick.',
  cue: 'Sauce coats the back of a spoon.',
);

/// A [LiveMedia] whose camera-only path can be held open, and whose
/// audio/video path can be denied, like a browser with the mic blocked.
class FakeMedia implements LiveMedia {
  final timed = StreamController<CapturedFrame>.broadcast();
  final liveFrames = StreamController<Uint8List>.broadcast();
  final failures = StreamController<String>.broadcast();
  final log = <String>[];
  bool micDenied = false;
  bool cameraDenied = false;
  Completer<void>? cameraGate;

  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<Uint8List> get frames => liveFrames.stream;
  @override
  Stream<CapturedFrame> get timedFrames => timed.stream;
  @override
  Stream<String> get errors => failures.stream;

  @override
  Future<void> start() async {
    log.add('start');
    if (micDenied) throw StateError('NotAllowedError: microphone denied');
  }

  @override
  Future<void> startCameraOnly() async {
    log.add('startCameraOnly');
    await cameraGate?.future;
    if (cameraDenied) throw StateError('NotAllowedError: camera denied');
  }

  @override
  Future<void> stop() async => log.add('stop');
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void playAudio(Uint8List pcm24khz) {}
  @override
  void interruptPlayback() {}

  void emit(DateTime capturedAt, [List<int> bytes = const [1, 2, 3]]) =>
      timed.add(
        CapturedFrame(bytes: Uint8List.fromList(bytes), capturedAt: capturedAt),
      );
}

/// A dispatcher whose results the test completes by hand, and which ignores
/// cancel the way a platform that can only abandon (not interrupt) would.
class ManualDispatcher implements HybridDispatcher {
  final tasks = <HybridTask>[];
  final sessions = <String>[];
  final pending = <Completer<DispatchResult>>[];
  final cancelled = <int>[];

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    final index = tasks.length;
    tasks.add(task);
    sessions.add(sessionId);
    final completer = Completer<DispatchResult>();
    pending.add(completer);
    return HybridOperation('manual-$index', completer.future, () {
      cancelled.add(index);
    });
  }

  void answer(
    int index,
    String text, {
    Provenance provenance = Provenance.sdkOnDevice,
  }) => pending[index].complete(
    DispatchResult(
      text: text,
      legs: [
        InferenceLeg(
          requestId: 'manual-$index',
          feature: tasks[index].feature,
          mode: HybridMode.onlyOnDevice,
          kinds: const {DataKind.text, DataKind.image},
          transferPermitted: provenance != Provenance.sdkOnDevice,
          provenance: provenance,
        ),
      ],
    ),
  );
}

class FakeConsentGate extends ConsentGate {
  final asks = <ConsentAsk>[];
  Completer<ConsentGrant?>? reply;

  @override
  Future<bool> confirm(ConsentAsk ask, {Uint8List? preview}) async => true;

  @override
  Future<ConsentGrant?> request(ConsentAsk ask, {Uint8List? preview}) {
    asks.add(ask);
    reply = Completer<ConsentGrant?>();
    return reply!.future;
  }

  void grant() => reply!.complete(super.request(asks.last));
  void grantFor(ConsentAsk ask) => reply!.complete(super.request(ask));
  void decline() => reply!.complete(null);
}

class FakePrivacy implements PrivacySettings {
  /// Every feature local-only.
  bool local = false;

  /// Only these feature keys local-only.
  final localFeatures = <String>{};
  @override
  bool localOnly(String feature) => local || localFeatures.contains(feature);
}

String verdictJson(
  String state, {
  String direction = 'none',
  String see = 'Onions in a pan.',
}) => '{"state":"$state","direction":"$direction","whatISee":"$see"}';
