// Ledger legs for cloud senders outside the dispatcher are written at the
// send boundary (PR #193 review): a local rejection is unsent, a failed
// transmission stays "may have been sent", and only a cloud answer is
// confirmed. Live records every connect attempt and every resume.
// Fakes only.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/app/cloud_send_recorder.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/live/live_backend_guard.dart';
import 'package:soussight/live/live_controller.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/main_hybrid_gate.dart';

const _query = CookingResearchQuery(
  question: 'Can I swap lemon for vinegar?',
  currentStep: 'Mix',
  confirmedIngredients: ['chickpeas'],
);

GenerateContentResponse _ungrounded() => GenerateContentResponse([
  Candidate(Content.text('An answer.'), null, null, FinishReason.stop, null),
], null);

class _Transport implements LiveTransport {
  _Transport({this.fail = false});
  final bool fail;
  final source = StreamController<LiveEvent>.broadcast();
  @override
  Stream<LiveEvent> get events => source.stream;
  @override
  Future<void> connect({required String systemInstruction}) async {
    if (fail) throw StateError('handshake refused');
  }

  @override
  Future<void> sendAudio(Uint8List pcm16khz) async {}
  @override
  Future<void> sendVideo(Uint8List jpeg) async {}
  @override
  Future<void> sendText(String text) async {}
  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async {}
  @override
  Future<void> close() async {}
}

class _Media implements LiveMedia {
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Stream<CapturedFrame> get timedFrames => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> startCameraOnly() async {}
  @override
  Future<void> stop() async {}
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void playAudio(Uint8List pcm24khz) {}
  @override
  void interruptPlayback() {}
}

