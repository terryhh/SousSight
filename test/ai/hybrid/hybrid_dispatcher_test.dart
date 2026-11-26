import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/ai/hybrid/inference_policy.dart';
import 'package:soussight/ai/hybrid/payload_digest.dart';

class _Privacy implements PrivacySettings {
  final Set<String> localOnlyFeatures = {};
  @override
  bool localOnly(String feature) => localOnlyFeatures.contains(feature);
}

class _Consent implements ConsentGate {
  final List<ConsentAsk> asks = [];
  Future<ConsentGrant?> Function(ConsentAsk ask)? answer;
  @override
  Future<ConsentGrant?> request(ConsentAsk ask) {
    asks.add(ask);
    return answer?.call(ask) ?? Future.value(ConsentGrant(ask));
  }
}

class _Adapter implements CloudFallbackSender {
  final List<HybridRequest> requests = [];
  final List<String> cancelled = [];
  final Queue<Object> script = Queue();
  Future<void>? gate;
  @override
  Future<HybridResult> send(HybridRequest request) async {
    requests.add(request);
    if (gate != null) await gate;
    if (cancelled.contains(request.requestId)) {
      throw const HybridException(HybridErrorCode.cancelled, 'cancelled');
    }
    final next = script.isEmpty ? 'adapter answer' : script.removeFirst();
    if (next is HybridException) throw next;
    return HybridResult(
      requestId: request.requestId,
      text: next as String,
      source: InferenceSource.cloud,
    );
  }

  @override
  Future<void> cancel(String requestId) async => cancelled.add(requestId);
}

class _Harness {
  _Harness({
    HybridCapabilities caps = fakeWebCapabilities,
    String routes = 'hybridFallback',
    bool withAdapter = true,
    RemoteRouting? remote,
  }) : bridge = FakeHybridInference(capabilities: caps),
       adapter = withAdapter ? _Adapter() : null {
    var seq = 0;
    dispatcher = DefaultHybridDispatcher(
      inference: bridge,
      privacy: privacy,
      cloudRoutes: CloudRoutes.parse(routes),
      consent: consent,
      ledger: ledger,
      cloudFallback: adapter,
      remoteRouting: () => remote,
      newId: () => 'id-${++seq}',
    );
  }

  final FakeHybridInference bridge;
  final _Adapter? adapter;
  final privacy = _Privacy();
  final consent = _Consent();
  final ledger = InferenceLedger(
    sessionId: 's1',
    clock: () => DateTime.utc(2026, 11, 25),
  );
  late final DefaultHybridDispatcher dispatcher;

  Future<DispatchResult> run(HybridTask task, {ResultValidator? validate}) =>
      dispatcher.start(task, sessionId: 's1', validate: validate).result;
}

HybridTask _text(String feature) => HybridTask(
  feature: feature,
  systemInstruction: 'You help a cook.',
  parts: const [HybridText('eggs, rice, spinach')],
  maxOutputTokens: 256,
  timeout: const Duration(seconds: 10),
);

HybridTask _photo(String feature, [int seed = 1]) => HybridTask(
  feature: feature,
  parts: [
    const HybridText('What is in the photo?'),
    HybridInlineData(Uint8List.fromList([seed, 2, 3]), 'image/jpeg'),
  ],
  maxOutputTokens: 256,
  timeout: const Duration(seconds: 10),
);

String? _rejectAll(String _) => 'not valid';
String? Function(String) _acceptOnly(String good) =>
    (t) => t == good ? null : 'not valid';

Matcher _leg({
  Provenance? provenance,
  HybridMode? mode,
  bool? transfer,
  Object? error = _any,
}) => isA<InferenceLeg>()
    .having((l) => l.provenance, 'provenance', provenance ?? anything)
    .having((l) => l.mode, 'mode', mode ?? anything)
    .having(
      (l) => l.transferPermitted,
      'transferPermitted',
      transfer ?? anything,
    )
    .having((l) => l.error, 'error', identical(error, _any) ? anything : error);

const _any = Object();

