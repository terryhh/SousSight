// SS-096: startup configure never holds a request past its own deadline,
// "Keep Pantry scan on this device" keeps the pantry voice clip here (and the
// cook is told), and only a ConsentGate can issue a ConsentGrant.
// Fakes only; no model, network or device is used.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:fake_async/fake_async.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/ai/hybrid/payload_digest.dart';
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

/// A [Stopwatch] that reads fake time, so the remaining budget handed to the
/// backend is observable under [fakeAsync].
class _FakeStopwatch implements Stopwatch {
  _FakeStopwatch(this.async);
  final FakeAsync async;
  Duration? _startedAt;

  @override
  void start() => _startedAt ??= async.elapsed;

  @override
  Duration get elapsed =>
      _startedAt == null ? Duration.zero : async.elapsed - _startedAt!;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Startup is immediate; generate keeps the isolate busy for [work] (fake
/// time passes without timers firing) and returns an already-completed
/// future, as a synchronous backend would.
class _BusyBackend extends FakeHybridInference {
  _BusyBackend(this.async, this.work, {this.fail = false});
  final FakeAsync async;
  final Duration work;
  final bool fail;

  @override
  Future<void> configure(HybridConfig config) async {}

  @override
  Future<HybridResult> generate(HybridRequest request) {
    requests.add(request);
    async.elapseBlocking(work);
    if (fail) {
      return Future.error(
        const HybridException(HybridErrorCode.failed, 'busy failure'),
      );
    }
    return Future.value(
      HybridResult(
        requestId: request.requestId,
        text: 'busy',
        source: InferenceSource.onDevice,
      ),
    );
  }
}

/// Configure settles after [startup]; generation takes [work] and, unless
/// [ignoresDeadline], honours the timeout it is handed (as the contract
/// requires of every backend).
class _TimedBackend extends FakeHybridInference {
  _TimedBackend({
    required this.startup,
    required this.work,
    this.ignoresDeadline = false,
  });
  final Duration startup;
  final Duration work;
  final bool ignoresDeadline;
  final handed = <Duration>[];

  @override
  Future<void> configure(HybridConfig config) => Future<void>.delayed(startup);

  @override
  Future<HybridResult> generate(HybridRequest request) {
    requests.add(request);
    handed.add(request.task.timeout);
    final answer = Future<HybridResult>.delayed(
      work,
      () => HybridResult(
        requestId: request.requestId,
        text: 'late',
        source: InferenceSource.onDevice,
      ),
    );
    if (ignoresDeadline) return answer;
    return answer.timeout(
      request.task.timeout,
      onTimeout: () =>
          throw const HybridException(HybridErrorCode.timeout, 'timed out'),
    );
  }
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

/// Web-shaped stall: configure, capabilities and availability all wait on
/// one SDK `import()` that never resolves.
class _SharedImport extends FakeHybridInference {
  final _import = Completer<void>();

  @override
  Future<void> configure(HybridConfig config) => _import.future;

  @override
  Future<HybridCapabilities> capabilities() =>
      _import.future.then((_) => capabilitiesValue);

  @override
  Future<HybridAvailability> availability({required bool withImage}) =>
      _import.future.then((_) => textAvailability);
}

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
  Future<bool> confirm(ConsentAsk ask, {Uint8List? preview}) async => true;
  Future<ConsentGrant> grantFor(ConsentAsk ask) async => (await request(ask))!;
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

    test('after configureWait, discovery reports no local model instead '
        'of throwing (Codex P2)', () async {
      final inner = _SlowStart();
      final configured = ConfiguredHybridInference(
        inner,
        const HybridConfig(cloudModel: 'm'),
        configureWait: const Duration(milliseconds: 20),
      );
      final caps = await configured.capabilities().timeout(
        const Duration(seconds: 5),
      );
      expect(caps.platform, 'none');
      expect(caps.supportedModes, isEmpty);
      final text = await configured
          .availability(withImage: false)
          .timeout(const Duration(seconds: 5));
      expect(text.status, OnDeviceStatus.unavailable);
    });

    // Codex P2: on web, availability awaits the same import() as configure.
    // Bounding only capabilities left the dispatcher hanging in availability.
    test('a stalled import shared by configure and availability cannot hang '
        'a dispatcher caller', () async {
      final inner = _SharedImport();
      final dispatcher = DefaultHybridDispatcher(
        inference: ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          configureWait: const Duration(milliseconds: 10),
        ),
        privacy: InMemoryPrivacyPreferences(),
        cloudRoutes: const CloudRoutes({}),
        consent: _Gate(),
        ledger: InferenceLedger(sessionId: 's'),
      );
      final watch = Stopwatch()..start();
      final result = await dispatcher
          .start(
            _request(const Duration(milliseconds: 25)).task,
            sessionId: 's',
          )
          .result
          .timeout(const Duration(seconds: 2));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 300)));
      expect(result.ok, isFalse);
      expect(result.blocked, RouteReason.cloudNotApproved);
      expect(inner.requests, isEmpty);
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

