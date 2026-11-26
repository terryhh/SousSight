// SS-096: startup configure never holds a request past its own deadline,
// "Keep Pantry scan on this device" keeps the pantry voice clip here (and the
// cook is told), and only a ConsentGate can issue a ConsentGrant.
// Fakes only; no model, network or device is used.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/trust/privacy_preferences.dart';

/// [FakeHybridInference] whose configure finishes only when [release]d
/// (on web, configure includes an unbounded `import()`).
class _SlowStart extends FakeHybridInference {
  final _done = Completer<void>();
  void release() => _done.complete();

  @override
  Future<void> configure(HybridConfig config) => _done.future;
}

HybridRequest _request(Duration timeout) => HybridRequest(
  requestId: 'r1',
  mode: HybridMode.onlyOnDevice,
  task: HybridTask(
    feature: 'coach_lite',
    parts: const [HybridText('Is the pan hot?')],
    maxOutputTokens: 16,
    timeout: timeout,
  ),
);

class _FailingStart extends FakeHybridInference {
  @override
  Future<void> configure(HybridConfig config) =>
      Future.error(StateError('bridge script failed to load'));
}

/// A valid 1x1 PNG, so the consent preview decodes.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _CountingCloud implements CloudFallbackSender {
  int sends = 0;
  @override
  Future<HybridResult> send(HybridRequest request) async {
    sends++;
    throw const HybridException(HybridErrorCode.failed, 'not in tests');
  }

  @override
  Future<void> cancel(String requestId) async {}
}

class _Gate extends ConsentGate {
  @override
  Future<ConsentGrant?> request(ConsentAsk ask) async => issue(ask);
}

String _scan() => jsonEncode({
  'items': [
    {'name': 'canned black beans', 'confidence': 'high'},
  ],
  'meals': [
    {
      'recipeId': 'black_bean_corn_salsa_v1',
      'why': 'Beans and corn are most of it.',
      'matched': ['black beans'],
      'missing': ['lime'],
    },
  ],
});