void main() {
  test('returns the operation synchronously and runs on-device', () async {
    final h = _Harness();
    h.bridge.enqueueText('local answer');
    final op = h.dispatcher.start(_text('pantry_scan'), sessionId: 's1');
    expect(op.operationId, 'id-1');
    expect(h.bridge.requests, isEmpty);
    final r = await op.result;
    expect(r.text, 'local answer');
    expect(h.bridge.requests.single.mode, HybridMode.preferOnDevice);
    expect(r.legs, [
      _leg(
        provenance: Provenance.sdkOnDevice,
        mode: HybridMode.preferOnDevice,
        transfer: true,
        error: null,
      ),
    ]);
    expect(h.ledger.entries.single.pending, isFalse);
    expect(
      h.consent.asks,
      isEmpty,
      reason: 'text from an on-device-first feature',
    );
  });

  test('writes the leg to the ledger before the bridge is called', () async {
    final h = _Harness();
    late LedgerEntry seen;
    h.bridge.script.add((HybridRequest req) {
      seen = h.ledger.entries.single;
      expect(seen.pending, isTrue);
      expect(seen.leg.requestId, req.requestId);
      expect(seen.leg.provenance, Provenance.unknown);
      expect(seen.leg.transferPermitted, isFalse);
      return const HybridResult(
        requestId: '',
        text: '{}',
        source: InferenceSource.onDevice,
      );
    });
    await h.run(_photo('local_watch'));
    expect(seen.pending, isFalse);
    expect(seen.leg.provenance, Provenance.sdkOnDevice);
  });

  group('bridge blocked', () {
    test('no bridge and no approved cloud route: nothing is sent', () async {
      final h = _Harness(caps: const HybridCapabilities.none(), routes: '');
      h.bridge.textAvailability = const HybridAvailability(
        status: OnDeviceStatus.unavailable,
        reason: 'bridge_unavailable',
      );
      final r = await h.run(_text('pantry_scan'));
      expect(r.text, isNull);
      expect(r.blocked, RouteReason.cloudNotApproved);
      expect(r.legs, isEmpty);
      expect(h.bridge.requests, isEmpty);
      expect(h.adapter!.requests, isEmpty);
      expect(h.ledger.entries, isEmpty);
    });

    test('no bridge, route approved: the Dart cloud adapter sends', () async {
      final h = _Harness(caps: const HybridCapabilities.none());
      h.bridge.textAvailability = const HybridAvailability(
        status: OnDeviceStatus.unavailable,
      );
      final r = await h.run(_text('pantry_scan'));
      expect(r.text, 'adapter answer');
      expect(h.bridge.requests, isEmpty);
      expect(h.adapter!.requests.single.mode, HybridMode.onlyInCloud);
      expect(r.legs, [
        _leg(
          provenance: Provenance.cloudAdapter,
          mode: HybridMode.onlyInCloud,
          transfer: true,
        ),
      ]);
    });

    test('no bridge and no adapter: blocked with the route reason', () async {
      final h = _Harness(
        caps: const HybridCapabilities.none(),
        withAdapter: false,
      );
      h.bridge.textAvailability = const HybridAvailability(
        status: OnDeviceStatus.unavailable,
      );
      final r = await h.run(_text('pantry_scan'));
      expect(r.blocked, RouteReason.noLocalModel);
      expect(r.legs, isEmpty);
    });

    test(
      'no bridge: an on-device-only feature never reaches the adapter',
      () async {
        final h = _Harness(caps: const HybridCapabilities.none());
        h.bridge.imageAvailability = const HybridAvailability(
          status: OnDeviceStatus.unavailable,
        );
        final r = await h.run(_photo('local_watch'));
        expect(r.blocked, RouteReason.noLocalModel);
        expect(h.adapter!.requests, isEmpty);
      },
    );
  });

  group('availability changing between preflight and send', () {
    test(
      'preferOnDevice: the SDK answers from the cloud and the leg says so',
      () async {
        final h = _Harness();
        h.bridge.script.add((HybridRequest req) {
          h.bridge.textAvailability = const HybridAvailability(
            status: OnDeviceStatus.unavailable,
          );
          return const HybridResult(
            requestId: '',
            text: 'cloud answer',
            source: InferenceSource.cloud,
          );
        });
        final r = await h.run(_text('recipe_draft'));
        expect(r.text, 'cloud answer');
        expect(r.legs, [
          _leg(
            provenance: Provenance.sdkCloud,
            mode: HybridMode.preferOnDevice,
            transfer: true,
          ),
        ]);
        expect(h.ledger.reportedSent, hasLength(1));
      },
    );

    test('onlyOnDevice: the model vanishes, the request fails, nothing goes to the cloud', () async {
      final h = _Harness();
      h.bridge.script.add(
        const HybridException(HybridErrorCode.unavailable, 'model_not_ready'),
      );
      final r = await h.run(_photo('local_watch'), validate: _rejectAll);
      expect(r.text, isNull);
      expect(r.legs, [
        _leg(
          provenance: Provenance.unknown,
          mode: HybridMode.onlyOnDevice,
          transfer: false,
          error: HybridErrorCode.unavailable,
        ),
      ]);
      expect(h.bridge.requests, hasLength(1));
      expect(h.adapter!.requests, isEmpty);
      expect(h.consent.asks, isEmpty);
    });
  });

  group('consent', () {
    test('declined: nothing is sent', () async {
      final h = _Harness(caps: fakeIosCapabilities);
      h.consent.answer = (_) async => null;
      final task = _photo('pantry_scan');
      final r = await h.run(task);
      expect(r.blocked, RouteReason.consentDeclined);
      expect(r.legs, isEmpty);
      expect(h.bridge.requests, isEmpty);
      expect(h.adapter!.requests, isEmpty);
      final ask = h.consent.asks.single;
      expect(ask.payloadDigest, hybridPayloadDigest(task));
      expect(ask.sessionId, 's1');
      expect(ask.kinds, {DataKind.text, DataKind.image});
    });

    test('a grant for another payload or session does not count', () async {
      final h = _Harness(caps: fakeIosCapabilities);
      final other = _photo('pantry_scan', 9);
      h.consent.answer = (ask) async => ConsentGrant(
        ConsentAsk(
          feature: ask.feature,
          kinds: ask.kinds,
          payloadDigest: hybridPayloadDigest(other),
          sessionId: 's1',
        ),
      );
      expect(
        (await h.run(_photo('pantry_scan'))).blocked,
        RouteReason.consentDeclined,
      );
      h.consent.answer = (ask) async => ConsentGrant(
        ConsentAsk(
          feature: ask.feature,
          kinds: ask.kinds,
          payloadDigest: ask.payloadDigest,
          sessionId: 's2',
        ),
      );
      expect(
        (await h.run(_photo('pantry_scan'))).blocked,
        RouteReason.consentDeclined,
      );
      expect(h.bridge.requests, isEmpty);
    });

    test('granted: iOS photo goes onlyInCloud through the bridge', () async {
      final h = _Harness(caps: fakeIosCapabilities);
      h.bridge.enqueueText('{"items":[]}', source: InferenceSource.cloud);
      final r = await h.run(_photo('pantry_scan'));
      expect(r.text, isNotNull);
      expect(h.bridge.requests.single.mode, HybridMode.onlyInCloud);
      expect(r.legs.single.provenance, Provenance.sdkCloud);
    });

    test('privacy setting flipped while the consent prompt is open', () async {
      final h = _Harness(caps: fakeIosCapabilities);
      final prompt = Completer<ConsentGrant?>();
      h.consent.answer = (_) => prompt.future;
      final result = h.run(_photo('pantry_scan'));
      await pumpEventQueue();
      expect(h.consent.asks, hasLength(1));
      h.privacy.localOnlyFeatures.add('pantry_scan');
      prompt.complete(ConsentGrant(h.consent.asks.single));
      final r = await result;
      expect(r.blocked, RouteReason.localOnlySetting);
      expect(h.bridge.requests, isEmpty);
      expect(h.ledger.entries, isEmpty);
    });

    test('a grant is used once: the retry needs a fresh one', () async {
      final h = _Harness();
      ConsentGrant? first;
      h.consent.answer = (ask) async => first ??= ConsentGrant(ask);
      h.bridge.enqueueText('bad');
      final r = await h.run(_photo('pantry_scan'), validate: _rejectAll);
      expect(h.consent.asks, hasLength(2));
      expect(r.blocked, RouteReason.consentDeclined);
      expect(h.bridge.requests, hasLength(1));
      expect(
        r.legs.last,
        _leg(transfer: false, error: HybridErrorCode.blocked),
      );
    });
  });

  group('payload snapshot (Codex P1)', () {
    test('mutating the caller\'s task while consent is pending changes nothing', () async {
      final h = _Harness(caps: fakeIosCapabilities);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final schema = <String, Object?>{
        'type': 'object',
        'required': <Object?>['items'],
      };
      final parts = <HybridPart>[
        const HybridText('What is in the photo?'),
        HybridInlineData(bytes, 'image/jpeg'),
      ];
      final task = HybridTask(
        feature: 'pantry_scan',
        parts: parts,
        jsonSchema: schema,
        maxOutputTokens: 256,
        timeout: const Duration(seconds: 10),
      );
      final original = hybridPayloadDigest(task);
      final prompt = Completer<ConsentGrant?>();
      h.consent.answer = (_) => prompt.future;
      h.bridge.enqueueText('{}', source: InferenceSource.cloud);
      final result = h.run(task);
      await pumpEventQueue();
      expect(h.consent.asks.single.payloadDigest, original);

      // The caller changes everything while the cook is looking at the prompt.
      bytes[0] = 99;
      parts.add(const HybridText('and also this'));
      schema['type'] = 'array';
      (schema['required']! as List).add('meals');
      expect(hybridPayloadDigest(task), isNot(original));

      prompt.complete(ConsentGrant(h.consent.asks.single));
      final r = await result;
      expect(r.text, isNotNull);
      final sent = h.bridge.requests.single.task;
      expect(
        hybridPayloadDigest(sent),
        original,
        reason: 'what was sent is what the cook approved',
      );
      expect((sent.parts[1] as HybridInlineData).bytes, [1, 2, 3]);
      expect(sent.parts, hasLength(2));
      expect(sent.jsonSchema, {
        'type': 'object',
        'required': ['items'],
      });
    });

    test('snapshotTask copies bytes, parts and nested schema', () {
      final bytes = Uint8List.fromList([5]);
      final task = HybridTask(
        feature: 'f',
        parts: [HybridInlineData(bytes, 'image/png')],
        jsonSchema: {
          'properties': {
            'a': {
              'enum': ['x'],
            },
          },
        },
        maxOutputTokens: 1,
        timeout: const Duration(seconds: 1),
      );
      final copy = snapshotTask(task);
      bytes[0] = 6;
      expect((copy.parts.single as HybridInlineData).bytes, [5]);
      expect(
        () => copy.parts.add(const HybridText('x')),
        throwsUnsupportedError,
      );
      final enumList =
          ((copy.jsonSchema!['properties'] as Map)['a'] as Map)['enum'] as List;
      expect(() => enumList.add('y'), throwsUnsupportedError);
      expect(hybridPayloadDigest(copy), isNot(hybridPayloadDigest(task)));
    });
  });

  test(
    'a watch cloud check honours the parent local_watch local-only setting',
    () async {
      final h = _Harness();
      h.privacy.localOnlyFeatures.add('local_watch');
      final r = await h.run(_photo('local_watch_cloud_check'));
      expect(r.blocked, RouteReason.localOnlySetting);
      expect(h.consent.asks, isEmpty);
      expect(h.bridge.requests, isEmpty);
    },
  );

  test('the parent local-only setting flipped during the consent prompt blocks the send', () async {
    final h = _Harness();
    final prompt = Completer<ConsentGrant?>();
    h.consent.answer = (_) => prompt.future;
    final result = h.run(_photo('local_watch_cloud_check'));
    await pumpEventQueue();
    h.privacy.localOnlyFeatures.add('local_watch');
    prompt.complete(ConsentGrant(h.consent.asks.single));
    expect((await result).blocked, RouteReason.localOnlySetting);
    expect(h.bridge.requests, isEmpty);
  });

  test('remote routing cannot widen local_watch to preferOnDevice', () async {
    final h = _Harness(
      remote: const RemoteRouting(
        modes: {'local_watch': HybridMode.preferOnDevice},
      ),
    );
    h.bridge.enqueueText('{}');
    final r = await h.run(_photo('local_watch'));
    expect(h.bridge.requests.single.mode, HybridMode.onlyOnDevice);
    expect(r.legs.single.transferPermitted, isFalse);
  });

  group('a grant supplied by the feature', () {
    test(
      'matching digest and session: used without asking the cook again',
      () async {
        final h = _Harness();
        final task = _photo('local_watch_cloud_check');
        final grant = ConsentGrant(
          ConsentAsk(
            feature: 'local_watch',
            kinds: const {DataKind.image},
            payloadDigest: hybridPayloadDigest(task),
            sessionId: 's1',
          ),
        );
        h.bridge.enqueueText(
          '{"state":"ready"}',
          source: InferenceSource.cloud,
        );
        final r = await h.dispatcher
            .start(task, sessionId: 's1', grant: grant)
            .result;
        expect(r.text, isNotNull);
        expect(h.consent.asks, isEmpty);
        expect(h.bridge.requests.single.mode, HybridMode.onlyInCloud);

        // Used once: the same grant on a second operation is not accepted.
        h.consent.answer = (_) async => null;
        final again = await h.dispatcher
            .start(task, sessionId: 's1', grant: grant)
            .result;
        expect(again.blocked, RouteReason.consentDeclined);
        expect(h.consent.asks, hasLength(1));
        expect(h.bridge.requests, hasLength(1));
      },
    );

    test(
      'a grant for another frame or session is ignored and the gate asked',
      () async {
        final h = _Harness();
        final task = _photo('local_watch_cloud_check');
        h.consent.answer = (_) async => null;
        for (final g in [
          ConsentGrant(
            ConsentAsk(
              feature: 'local_watch',
              kinds: const {DataKind.image},
              payloadDigest: hybridPayloadDigest(
                _photo('local_watch_cloud_check', 7),
              ),
              sessionId: 's1',
            ),
          ),
          ConsentGrant(
            ConsentAsk(
              feature: 'local_watch',
              kinds: const {DataKind.image},
              payloadDigest: hybridPayloadDigest(task),
              sessionId: 'other',
            ),
          ),
        ]) {
          final r = await h.dispatcher
              .start(task, sessionId: 's1', grant: g)
              .result;
          expect(r.blocked, RouteReason.consentDeclined);
        }
        expect(h.consent.asks, hasLength(2));
        expect(h.bridge.requests, isEmpty);
      },
    );
  });

  test(
    'onlyOnDevice while the image model is only downloadable: not sent',
    () async {
      final h = _Harness();
      h.bridge.imageAvailability = const HybridAvailability(
        status: OnDeviceStatus.downloadable,
      );
      final r = await h.run(_photo('local_watch'));
      expect(r.blocked, RouteReason.modelNotReady);
      expect(h.bridge.requests, isEmpty);
      // Availability is per modality: text is still ready and runs locally.
      h.bridge.enqueueText('ok');
      expect((await h.run(_text('coach_lite'))).text, 'ok');
    },
  );

  test(
    'localOnly with a remote override set to cloud stays on-device',
    () async {
      for (final mode in [HybridMode.onlyInCloud, HybridMode.preferOnDevice]) {
        final h = _Harness(remote: RemoteRouting(modes: {'pantry_scan': mode}));
        h.privacy.localOnlyFeatures.add('pantry_scan');
        h.bridge.enqueueText('local');
        final r = await h.run(_photo('pantry_scan'));
        expect(h.bridge.requests.single.mode, HybridMode.onlyOnDevice);
        expect(r.legs.single.transferPermitted, isFalse);
        expect(h.consent.asks, isEmpty);
      }
    },
  );

  group('semantic retry', () {
    test(
      'a rejected on-device answer is retried once onlyInCloud and validated',
      () async {
        final h = _Harness();
        h.bridge
          ..enqueueText('bad')
          ..enqueueText('good', source: InferenceSource.cloud);
        final r = await h.run(
          _text('recipe_draft'),
          validate: _acceptOnly('good'),
        );
        expect(r.text, 'good');
        expect(h.bridge.requests.map((q) => q.mode), [
          HybridMode.preferOnDevice,
          HybridMode.onlyInCloud,
        ]);
        expect(r.legs, [
          _leg(provenance: Provenance.sdkOnDevice),
          _leg(
            provenance: Provenance.sdkCloud,
            mode: HybridMode.onlyInCloud,
            transfer: true,
          ),
        ]);
      },
    );

    test('the retry is validated too, and there is only one', () async {
      final h = _Harness();
      h.bridge
        ..enqueueText('bad')
        ..enqueueText('still bad', source: InferenceSource.cloud);
      final r = await h.run(_text('coach_lite'), validate: _rejectAll);
      expect(r.text, isNull);
      expect(h.bridge.requests, hasLength(2));
      expect(h.bridge.requests.first.mode, HybridMode.onlyOnDevice);
    });

    test('blocked by localOnly turned on during the first send', () async {
      final h = _Harness();
      h.bridge.script.add((HybridRequest _) {
        h.privacy.localOnlyFeatures.add('recipe_draft');
        return const HybridResult(
          requestId: '',
          text: 'bad',
          source: InferenceSource.onDevice,
        );
      });
      final r = await h.run(_text('recipe_draft'), validate: _rejectAll);
      expect(r.text, isNull);
      expect(r.blocked, RouteReason.localOnlySetting);
      expect(h.bridge.requests, hasLength(1));
      expect(r.legs, [
        _leg(provenance: Provenance.sdkOnDevice),
        _leg(
          mode: HybridMode.onlyInCloud,
          transfer: false,
          error: HybridErrorCode.blocked,
        ),
      ]);
      expect(
        h.ledger.allowedToLeave,
        hasLength(1),
        reason: 'only the first, preferOnDevice leg',
      );
    });

    test('blocked when cloud routes are not approved', () async {
      final h = _Harness(routes: '');
      h.bridge.enqueueText('bad');
      final r = await h.run(_text('recipe_draft'), validate: _rejectAll);
      expect(r.blocked, RouteReason.cloudNotApproved);
      expect(h.bridge.requests.single.mode, HybridMode.onlyOnDevice);
    });

    test('no retry when the SDK already answered from the cloud', () async {
      final h = _Harness();
      h.bridge.enqueueText('bad', source: InferenceSource.cloud);
      final r = await h.run(_text('recipe_draft'), validate: _rejectAll);
      expect(r.text, isNull);
      expect(h.bridge.requests, hasLength(1));
    });

    test('no retry for an on-device-only feature', () async {
      final h = _Harness();
      h.bridge.enqueueText('bad');
      await h.run(_photo('local_watch'), validate: _rejectAll);
      expect(h.bridge.requests, hasLength(1));
      expect(h.consent.asks, isEmpty);
    });

    test('transport errors are not retried this way', () async {
      final h = _Harness();
      h.bridge.script.add(const HybridException(HybridErrorCode.busy, 'busy'));
      final r = await h.run(_text('recipe_draft'), validate: _rejectAll);
      expect(r.text, isNull);
      expect(h.bridge.requests, hasLength(1));
      expect(h.adapter!.requests, isEmpty);
    });
  });

  group('cancel', () {
    test(
      'during the send: plugin cancel is called, no fallback, no retry',
      () async {
        final h = _Harness();
        final release = Completer<void>();
        h.bridge
          ..enqueueText('bad')
          ..enqueueText('good', source: InferenceSource.cloud);
        final slow = _SlowBridge(h.bridge, release.future, forwardCancel: true);
        final d = DefaultHybridDispatcher(
          inference: slow,
          privacy: h.privacy,
          cloudRoutes: CloudRoutes.parse('hybridFallback'),
          consent: h.consent,
          ledger: h.ledger,
          cloudFallback: h.adapter,
        );
        final op = d.start(
          _text('recipe_draft'),
          sessionId: 's1',
          validate: _acceptOnly('good'),
        );
        await pumpEventQueue();
        expect(slow.started, hasLength(1));
        op.cancel();
        release.complete();
        final r = await op.result;
        expect(r.blocked, RouteReason.cancelled);
        expect(r.text, isNull);
        expect(h.bridge.cancelled, [slow.started.single]);
        expect(slow.started, hasLength(1));
        expect(h.adapter!.requests, isEmpty);
        expect(r.legs.single.error, HybridErrorCode.cancelled);
      },
    );

    test(
      'a late success after cancel is recorded but never returned or retried',
      () async {
        final h = _Harness();
        final release = Completer<void>();
        h.bridge.script.add(
          (HybridRequest _) => const HybridResult(
            requestId: '',
            text: 'bad',
            source: InferenceSource.onDevice,
          ),
        );
        h.bridge.script.add(
          (HybridRequest _) => const HybridResult(
            requestId: '',
            text: 'good',
            source: InferenceSource.cloud,
          ),
        );
        final slow = _SlowBridge(h.bridge, release.future);
        var seq = 0;
        final d = DefaultHybridDispatcher(
          inference: slow,
          privacy: h.privacy,
          cloudRoutes: CloudRoutes.parse('hybridFallback'),
          consent: h.consent,
          ledger: h.ledger,
          newId: () => 'x-${++seq}',
        );
        final op = d.start(
          _text('recipe_draft'),
          sessionId: 's1',
          validate: _acceptOnly('good'),
        );
        await pumpEventQueue();
        op.cancel();
        release.complete();
        final r = await op.result;
        expect(r.blocked, RouteReason.cancelled);
        expect(r.text, isNull);
        expect(h.bridge.requests, hasLength(1));
        expect(r.legs.single.provenance, Provenance.sdkOnDevice);
      },
    );

    test('during the adapter send: adapter cancel is called', () async {
      final h = _Harness(caps: const HybridCapabilities.none());
      h.bridge.textAvailability = const HybridAvailability(
        status: OnDeviceStatus.unavailable,
      );
      final release = Completer<void>();
      h.adapter!.gate = release.future;
      final op = h.dispatcher.start(_text('pantry_scan'), sessionId: 's1');
      await pumpEventQueue();
      op.cancel();
      release.complete();
      final r = await op.result;
      expect(r.blocked, RouteReason.cancelled);
      expect(h.adapter!.cancelled, [h.adapter!.requests.single.requestId]);
    });

    test('before the first send: nothing is sent', () async {
      final h = _Harness();
      h.bridge.enqueueText('x');
      final op = h.dispatcher.start(_text('pantry_scan'), sessionId: 's1')
        ..cancel();
      expect((await op.result).blocked, RouteReason.cancelled);
      expect(h.bridge.requests, isEmpty);
    });
  });

  group('outcomes', () {
    test(
      'an error on a send allowed to upload is recorded as unknown',
      () async {
        final h = _Harness();
        h.bridge.script.add(
          const HybridException(HybridErrorCode.network, 'offline'),
        );
        final r = await h.run(_text('pantry_scan'));
        expect(r.text, isNull);
        expect(r.blocked, isNull);
        expect(
          r.legs.single,
          _leg(
            provenance: Provenance.unknown,
            transfer: true,
            error: HybridErrorCode.network,
          ),
        );
        expect(h.ledger.entries.single.uploadUnknown, isTrue);
      },
    );

    test(
      'unsupportedInput on a cloud-only photo goes to the adapter, one consent',
      () async {
        final h = _Harness(caps: fakeIosCapabilities);
        h.bridge.script.add(
          const HybridException(
            HybridErrorCode.unsupportedInput,
            'no attachment',
          ),
        );
        final r = await h.run(_photo('pantry_scan'));
        expect(r.text, 'adapter answer');
        expect(h.consent.asks, hasLength(1));
        expect(r.legs, [
          _leg(
            mode: HybridMode.onlyInCloud,
            error: HybridErrorCode.unsupportedInput,
          ),
          _leg(
            provenance: Provenance.cloudAdapter,
            mode: HybridMode.onlyInCloud,
            error: null,
          ),
        ]);
      },
    );

    test('the adapter fallback re-checks localOnly', () async {
      final h = _Harness(caps: fakeIosCapabilities);
      h.bridge.script.add((HybridRequest _) {
        h.privacy.localOnlyFeatures.add('pantry_scan');
        throw const HybridException(
          HybridErrorCode.unsupportedInput,
          'no attachment',
        );
      });
      final r = await h.run(_photo('pantry_scan'));
      expect(r.blocked, RouteReason.localOnlySetting);
      expect(h.adapter!.requests, isEmpty);
    });

    test(
      'a backend that widens onlyOnDevice is recorded honestly and not used',
      () async {
        final h = _Harness();
        h.bridge.enqueueText('from cloud', source: InferenceSource.cloud);
        final r = await h.run(_photo('local_watch'));
        expect(r.text, isNull);
        expect(
          r.legs.single,
          _leg(provenance: Provenance.sdkCloud, error: HybridErrorCode.failed),
        );
      },
    );

    test(
      'a validator rejection on a cloud-adapter answer is not retried',
      () async {
        final h = _Harness(caps: const HybridCapabilities.none());
        h.bridge.textAvailability = const HybridAvailability(
          status: OnDeviceStatus.unavailable,
        );
        final r = await h.run(_text('recipe_draft'), validate: _rejectAll);
        expect(r.text, isNull);
        expect(h.adapter!.requests, hasLength(1));
      },
    );
  });

  group('payloads that rule out a local run do not wait for availability', () {
    DefaultHybridDispatcher dispatcher(
      HybridInference bridge, {
      _Privacy? privacy,
      String routes = 'hybridFallback',
    }) => DefaultHybridDispatcher(
      inference: bridge,
      privacy: privacy ?? _Privacy(),
      cloudRoutes: CloudRoutes.parse(routes),
      consent: _Consent(),
      ledger: InferenceLedger(sessionId: 's1'),
      newId: () => 'id-1',
    );

    HybridTask voice() => HybridTask(
      feature: 'pantry_voice',
      parts: [
        const HybridText('What did I say?'),
        HybridInlineData(Uint8List.fromList([1, 2, 3]), 'audio/wav'),
      ],
      maxOutputTokens: 256,
      timeout: const Duration(seconds: 10),
    );

    test('audio goes to the cloud without asking for local status', () async {
      final bridge = _StalledAvailability(
        FakeHybridInference(capabilities: fakeIosCapabilities)
          ..enqueueText('two eggs'),
      );
      final r = await dispatcher(bridge)
          .start(voice(), sessionId: 's1')
          .result
          .timeout(const Duration(seconds: 2));
      expect(bridge.asked, 0);
      expect(r.text, 'two eggs');
      expect(bridge.inner.requests.single.mode, HybridMode.onlyInCloud);
    });

    test('send-time privacy still blocks the audio send', () async {
      final bridge = _StalledAvailability(
        FakeHybridInference(capabilities: fakeIosCapabilities),
      );
      final privacy = _Privacy()..localOnlyFeatures.add('pantry_voice');
      final r = await dispatcher(bridge, privacy: privacy)
          .start(voice(), sessionId: 's1')
          .result
          .timeout(const Duration(seconds: 2));
      expect(bridge.asked, 0);
      expect(r.blocked, RouteReason.localOnlySetting);
      expect(bridge.inner.requests, isEmpty);

      final unapproved = await dispatcher(bridge, routes: '')
          .start(voice(), sessionId: 's1')
          .result
          .timeout(const Duration(seconds: 2));
      expect(unapproved.blocked, RouteReason.cloudNotApproved);
      expect(bridge.inner.requests, isEmpty);
    });

    test('a text request that could run locally still waits for status', () {
      final bridge = _StalledAvailability(
        FakeHybridInference(capabilities: fakeIosCapabilities),
      );
      dispatcher(bridge).start(_text('recipe_draft'), sessionId: 's1');
      return pumpEventQueue().then((_) {
        expect(bridge.asked, 1);
        expect(bridge.inner.requests, isEmpty);
      });
    });

    test('a cloud-only feature does not wait either', () async {
      final bridge = _StalledAvailability(
        FakeHybridInference(capabilities: fakeWebCapabilities)
          ..enqueueText('{"changed":false}'),
      );
      final r = await dispatcher(bridge)
          .start(_photo('local_watch_cloud_check'), sessionId: 's1')
          .result
          .timeout(const Duration(seconds: 2));
      expect(bridge.asked, 0);
      expect(r.text, '{"changed":false}');
      expect(bridge.inner.requests.single.mode, HybridMode.onlyInCloud);
    });

    test(
      'the parent local-only setting still blocks the cloud check',
      () async {
        final bridge = _StalledAvailability(
          FakeHybridInference(capabilities: fakeWebCapabilities),
        );
        final privacy = _Privacy()..localOnlyFeatures.add('local_watch');
        final r = await dispatcher(bridge, privacy: privacy)
            .start(_photo('local_watch_cloud_check'), sessionId: 's1')
            .result
            .timeout(const Duration(seconds: 2));
        expect(bridge.asked, 0);
        expect(r.blocked, isNotNull);
        expect(bridge.inner.requests, isEmpty);
      },
    );
  });
}