  group('one deadline covers configure plus generation (Codex P2)', () {
    // Codex P2 (77/100): a busy isolate can run the completion microtask
    // before the deadline timer. The monotonic clock must still decide.
    test('an answer delivered after the deadline by a busy isolate is '
        'refused', () {
      fakeAsync((async) {
        final inner = _BusyBackend(async, const Duration(milliseconds: 60));
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          stopwatch: () => _FakeStopwatch(async),
        );
        async.flushMicrotasks(); // startup done
        HybridResult? result;
        Object? error;
        configured
            .generate(_request(const Duration(milliseconds: 20)))
            .then<void>(
              (r) => result = r,
              onError: (Object e) {
                error = e;
              },
            );
        async.flushMicrotasks();
        expect(result, isNull, reason: 'the 60ms answer missed a 20ms budget');
        expect(
          error,
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.timeout,
          ),
        );
        async.elapse(const Duration(milliseconds: 100));
        expect(result, isNull);
      });
    });

    test('a busy backend error after the deadline is reported as timeout', () {
      fakeAsync((async) {
        final inner = _BusyBackend(
          async,
          const Duration(milliseconds: 60),
          fail: true,
        );
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          stopwatch: () => _FakeStopwatch(async),
        );
        async.flushMicrotasks();
        Object? error;
        configured
            .generate(_request(const Duration(milliseconds: 20)))
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.flushMicrotasks();
        expect((error as HybridException?)?.code, HybridErrorCode.timeout);
      });
    });

    test('an answer inside the budget from a fast backend is used', () {
      fakeAsync((async) {
        final inner = _BusyBackend(async, const Duration(milliseconds: 5));
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          stopwatch: () => _FakeStopwatch(async),
        );
        async.flushMicrotasks();
        HybridResult? result;
        configured
            .generate(_request(const Duration(milliseconds: 20)))
            .then<void>((r) => result = r);
        async.flushMicrotasks();
        expect(result?.text, 'busy');
      });
    });

    // #227 review: a configure that never settles must not hold a cancelled
    // request until its deadline; configure races the cancellation.
    test('cancel wins over a configure that never settles', () {
      fakeAsync((async) {
        final inner = _SlowStart(); // never released
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
        );
        Object? error;
        configured
            .generate(_request(const Duration(seconds: 30)))
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(const Duration(milliseconds: 5));
        expect(error, isNull);
        unawaited(configured.cancel('r1'));
        async.flushMicrotasks();
        expect(
          (error as HybridException?)?.code,
          HybridErrorCode.cancelled,
          reason: 'settled at once, not at the 30s deadline',
        );
        expect(inner.requests, isEmpty);
        expect(inner.cancelled, isEmpty);
      });
    });

    // Pre-existing (Codex): cancelling while startup is still running used
    // to reach a backend with no such request, and generate still ran.
    test('a request cancelled while waiting for configure is never '
        'forwarded', () async {
      final inner = _SlowStart();
      final configured = ConfiguredHybridInference(
        inner,
        const HybridConfig(cloudModel: 'm'),
      );
      final pending = expectLater(
        configured.generate(_request(const Duration(seconds: 5))),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.cancelled,
          ),
        ),
      );
      await configured.cancel('r1');
      inner.release();
      await pending;
      expect(inner.requests, isEmpty);
      expect(inner.cancelled, isEmpty, reason: 'the backend never had r1');
      // The cancellation was spent: a later request is not affected.
      inner.enqueueText('ok');
      final later = HybridRequest(
        requestId: 'r2',
        mode: HybridMode.onlyOnDevice,
        task: _request(const Duration(seconds: 5)).task,
      );
      expect((await configured.generate(later)).text, 'ok');
      expect(inner.requests.single.requestId, 'r2');
    });

    // Codex's repro: a 100ms task, configure finishing at 90ms and a backend
    // that needs 90ms. Before the fix the backend was handed the full 100ms
    // and the call could succeed at 180ms.
    test('configure at 90ms + 90ms backend fails by the 100ms deadline and '
        'the backend gets only the remaining 10ms', () {
      fakeAsync((async) {
        final inner = _TimedBackend(
          startup: const Duration(milliseconds: 90),
          work: const Duration(milliseconds: 90),
        );
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          stopwatch: () => _FakeStopwatch(async),
        );
        HybridResult? result;
        Object? error;
        Duration? settledAt;
        configured
            .generate(_request(const Duration(milliseconds: 100)))
            .then<void>(
              (r) => result = r,
              onError: (Object e) {
                error = e;
              },
            )
            .whenComplete(() => settledAt = async.elapsed);
        async.elapse(const Duration(milliseconds: 100));
        expect(settledAt, isNotNull, reason: 'settled within the budget');
        expect(settledAt, lessThanOrEqualTo(const Duration(milliseconds: 100)));
        expect(result, isNull);
        expect(
          error,
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.timeout,
          ),
        );
        expect(inner.handed, [const Duration(milliseconds: 10)]);
        async.elapse(const Duration(milliseconds: 200));
        expect(result, isNull, reason: 'no late success at 180ms');
      });
    });

    test('a backend that ignores its deadline is cancelled at the overall '
        'deadline and its late answer is dropped', () {
      fakeAsync((async) {
        final inner = _TimedBackend(
          startup: const Duration(milliseconds: 90),
          work: const Duration(milliseconds: 90),
          ignoresDeadline: true,
        );
        // Default (real) stopwatch: the single deadline timer alone must
        // bound the call, whatever the measured elapsed time says.
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
        );
        HybridResult? result;
        Object? error;
        configured
            .generate(_request(const Duration(milliseconds: 100)))
            .then<void>(
              (r) => result = r,
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(const Duration(milliseconds: 99));
        expect(error, isNull);
        expect(inner.requests, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(
          error,
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.timeout,
          ),
        );
        async.flushMicrotasks();
        expect(inner.cancelled, ['r1']);
        async.elapse(const Duration(milliseconds: 200));
        expect(result, isNull);
      });
    });

    test('a configure that settles after the deadline never forwards the '
        'request', () {
      fakeAsync((async) {
        final inner = _TimedBackend(
          startup: const Duration(milliseconds: 150),
          work: const Duration(milliseconds: 1),
        );
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          stopwatch: () => _FakeStopwatch(async),
        );
        Object? error;
        configured
            .generate(_request(const Duration(milliseconds: 100)))
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(const Duration(milliseconds: 100));
        expect(error, isA<HybridException>());
        async.elapse(const Duration(milliseconds: 200));
        expect(inner.requests, isEmpty);
        expect(inner.cancelled, isEmpty, reason: 'nothing was sent');
      });
    });

    test('within budget the answer arrives and the backend gets what startup '
        'left', () {
      fakeAsync((async) {
        final inner = _TimedBackend(
          startup: const Duration(milliseconds: 30),
          work: const Duration(milliseconds: 20),
        );
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          stopwatch: () => _FakeStopwatch(async),
        );
        HybridResult? result;
        configured
            .generate(_request(const Duration(milliseconds: 100)))
            .then((r) => result = r);
        async.elapse(const Duration(milliseconds: 50));
        expect(result?.text, 'late');
        expect(result?.requestId, 'r1');
        expect(inner.handed, [const Duration(milliseconds: 70)]);
        expect(inner.cancelled, isEmpty);
        final sent = inner.requests.single;
        expect(sent.mode, HybridMode.onlyOnDevice);
        expect(sent.task.feature, 'coach_lite');
        expect(sent.task.maxOutputTokens, 16);
      });
    });

    test('a blocked forward after startup is reported, not timed out', () {
      fakeAsync((async) {
        final inner = _TimedBackend(
          startup: const Duration(milliseconds: 10),
          work: const Duration(milliseconds: 10),
        );
        final configured = ConfiguredHybridInference(
          inner,
          const HybridConfig(cloudModel: 'm'),
          mayForward: (_) => false,
        );
        Object? error;
        configured
            .generate(
              HybridRequest(
                requestId: 'c9',
                mode: HybridMode.preferOnDevice,
                task: _request(const Duration(milliseconds: 100)).task,
              ),
            )
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(const Duration(milliseconds: 20));
        expect(
          error,
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.blocked,
          ),
        );
        expect(inner.requests, isEmpty);
      });
    });
  });

  // Codex #224 (71/100) P1: the final check runs after the backend's startup
  // wait, immediately before the send, not only in the dispatcher.
  group('the last check runs after the startup wait', () {
    HybridTask text(String feature) => HybridTask(
      feature: feature,
      parts: const [HybridText('eggs, rice')],
      maxOutputTokens: 16,
      timeout: const Duration(seconds: 5),
    );

    test('going offline in a microtask queued at admission: nothing sent, '
        'the leg unsent', () async {
      var online = true;
      final inference = FakeHybridInference(
        textAvailability: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
        ),
      )..enqueueText('{}', source: InferenceSource.cloud);
      final hybrid = HybridRuntime.create(
        inference: inference,
        cloudRoutes: CloudRoutes.parse('hybridFallback'),
        cloudFallback: _CountingCloud(),
        isOnline: () => online,
        cloudModel: 'm',
      );
      hybrid.ledger.addListener(() {
        if (hybrid.ledger.entries.any((e) => e.pending)) {
          scheduleMicrotask(() => online = false);
        }
      });
      final r = await hybrid.dispatcher
          .start(text('recipe_draft'), sessionId: hybrid.sessionId)
          .result;
      expect(inference.requests, isEmpty);
      expect(r.text, isNull);
      final entry = hybrid.ledger.entries.first;
      expect(entry.pending, isFalse);
      expect(entry.leg.transferPermitted, isFalse);
      expect(entry.uploadUnknown, isFalse);
    });

    test('a new pantry flow in a microtask queued at admission: nothing '
        'sent, no answer accepted', () async {
      final inference = FakeHybridInference()..enqueueText('answer');
      final hybrid = HybridRuntime.create(
        inference: inference,
        cloudRoutes: const CloudRoutes({}),
        cloudFallback: _CountingCloud(),
        isOnline: () => true,
        cloudModel: 'm',
      );
      hybrid.bindCookingSession('meal-a');
      hybrid.ledger.addListener(() {
        if (hybrid.ledger.entries.any((e) => e.pending)) {
          scheduleMicrotask(hybrid.beginPantry);
        }
      });
      final r = await hybrid.dispatcher
          .start(text('coach_lite'), sessionId: 'meal-a')
          .result;
      expect(inference.requests, isEmpty);
      expect(r.text, isNull);
      expect(hybrid.ledger.entries, isEmpty, reason: 'new ledger untouched');
    });

    test('stillWanted false: refused after configure as not sent', () async {
      final inner = _SlowStart()..enqueueText('x');
      final configured = ConfiguredHybridInference(
        inner,
        const HybridConfig(cloudModel: 'm'),
        stillWanted: (_) => false,
      );
      final pending = expectLater(
        configured.generate(_request(const Duration(seconds: 5))),
        throwsA(isA<NotSentException>()),
      );
      inner.release();
      await pending;
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
            }) => reply().then((text) => CloudReply(text)),
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
      final ask = ConsentAsk(
        feature: 'local_watch_cloud_check',
        kinds: const {DataKind.image},
        payloadDigest: 'd',
        sessionId: 's',
        imageDigests: {sha256Hex(_png)},
      );
      ConsentGrant? grant;
      unawaited(gate.request(ask).then((g) => grant = g));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('consent-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('consent-allow')));
      await tester.pumpAndSettle();
      expect(grant?.ask, _sameAskAs(ask));
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

    // Codex P2: the switch turned on while the voice request was in flight.
    // The bridge leg failed with an unknown upload; the adapter retry was
    // then blocked by local-only. The clip may have left, so the cook must
    // not be told it "stayed on this device".
    ({
      FakeHybridInference inference,
      HybridPantryClient client,
      _CountingCloud cloud,
    })
    flipMidFlight() {
      final w = wired(keepLocal: false);
      final prefs = w.hybrid.privacy as InMemoryPrivacyPreferences;
      w.inference.script.add((HybridRequest r) {
        prefs.setLocalOnly('pantry_scan', true);
        return const HybridException(HybridErrorCode.unavailable, 'no bridge');
      });
      final client = HybridPantryClient(
        dispatcher: w.hybrid.dispatcher,
        sessionId: () => w.hybrid.sessionId,
      );
      return (inference: w.inference, client: client, cloud: w.cloud);
    }

    test('switch turned on mid-flight after an unknown upload: no '
        '"stayed on this device" notice', () async {
      final f = flipMidFlight();
      f.inference.enqueueText(_scan());
      final result = await f.client.identify(
        PantryInput(text: 'black beans', audioWav: audio),
        recipes,
      );
      expect(f.inference.requests.where(_hasAudio), hasLength(1));
      expect(f.cloud.sends, 0, reason: 'the adapter retry was blocked');
      final voiceLegs = result.legs.where(
        (l) => l.feature == kPantryVoiceFeature,
      );
      expect(voiceLegs, isNotEmpty);
      expect(result.notice, isNot(kPantryVoiceKeptLocalNotice));
      expect(result.notice, kPantryVoiceMaybeSentNotice);
    });

    test('switch turned on mid-flight, voice only: the error does not claim '
        'the clip stayed here', () async {
      final f = flipMidFlight();
      await expectLater(
        f.client.identify(PantryInput(audioWav: audio), recipes),
        throwsA(
          isA<PantryException>().having(
            (e) => e.message,
            'message',
            allOf(
              isNot(contains('stayed on this device')),
              contains('may have reached Google cloud AI'),
            ),
          ),
        ),
      );
      expect(f.cloud.sends, 0);
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
    final gate = _Gate();
    final grant = await gate.request(ask);
    expect(grant!.ask, _sameAskAs(ask));
    expect(gate.issued(grant), isTrue);
    expect(_Gate().issued(grant), isFalse, reason: 'bound to its issuer');
  });

  test('the frame preview gate asks its dialog, with the frame, and the '
      'grant is the dialog\'s', () async {
    final frame = Uint8List.fromList([1, 2, 3]);
    final dialog = _AllowingDialog();
    final preview = FramePreviewConsentGate(dialog, () => frame);
    final ask = ConsentAsk(
      feature: 'local_watch_cloud_check',
      kinds: const {DataKind.image},
      payloadDigest: 'd',
      sessionId: 's1',
      imageDigests: {sha256Hex(frame)},
    );
    final grant = await preview.request(ask);
    expect(dialog.previews, [frame]); // the gate's own copy of the frame
    expect(grant!.ask, _sameAskAs(ask));
    expect(dialog.issued(grant), isTrue);
    expect(preview.issued(grant), isTrue);
    expect(preview.issued(await _Gate().grantFor(ask)), isFalse);
  });

  // Codex P1 (77/100): there is no public mint. Feature code holding the
  // runtime's gate gets a grant only by showing the cook the dialog.
  testWidgets('the runtime gate grants nothing without its dialog', (
    tester,
  ) async {
    final hybrid = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: CloudRoutes.parse('hybridFallback'),
      cloudFallback: _CountingCloud(),
      isOnline: () => true,
      cloudModel: 'm',
    );
    const ask = ConsentAsk(
      feature: 'label_check',
      kinds: {DataKind.image},
      payloadDigest: 'd',
      sessionId: 's1',
    );
    // No navigator is mounted, so no dialog can be shown: no grant.
    expect(await hybrid.consent.request(ask), isNull);

    await tester.pumpWidget(
      MaterialApp(navigatorKey: hybrid.navigatorKey, home: const SizedBox()),
    );
    ConsentGrant? grant;
    unawaited(hybrid.consent.request(ask).then((g) => grant = g));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('consent-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('consent-allow')));
    await tester.pumpAndSettle();
    expect(hybrid.consent.issued(grant!), isTrue);
  });

  // Codex #224 (65/100) P1: a caller-supplied preview of another photo is
  // never shown for photo A's grant.
  test('the gate shows its own copy of the preview: mutating the caller\'s '
      'buffer after request() changes nothing', () async {
    final photoA = Uint8List.fromList([1, 2, 3]);
    final buffer = Uint8List.fromList(photoA);
    final gateOpen = Completer<bool>();
    final dialog = _HeldDialog(gateOpen.future);
    final ask = ConsentAsk(
      feature: 'local_watch_cloud_check',
      kinds: const {DataKind.image},
      payloadDigest: 'd',
      sessionId: 's1',
      imageDigests: {sha256Hex(photoA)},
    );
    final pending = dialog.request(ask, preview: buffer);
    buffer.setAll(0, [9, 9, 9]); // the caller swaps the bytes
    gateOpen.complete(true);
    await pending;
    expect(dialog.shown.single, photoA);
  });

  test(
    'the prompt shows a preview only if it is one of the payload photos',
    () async {
      final photoA = Uint8List.fromList([1, 2, 3]);
      final photoB = Uint8List.fromList([9, 9, 9]);
      final task = HybridTask(
        feature: 'local_watch_cloud_check',
        parts: [HybridInlineData(photoA, 'image/jpeg')],
        maxOutputTokens: 8,
        timeout: const Duration(seconds: 1),
      );
      final ask = ConsentAsk(
        feature: 'local_watch_cloud_check',
        kinds: const {DataKind.image},
        payloadDigest: hybridPayloadDigest(task),
        sessionId: 's1',
        imageDigests: taskImageDigests(task),
      );
      final dialog = _AllowingDialog();
      await dialog.request(ask, preview: photoB);
      await dialog.request(ask, preview: photoA);
      // Through the frame preview gate, a mismatched frame is dropped too.
      await FramePreviewConsentGate(dialog, () => photoB).request(ask);
      // An ask that names no photos shows no preview at all.
      await dialog.request(
        ConsentAsk(
          feature: 'label_check',
          kinds: const {DataKind.image},
          payloadDigest: 'd',
          sessionId: 's1',
        ),
        preview: photoA,
      );
      expect(dialog.previews, [null, photoA, null, null]);
    },
  );
}

class _AllowingDialog extends DialogConsentGate {
  _AllowingDialog()
    : super(navigatorKey: GlobalKey<NavigatorState>(), cloudModel: 'm');
  final previews = <Uint8List?>[];

  @override
  Future<bool> confirm(ConsentAsk ask, {Uint8List? preview}) async {
    previews.add(preview);
    return true;
  }
}

/// The gate grants a frozen copy of the ask: equal fields, not the instance.
Matcher _sameAskAs(ConsentAsk a) => isA<ConsentAsk>()
    .having((x) => x.feature, 'feature', a.feature)
    .having((x) => x.kinds, 'kinds', a.kinds)
    .having((x) => x.payloadDigest, 'payloadDigest', a.payloadDigest)
    .having((x) => x.sessionId, 'sessionId', a.sessionId);

/// Holds its prompt open until [answer] completes, then reads the preview.
class _HeldDialog extends DialogConsentGate {
  _HeldDialog(this.answer)
    : super(navigatorKey: GlobalKey<NavigatorState>(), cloudModel: 'm');
  final Future<bool> answer;
  final shown = <Uint8List?>[];

  @override
  Future<bool> confirm(ConsentAsk ask, {Uint8List? preview}) async {
    final allowed = await answer;
    shown.add(preview == null ? null : Uint8List.fromList(preview));
    return allowed;
  }
}
