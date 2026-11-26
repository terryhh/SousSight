// Integration wiring (SS-083): the app-wide hybrid runtime, the Live backend
// switch, the consent dialog, the cloud adapter, the "Where the AI runs"
// section, and the coordinator's Coach Lite / watch / research branches.
// Every model here is a fake; nothing reaches a real service.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/how_it_works.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/live/live_backend.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/trust/privacy_preferences.dart';

const _recipe = Recipe(
  id: 'wrap',
  version: 1,
  title: 'Chickpea wrap',
  summary: 'A simple wrap.',
  ingredients: [Ingredient(id: 'chickpeas', name: 'Chickpeas', qty: '1 can')],
  equipment: ['bowl'],
  steps: [
    RecipeStep(
      id: 'mash',
      title: 'Mash',
      instruction: 'Mash with a fork.',
      cue: 'Small chunks remain.',
    ),
    RecipeStep(
      id: 'mix',
      title: 'Mix',
      instruction: 'Stir.',
      cue: 'Evenly coated.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

String _liteJson({Map<String, Object?>? timer}) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['tip'],
    },
    {
      'id': 'tip',
      'component': 'stepCue',
      'title': 'Keep some texture',
      'body': 'Stop when a few small chunks remain.',
    },
  ],
  'timerSuggestion': ?timer,
});

class _Media implements LiveMedia {
  final timed = StreamController<CapturedFrame>.broadcast();
  int cameraOnlyStarts = 0;
  int fullStarts = 0;
  int stops = 0;
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Stream<CapturedFrame> get timedFrames => timed.stream;
  @override
  Future<void> start() async => fullStarts++;
  @override
  Future<void> startCameraOnly() async => cameraOnlyStarts++;
  @override
  Future<void> stop() async => stops++;
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void playAudio(Uint8List pcm24khz) {}
  @override
  void interruptPlayback() {}
}

class _Research implements CookingResearchClient {
  final queries = <CookingResearchQuery>[];
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async {
    queries.add(query);
    return const CookingResearchResult(answer: 'An answer.', citations: []);
  }
}

class _NoCloud implements CloudFallbackSender {
  int sends = 0;
  @override
  Future<HybridResult> send(HybridRequest request) async {
    sends++;
    throw const HybridException(HybridErrorCode.failed, 'not in tests');
  }

  @override
  Future<void> cancel(String requestId) async {}
}