void main() {
  late InferenceLedger ledger;
  late LedgerCloudSendRecorder recorder;

  setUp(() {
    ledger = InferenceLedger(sessionId: 's');
    recorder = LedgerCloudSendRecorder(ledger);
  });

  group('grounded research', () {
    test('a question rejected locally is recorded as unsent', () async {
      var calls = 0;
      final client = GeminiCookingResearchClient(
        recorder: recorder,
        generate: (_) async {
          calls++;
          return _ungrounded();
        },
      );
      await expectLater(
        client.research(
          CookingResearchQuery(
            question: 'x' * 1501,
            currentStep: 'Mix',
            confirmedIngredients: const [],
          ),
        ),
        throwsA(isA<CookingResearchException>()),
      );
      expect(calls, 0);
      final entry = ledger.entries.single;
      expect(entry.allowedToLeave, isFalse);
      expect(entry.reportedSent, isFalse);
      expect(entry.leg.error, HybridErrorCode.unsupportedInput);
    });

    test(
      'a timed-out send stays "may have been sent", never confirmed',
      () async {
        final client = GeminiCookingResearchClient(
          recorder: recorder,
          timeout: const Duration(milliseconds: 10),
          generate: (_) => Completer<GenerateContentResponse>().future,
        );
        await expectLater(
          client.research(_query),
          throwsA(isA<CookingResearchException>()),
        );
        final entry = ledger.entries.single;
        expect(entry.pending, isFalse);
        expect(entry.uploadUnknown, isTrue);
        expect(entry.reportedSent, isFalse);
        expect(entry.leg.error, HybridErrorCode.timeout);
      },
    );

    test('a transmission error stays unknown', () async {
      final client = GeminiCookingResearchClient(
        recorder: recorder,
        generate: (_) async => throw StateError('socket closed'),
      );
      await expectLater(client.research(_query), throwsA(anything));
      expect(ledger.entries.single.uploadUnknown, isTrue);
      expect(ledger.entries.single.leg.error, HybridErrorCode.network);
    });

    test('only a cloud answer is confirmed', () async {
      final client = GeminiCookingResearchClient(
        recorder: recorder,
        generate: (_) async => _ungrounded(),
      );
      // Ungrounded, so the app rejects the answer, but the cloud did answer.
      await expectLater(client.research(_query), throwsA(anything));
      final entry = ledger.entries.single;
      expect(entry.reportedSent, isTrue);
      expect(entry.leg.provenance, Provenance.cloudAdapter);
      expect(entry.leg.modelLabel, kCookingResearchModel);
    });

    test('the leg is pending while the send is in flight', () async {
      final reply = Completer<GenerateContentResponse>();
      final client = GeminiCookingResearchClient(
        recorder: recorder,
        generate: (_) => reply.future,
      );
      final pending = client.research(_query);
      await Future<void>.delayed(Duration.zero);
      expect(ledger.entries.single.pending, isTrue);
      expect(ledger.entries.single.reportedSent, isFalse);
      reply.complete(_ungrounded());
      await expectLater(pending, throwsA(anything));
      expect(ledger.entries.single.reportedSent, isTrue);
    });
  });

  group('Live', () {
    test('a failed connect is recorded and stays visible', () async {
      final live = LedgeredLiveTransport(
        _Transport(fail: true),
        LiveLegTracker(recorder),
      );
      await expectLater(
        live.connect(systemInstruction: 'x'),
        throwsA(isA<StateError>()),
      );
      final entry = ledger.entries.single;
      expect(entry.leg.feature, kLiveFeature);
      expect(entry.uploadUnknown, isTrue);
      expect(entry.leg.kinds, {DataKind.text, DataKind.image, DataKind.audio});
    });

    test('a connect and every resume are legs', () async {
      final inner = _Transport();
      final live = LedgeredLiveTransport(inner, LiveLegTracker(recorder));
      final seen = <LiveEvent>[];
      final errors = <Object>[];
      final sub = live.events.listen(seen.add, onError: errors.add);
      await live.connect(systemInstruction: 'x');
      expect(ledger.entries.single.reportedSent, isTrue);

      // Resume 1 succeeds.
      inner.source.add(
        const LiveConnectionNotice('Reconnecting…', reconnecting: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(ledger.entries, hasLength(2));
      expect(ledger.entries[1].pending, isTrue);
      inner.source.add(const LiveConnectionNotice('Live session resumed.'));
      await Future<void>.delayed(Duration.zero);
      expect(ledger.entries[1].reportedSent, isTrue);

      // Resume 2 fails: visible as unknown, the error still reaches Live.
      inner.source.add(
        const LiveConnectionNotice('Reconnecting…', reconnecting: true),
      );
      await Future<void>.delayed(Duration.zero);
      inner.source.addError(StateError('Could not resume live session.'));
      await Future<void>.delayed(Duration.zero);
      expect(ledger.entries, hasLength(3));
      expect(ledger.entries[2].uploadUnknown, isTrue);
      expect(errors, hasLength(1));
      expect(seen, hasLength(3));
      await sub.cancel();
    });

    test('the coordinator path records a failed Live connect', () async {
      final hybridLedger = InferenceLedger(sessionId: 's');
      final cook = CookingCoordinator(
        services: AppServices(
          auth: FakeAuthService(),
          recipes: FakeRecipeRepository(_recipe),
          sessions: FakeSessionRepository(),
          bundledRecipe: _recipe,
        ),
        research: const FakeCookingResearchClient(),
        transportFactory: () => LedgeredLiveTransport(
          _Transport(fail: true),
          LiveLegTracker(LedgerCloudSendRecorder(hybridLedger)),
        ),
        media: _Media(),
      );
      await cook.initialize();
      await cook.connect();
      expect(cook.live.isActive, isFalse);
      expect(hybridLedger.entries.single.uploadUnknown, isTrue);
      cook.dispose();
    });

    test('rehearsal Live is not wrapped', () {
      final demo = ledgeredLiveFactory(isDemo: true)!;
      expect(demo(), isNot(isA<LedgeredLiveTransport>()));
    });

    test('no Live in this build means no factory', () {
      expect(
        ledgeredLiveFactory(
          isDemo: false,
          hybrid: _runtime(),
          build: (_) => null,
        ),
        isNull,
      );
    });

    group('AI Logic transport (records through its guard)', () {
      late HybridRuntime runtime;
      late List<_SelfRecording> made;
      var refuse = false;

      LiveTransport make() => ledgeredLiveFactory(
        isDemo: false,
        hybrid: runtime,
        selfRecording: true,
        build: (record) => () {
          final t = _SelfRecording(record!, refuse: refuse);
          made.add(t);
          return t;
        },
      )!();

      setUp(() {
        runtime = _runtime();
        made = [];
        refuse = false;
      });

      test('a connect and a resume are each exactly one leg', () async {
        final live = make();
        final sub = live.events.listen((_) {}, onError: (_) {});
        await live.connect(systemInstruction: 'x');
        expect(runtime.ledger.entries, hasLength(1));
        expect(runtime.ledger.entries.single.reportedSent, isTrue);
        await made.single.resume();
        expect(runtime.ledger.entries, hasLength(2));
        expect(runtime.ledger.entries.every((e) => e.reportedSent), isTrue);
        await sub.cancel();
      });

      test(
        'a connect refused before its socket opens writes nothing',
        () async {
          refuse = true;
          final live = make();
          await expectLater(
            live.connect(systemInstruction: 'x'),
            throwsA(isA<LiveUnavailable>()),
          );
          expect(runtime.ledger.entries, isEmpty);
        },
      );

      test('the cook sees why Live was refused', () async {
        refuse = true;
        final controller = LiveCookingController(
          transportFactory: make,
          media: _Media(),
          onToolCall: (_) async => const {},
        );
        await controller.start(cookingContext: 'Mash');
        expect(controller.isActive, isFalse);
        expect(controller.error, 'Live is off.');
        expect(runtime.ledger.entries, isEmpty);
        controller.dispose();
      });

      test('a socket that fails after admission stays unknown', () async {
        final live = make();
        made.single.failAfterAdmit = true;
        await expectLater(
          live.connect(systemInstruction: 'x'),
          throwsA(isA<StateError>()),
        );
        expect(runtime.ledger.entries.single.uploadUnknown, isTrue);
      });
    });
  });

  group('gate harness', () {
    test('probes that may reach the cloud need hybridFallback', () {
      const none = CloudRoutes({});
      final approved = CloudRoutes.parse('hybridFallback');
      expect(gateProbeAllowed(HybridMode.onlyOnDevice, none), isTrue);
      expect(gateProbeAllowed(HybridMode.preferOnDevice, none), isFalse);
      expect(gateProbeAllowed(HybridMode.onlyInCloud, none), isFalse);
      expect(gateProbeAllowed(HybridMode.preferOnDevice, approved), isTrue);
      expect(gateProbeAllowed(HybridMode.onlyInCloud, approved), isTrue);
      expect(
        gateProbeLabel('Text', cloudApproved: false),
        contains('disabled'),
      );
    });
  });
}

const _recipe = Recipe(
  id: 'wrap',
  version: 1,
  title: 'Wrap',
  summary: 'A wrap.',
  ingredients: [Ingredient(id: 'c', name: 'Chickpeas', qty: '1 can')],
  equipment: [],
  steps: [
    RecipeStep(id: 'mix', title: 'Mix', instruction: 'Stir.', cue: 'Mixed.'),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

HybridRuntime _runtime() => HybridRuntime.create(
  inference: FakeHybridInference(),
  cloudRoutes: CloudRoutes.parse('live'),
  isOnline: () => true,
  cloudModel: 'm',
);

/// Stands in for the AI Logic transport: its guard records a leg right before
/// each socket opens, and refuses before that when Live is not allowed.
class _SelfRecording implements LiveTransport {
  _SelfRecording(this.record, {required this.refuse});
  final LiveLegRecorder record;
  final bool refuse;
  bool failAfterAdmit = false;
  final source = StreamController<LiveEvent>.broadcast();

  @override
  Stream<LiveEvent> get events => source.stream;

  @override
  Future<void> connect({required String systemInstruction}) async {
    if (refuse) throw const LiveUnavailable('Live is off.');
    record(kLiveFeature, kLiveLegKinds);
    if (failAfterAdmit) throw StateError('socket closed');
  }

  Future<void> resume() async {
    record(kLiveFeature, kLiveLegKinds);
    source.add(const LiveConnectionNotice('…', reconnecting: true));
    await Future<void>.delayed(Duration.zero);
    source.add(const LiveConnectionNotice('Live session resumed.'));
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> sendAudio(Uint8List pcm16khz) async {}
  @override
  Future<void> sendVideo(Uint8List jpeg) async {}
  @override
  Future<void> sendText(String text) async {}
  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async {}
  @override
  Future<void> close() async {}
}