/// Availability never answers (a cold Android check stuck in its probe);
/// counts how often it was asked.
class _StalledAvailability extends _SlowBridge {
  _StalledAvailability(FakeHybridInference inner)
    : super(inner, Future<void>.value(), forwardCancel: true);
  int asked = 0;
  @override
  Future<HybridAvailability> availability({required bool withImage}) {
    asked++;
    return Completer<HybridAvailability>().future;
  }
}

/// Holds every generate until [gate] completes. Without [forwardCancel] it
/// ignores cancel, so a result can arrive after the operation was cancelled.
class _SlowBridge implements HybridInference {
  _SlowBridge(this.inner, this.gate, {this.forwardCancel = false});
  final FakeHybridInference inner;
  final Future<void> gate;
  final bool forwardCancel;
  final List<String> started = [];
  @override
  Future<void> configure(HybridConfig config) => inner.configure(config);
  @override
  Future<HybridCapabilities> capabilities() => inner.capabilities();
  @override
  Future<HybridAvailability> availability({required bool withImage}) =>
      inner.availability(withImage: withImage);
  @override
  Stream<double?> prepare({required bool withImage}) =>
      inner.prepare(withImage: withImage);
  @override
  Future<HybridResult> generate(HybridRequest request) async {
    started.add(request.requestId);
    await gate;
    return inner.generate(request);
  }

  @override
  Future<void> cancel(String requestId) async {
    if (forwardCancel) await inner.cancel(requestId);
  }
}