bool _hasAudio(HybridRequest r) =>
    r.task.parts.any((p) => p is HybridInlineData && p.mimeType == 'audio/wav');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConfiguredHybridInference waits for configure only so long', () {
    test('generate throws timeout at the task deadline; nothing is '
        'forwarded', () async {
      final inner = _SlowStart()..enqueueText('late');
      final configured = ConfiguredHybridInference(
        inner,
        const HybridConfig(cloudModel: 'm'),
      );
      final watch = Stopwatch()..start();
      await expectLater(
        configured.generate(_request(const Duration(milliseconds: 40))),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.timeout,
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(inner.requests, isEmpty);
    });

    test('capabilities throws timeout after configureWait', () async {
      final inner = _SlowStart();
      final configured = ConfiguredHybridInference(
        inner,
        const HybridConfig(cloudModel: 'm'),
        configureWait: const Duration(milliseconds: 20),
      );
      await expectLater(
        configured.capabilities(),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.timeout,
          ),
        ),
      );
    });

    test(
      'a configure that finishes in time lets the request through',
      () async {
        final inner = _SlowStart()..enqueueText('ok');
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
        );
        final result = configured.generate(
          _request(const Duration(seconds: 5)),
        );
        final caps = configured.capabilities();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(inner.requests, isEmpty, reason: 'still waiting for configure');
        inner.release();
        expect((await result).text, 'ok');
        expect((await caps).supportedModes, isNotEmpty);
        expect(inner.requests, hasLength(1));
      },
    );

    test('the dispatcher treats a capabilities timeout as no bridge', () async {
      final inner = _SlowStart();
      final dispatcher = DefaultHybridDispatcher(
        inference: ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          configureWait: const Duration(milliseconds: 20),
        ),
        privacy: InMemoryPrivacyPreferences(),
        cloudRoutes: const CloudRoutes({}),
        consent: _Gate(),
        ledger: InferenceLedger(sessionId: 's'),
      );
      final result = await dispatcher
          .start(_request(const Duration(seconds: 1)).task, sessionId: 's')
          .result
          .timeout(const Duration(seconds: 5));
      expect(result.ok, isFalse);
      // No capabilities means no local model; with no cloud route, blocked.
      expect(result.blocked, RouteReason.cloudNotApproved);
      expect(inner.requests, isEmpty);
    });
  });

  group('runtime plumbing around the bounded wait', () {
    test('a failed configure still settles; calls are forwarded', () async {
      final inner = _FailingStart()..enqueueText('ok');
      final configured = ConfiguredHybridInference(
        inner,
        const HybridConfig(cloudModel: 'm'),
      );
      await configured.configured;
      expect(
        (await configured.generate(_request(const Duration(seconds: 1)))).text,
        'ok',
      );
      // A later explicit configure goes straight to the bridge.
      await expectLater(
        configured.configure(const HybridConfig(cloudModel: 'm2')),
        throwsStateError,
      );
      expect(await configured.prepare(withImage: false).toList(), isNotEmpty);
      await configured.cancel('r9');
      expect(inner.cancelled, ['r9']);
    });

    HybridRequest cloudRequest(Duration timeout) => HybridRequest(
      requestId: 'c1',
      mode: HybridMode.onlyInCloud,
      task: HybridTask(
        feature: 'label_check',
        parts: const [HybridText('Contains peanuts')],
        maxOutputTokens: 16,
        timeout: timeout,
      ),
    );

    Matcher code(HybridErrorCode c) =>
        throwsA(isA<HybridException>().having((e) => e.code, 'code', c));

    test('the Dart cloud adapter maps its failures to bridge codes', () async {
      FirebaseAiCloudSender sender(Future<String?> Function() reply) =>
          FirebaseAiCloudSender(
            model: 'm',
            generate: ({
              required model,
              required systemInstruction,
              required content,
              required config,
            }) => reply(),
          );
      await expectLater(
        sender(() => Completer<String?>().future)
            .send(cloudRequest(const Duration(milliseconds: 10))),
        code(HybridErrorCode.timeout),
      );
      await expectLater(
        sender(() => Future.error(QuotaExceeded('quota')))
            .send(cloudRequest(const Duration(seconds: 1))),
        code(HybridErrorCode.quota),
      );
      await expectLater(
        sender(() => Future.error(FirebaseAIException('bad')))
            .send(cloudRequest(const Duration(seconds: 1))),
        code(HybridErrorCode.failed),
      );
      final reply = Completer<String?>();
      final cancellable = sender(() => reply.future);
      final pending = cancellable.send(
        cloudRequest(const Duration(seconds: 1)),
      );
      await cancellable.cancel('c1');
      reply.complete('late');
      await expectLater(pending, code(HybridErrorCode.cancelled));
    });

    testWidgets('the frame consent prompt shows the exact photo', (
      tester,
    ) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      final gate = FramePreviewConsentGate(
        DialogConsentGate(navigatorKey: key, cloudModel: 'm'),
        () => _png,
      );
      const ask = ConsentAsk(
        feature: 'local_watch_cloud_check',
        kinds: {DataKind.image},
        payloadDigest: 'd',
        sessionId: 's',
      );
      ConsentGrant? grant;
      unawaited(gate.request(ask).then((g) => grant = g));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('consent-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('consent-allow')));
      await tester.pumpAndSettle();
      expect(grant?.ask, same(ask));
    });

    test('label check controllers share the runtime', () {
      final hybrid = HybridRuntime.create(
        inference: FakeHybridInference(),
        cloudRoutes: const CloudRoutes({}),
        isOnline: () => true,
        cloudModel: 'm',
      );
      final controller = hybrid.labelCheck('s1');
      addTearDown(controller.dispose);
      expect(controller, isNotNull);
    });
  });

  group('pantry voice inherits "Keep Pantry scan on this device"', () {
    late List<Recipe> recipes;
    final audio = Uint8List.fromList(List.filled(64, 3));

    setUpAll(() async => recipes = await loadRecipeCatalog());

    ({
      HybridRuntime hybrid,
      FakeHybridInference inference,
      _CountingCloud cloud,
    })
    wired({required bool keepLocal}) {
      final inference = FakeHybridInference();
      final cloud = _CountingCloud();
      final hybrid = HybridRuntime.create(
        inference: inference,
        // The cloud is approved, so only the cook's switch keeps it local.
        cloudRoutes: CloudRoutes.parse('hybridFallback'),
        privacy: InMemoryPrivacyPreferences({if (keepLocal) 'pantry_scan'}),
        cloudFallback: cloud,
        isOnline: () => true,
        cloudModel: 'm',
      );
      return (hybrid: hybrid, inference: inference, cloud: cloud);
    }

    test('switch on: the clip never uploads and the cook is told', () async {
      final w = wired(keepLocal: true);
      w.inference.enqueueText(_scan());
      final client = HybridPantryClient(
        dispatcher: w.hybrid.dispatcher,
        sessionId: () => w.hybrid.sessionId,
      );
      final result = await client.identify(
        PantryInput(text: 'black beans', audioWav: audio),
        recipes,
      );
      expect(result.notice, kPantryVoiceKeptLocalNotice);
      expect(w.inference.requests.where(_hasAudio), isEmpty);
      expect(w.inference.requests.single.mode, HybridMode.onlyOnDevice);
      expect(w.cloud.sends, 0);
      expect(
        w.hybrid.ledger.legs.where((l) => l.feature == kPantryVoiceFeature),
        isEmpty,
      );
      expect(w.hybrid.ledger.legs.every((l) => !l.transferPermitted), isTrue);
    });

    test('switch on with only a voice clip: stops and says why', () async {
      final w = wired(keepLocal: true);
      final client = HybridPantryClient(
        dispatcher: w.hybrid.dispatcher,
        sessionId: () => w.hybrid.sessionId,
      );
      await expectLater(
        client.identify(PantryInput(audioWav: audio), recipes),
        throwsA(
          isA<PantryException>().having(
            (e) => e.message,
            'message',
            contains('stayed on this device'),
          ),
        ),
      );
      expect(w.inference.requests, isEmpty);
      expect(w.cloud.sends, 0);
    });

    test('switch off: the labelled clip goes to the cloud as before', () async {
      final w = wired(keepLocal: false);
      w.inference
        ..enqueueText(
          jsonEncode({
            'items': [
              {'name': 'corn', 'confidence': 'high'},
            ],
          }),
          source: InferenceSource.cloud,
        )
        ..enqueueText(_scan());
      final client = HybridPantryClient(
        dispatcher: w.hybrid.dispatcher,
        sessionId: () => w.hybrid.sessionId,
      );
      final result = await client.identify(
        PantryInput(text: 'black beans', audioWav: audio),
        recipes,
      );
      expect(result.notice, isNull);
      final voice = w.inference.requests.where(_hasAudio).single;
      expect(voice.mode, HybridMode.onlyInCloud);
    });
  });

  test('a ConsentGate issues a grant bound to the exact ask', () async {
    const ask = ConsentAsk(
      feature: 'pantry_scan',
      kinds: {DataKind.image},
      payloadDigest: 'digest',
      sessionId: 's1',
    );
    final grant = await _Gate().request(ask);
    expect(grant!.ask, same(ask));
  });
}