HybridRuntime _runtime(
  FakeHybridInference inference, {
  String routes = '',
  _NoCloud? cloud,
}) => HybridRuntime.create(
  inference: inference,
  cloudRoutes: CloudRoutes.parse(routes),
  cloudFallback: cloud ?? _NoCloud(),
  isOnline: () => true,
  cloudModel: 'test-cloud-model',
);

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('LIVE_BACKEND', () {
    test('missing or unknown values mean none', () {
      expect(parseLiveBackend(''), LiveBackend.none);
      expect(parseLiveBackend('vertex'), LiveBackend.none);
      expect(parseLiveBackend('aiLogic'), LiveBackend.aiLogic);
      expect(parseLiveBackend('ephemeral'), LiveBackend.ephemeral);
    });

    test(
      'tests are compiled with no Live backend; rehearsal still has Live',
      () {
        expect(configuredLiveBackend, LiveBackend.none);
        expect(liveTransportFactory(isDemo: false), isNull);
        expect(liveTransportFactory(isDemo: true), isNotNull);
      },
    );
  });

  group('Where the AI runs', () {
    String where(List<RoutingRow> rows, String prefix) =>
        rows.firstWhere((r) => r.feature.startsWith(prefix)).where;

    test('with no cloud route approved, everything stays on this device', () {
      final rows = hybridRoutingRows(
        cloudRoutes: const CloudRoutes({}),
        liveBackend: LiveBackend.none,
      );
      expect(where(rows, 'Pantry scan'), contains('On this device only'));
      expect(where(rows, 'Pantry voice'), startsWith('Off in this build'));
      expect(where(rows, 'Watch my food'), 'On this device only.');
      expect(where(rows, 'Coach Lite'), 'On this device only.');
      expect(where(rows, 'Live coach'), startsWith('Off in this build'));
      expect(where(rows, 'Grounded research'), 'Off in this build.');
    });

    test('with hybrid fallback approved, the cloud legs say so', () {
      final rows = hybridRoutingRows(
        cloudRoutes: CloudRoutes.parse('hybridFallback,research'),
        liveBackend: LiveBackend.none,
      );
      expect(where(rows, 'Pantry scan'), contains('otherwise Google cloud'));
      expect(where(rows, 'Pantry scan'), contains('allow them'));
      // The watch itself never leaves the device; only the explicit,
      // consented cloud check does.
      expect(where(rows, 'Watch my food'), startsWith('On this device only'));
      expect(where(rows, 'Watch: '), contains('allow that exact request'));
      expect(where(rows, 'Coach Lite'), contains('retried once in the cloud'));
      expect(where(rows, 'Grounded research'), contains('Google Search'));
    });

    test('aiLogic Live needs the live cloud route', () {
      String live(String routes) => where(
        hybridRoutingRows(
          cloudRoutes: CloudRoutes.parse(routes),
          liveBackend: LiveBackend.aiLogic,
        ),
        'Live coach',
      );
      expect(live(''), startsWith('Off in this build'));
      expect(live('live'), contains('Firebase AI Logic'));
    });

    testWidgets('the sheet shows the section and no DevFest card', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: HowItWorksSheet())),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('how-it-works-hybrid')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('how-it-works-hybrid')), findsOneWidget);
      expect(find.byKey(const ValueKey('devfest-x-ray-card')), findsNothing);
      expect(find.textContaining('DevFest'), findsNothing);
    });
  });

  group('runtime', () {
    test('configures the backend once, before any generate', () async {
      final inference = FakeHybridInference();
      final hybrid = _runtime(inference);
      await (hybrid.inference as ConfiguredHybridInference).configured;
      expect(inference.config?.cloudModel, 'test-cloud-model');
    });

    test('the first cooking session keeps pantry legs; a new cook clears', () {
      final hybrid = _runtime(FakeHybridInference());
      final runId = hybrid.sessionId;
      expect(runId, startsWith('run-'));
      hybrid.recordCloudLeg('pantry_voice', const {DataKind.audio});
      hybrid.bindCookingSession('s1');
      expect(hybrid.sessionId, 's1');
      expect(hybrid.ledgerSource.legs, hasLength(1));
      hybrid.bindCookingSession('s1');
      expect(hybrid.ledgerSource.legs, hasLength(1));
      hybrid.bindCookingSession('s2');
      expect(hybrid.ledgerSource.legs, isEmpty);
      expect(hybrid.ledger.sessionId, 's2');
    });

    test('the ledger source notifies the trust UI', () {
      final hybrid = _runtime(FakeHybridInference());
      var notified = 0;
      void listener() => notified++;
      hybrid.ledgerSource.addListener(listener);
      hybrid.recordCloudLeg('research', const {DataKind.text});
      hybrid.ledgerSource.removeListener(listener);
      hybrid.recordCloudLeg('research', const {DataKind.text});
      expect(notified, 1);
    });

    test(
      'a typed pantry-style request runs on device through the dispatcher',
      () async {
        final inference = FakeHybridInference()..enqueueText('{"ok":true}');
        final hybrid = _runtime(inference);
        final result = await hybrid.dispatcher
            .start(
              const HybridTask(
                feature: 'pantry_scan',
                parts: [HybridText('beans, rice')],
                maxOutputTokens: 64,
                timeout: Duration(seconds: 5),
              ),
              sessionId: hybrid.sessionId,
            )
            .result;
        expect(result.text, '{"ok":true}');
        expect(result.legs.single.provenance, Provenance.sdkOnDevice);
        expect(
          hybrid.ledgerSource.legs.single.provenance,
          Provenance.sdkOnDevice,
        );
        // No cloud route approved: preferOnDevice narrows to onlyOnDevice so
      // the SDK cannot fall back to the cloud on its own.
      expect(inference.requests.single.mode, HybridMode.onlyOnDevice);
      },
    );

    test(
      'with no cloud route a local-model miss is blocked, nothing sent',
      () async {
        final inference = FakeHybridInference(
          textAvailability: const HybridAvailability(
            status: OnDeviceStatus.unavailable,
          ),
        );
        final cloud = _NoCloud();
        final hybrid = _runtime(inference, cloud: cloud);
        final result = await hybrid.dispatcher
            .start(
              const HybridTask(
                feature: 'pantry_scan',
                parts: [HybridText('beans')],
                maxOutputTokens: 64,
                timeout: Duration(seconds: 5),
              ),
              sessionId: hybrid.sessionId,
            )
            .result;
        expect(result.ok, isFalse);
        expect(inference.requests, isEmpty);
        expect(cloud.sends, 0);
      },
    );
  });

  group('consent dialog', () {
    const ask = ConsentAsk(
      feature: 'pantry_scan',
      kinds: {DataKind.image, DataKind.text},
      payloadDigest: 'd',
      sessionId: 's',
    );

    test('says which data goes to whom', () {
      final copy = consentCopy(ask, cloudModel: 'm-1');
      expect(copy.body, contains('photo and text'));
      expect(copy.body, contains(kCloudRecipient));
      expect(copy.body, contains('m-1'));
      expect(copy.body, contains('nothing is sent'));
    });

    test('no navigator means no grant', () async {
      final gate = DialogConsentGate(
        navigatorKey: GlobalKey<NavigatorState>(),
        cloudModel: 'm',
      );
      expect(await gate.request(ask), isNull);
    });

    for (final (button, granted) in [
      ('consent-allow', true),
      ('consent-decline', false),
    ]) {
      testWidgets('$button ${granted ? 'grants once' : 'sends nothing'}', (
        tester,
      ) async {
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(navigatorKey: key, home: const SizedBox()),
        );
        final gate = DialogConsentGate(navigatorKey: key, cloudModel: 'm');
        ConsentGrant? grant;
        var done = false;
        unawaited(
          gate
              .requestWithPreview(ask, null)
              .then((g) => (grant, done) = (g, true)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Allow once'), findsOneWidget);
        expect(find.text("Don't send"), findsOneWidget);
        await tester.tap(find.byKey(ValueKey(button)));
        await tester.pumpAndSettle();
        expect(done, isTrue);
        expect(grant?.ask, granted ? same(ask) : isNull);
      });
    }
  });

  group('Dart cloud adapter', () {
    test('sends the task exactly and reports a cloud source', () async {
      GenerationConfig? sentConfig;
      String? sentInstruction;
      final sender = FirebaseAiCloudSender(
        model: 'm-2',
        generate:
            ({
              required model,
              required systemInstruction,
              required content,
              required config,
            }) async {
              sentConfig = config;
              sentInstruction = systemInstruction;
              expect(model, 'm-2');
              expect(content.parts, hasLength(2));
              return '{"a":1}';
            },
      );
      final result = await sender.send(
        HybridRequest(
          requestId: 'r1',
          mode: HybridMode.onlyInCloud,
          task: HybridTask(
            feature: 'label_check',
            systemInstruction: 'sys',
            parts: [
              const HybridText('hi'),
              HybridInlineData(Uint8List.fromList([1, 2]), 'image/jpeg'),
            ],
            jsonSchema: const {'type': 'object'},
            maxOutputTokens: 32,
            timeout: const Duration(seconds: 5),
          ),
        ),
      );
      expect(result.source, InferenceSource.cloud);
      expect(result.requestId, 'r1');
      expect(result.modelLabel, 'm-2');
      expect(sentInstruction, 'sys');
      expect(sentConfig!.toJson()['responseJsonSchema'], {'type': 'object'});
    });

    test('an empty reply fails instead of passing as an answer', () async {
      final sender = FirebaseAiCloudSender(
        model: 'm',
        generate: ({
          required model,
          required systemInstruction,
          required content,
          required config,
        }) async => null,
      );
      expect(
        sender.send(
          const HybridRequest(
            requestId: 'r',
            mode: HybridMode.onlyInCloud,
            task: HybridTask(
              feature: 'x',
              parts: [HybridText('q')],
              maxOutputTokens: 8,
              timeout: Duration(seconds: 1),
            ),
          ),
        ),
        throwsA(isA<HybridException>()),
      );
    });
  });

  group('cooking coordinator with Live off', () {
    late FakeHybridInference inference;
    late HybridRuntime hybrid;
    late _Media media;
    late _Research research;
    late CookingCoordinator cook;
    var researchApproved = false;

    setUp(() async {
      inference = FakeHybridInference();
      hybrid = _runtime(inference);
      media = _Media();
      research = _Research();
      researchApproved = false;
      cook = CookingCoordinator(
        services: AppServices(
          auth: FakeAuthService(),
          recipes: FakeRecipeRepository(_recipe),
          sessions: FakeSessionRepository(),
          bundledRecipe: _recipe,
        ),
        research: research,
        transportFactory: null,
        media: media,
        coachLite: CoachLite(
          dispatcher: hybrid.dispatcher,
          privacy: hybrid.privacy,
          cloudRoutes: hybrid.cloudRoutes,
          isOnline: hybrid.isOnline,
        ),
        watchServiceFactory: (live) => buildWatchService(hybrid, live),
        onSessionReady: hybrid.bindCookingSession,
        researchAllowed: () => researchApproved,
        recordCloudLeg: hybrid.recordCloudLeg,
      );
      await cook.initialize();
      await _flush();
    });

    tearDown(() async {
      cook.dispose();
      await _flush();
    });

    test('binds the ledger to the session and hides Live', () async {
      expect(cook.liveEnabled, isFalse);
      expect(hybrid.sessionId, cook.session!.id);
      await cook.connect();
      expect(cook.live.isActive, isFalse);
      expect(cook.alert, contains('Live coach is off'));
    });

    test('a typed question goes to Coach Lite on this device, and its timer '
        'suggestion starts only on the cook\'s tap', () async {
      inference.enqueueText(
        _liteJson(timer: {'label': 'Rest the mash', 'seconds': 120}),
      );
      expect(await cook.say('How chunky should it be?'), isTrue);
      await _flush();
      final answer = cook.coachLiteAnswer!;
      expect(answer.status, CoachLiteStatus.answered);
      expect(answer.legs.single.provenance, Provenance.sdkOnDevice);
      expect(inference.requests.single.mode, HybridMode.onlyOnDevice);
      expect(hybrid.ledgerSource.legs.single.feature, 'coach_lite');
      expect(cook.ui.timers, isEmpty);
      await cook.startSuggestedTimer(
        answer.timerSuggestion!.label,
        answer.timerSuggestion!.seconds,
      );
      expect(cook.ui.timers.single.label, 'Rest the mash');
    });

    test('a step change drops a late Coach Lite answer', () async {
      inference
        ..delay = const Duration(milliseconds: 50)
        ..enqueueText(_liteJson());
      await cook.say('How chunky should it be?');
      await cook.advanceStep();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _flush();
      expect(cook.coachLiteAnswer, isNull);
      expect(cook.coachLiteBusy, isFalse);
    });

    test(
      'grounded research is refused when the route is not approved',
      () async {
        expect(await cook.researchQuestionNow('Is it ok?'), isNull);
        expect(research.queries, isEmpty);
        expect(cook.error, contains('off in this build'));
        researchApproved = true;
        await cook.researchQuestionNow('Is it ok?');
        expect(research.queries, hasLength(1));
        expect(hybrid.ledgerSource.legs.last.feature, 'research');
      },
    );

    test('Watch my food runs on this device, camera only', () async {
      await cook.startWatch();
      await _flush();
      expect(cook.watching, isTrue);
      expect(cook.watchService!.local.isActive, isTrue);
      expect(media.cameraOnlyStarts, 1);
      expect(media.fullStarts, 0);
      expect(cook.watchService!.captureLabel, contains('microphone off'));
      cook.stopWatch();
      await _flush();
      expect(cook.watching, isFalse);
    });

    test('the privacy switches are the dispatcher\'s settings', () {
      final prefs = hybrid.privacy as InMemoryPrivacyPreferences;
      prefs.setLocalOnly('coach_lite', true);
      expect(hybrid.privacy.localOnly('coach_lite'), isTrue);
    });
  });
}
