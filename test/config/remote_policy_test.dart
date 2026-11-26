// Remote Config policy (SS-076) against a fake source only. No Firebase or
// network call is made; these tests do not show a live Remote Config fetch.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/ai/hybrid/inference_policy.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/config/remote_policy.dart';

class _FakeSource implements RemoteConfigSource {
  _FakeSource({
    Map<String, String>? remote,
    this.fetch,
    this.configureError,
    this.readError,
  }) : remote = remote ?? {};

  /// Values that become active once a fetch completes.
  final Map<String, String> remote;
  Future<void> Function()? fetch;
  Object? configureError;
  Object? readError;

  Map<String, Object> defaults = {};
  Duration? fetchTimeout;
  bool activated = false;

  @override
  Future<void> configure({
    required Duration fetchTimeout,
    required Duration minimumFetchInterval,
    required Map<String, Object> defaults,
  }) async {
    if (configureError case final e?) throw e;
    this.fetchTimeout = fetchTimeout;
    this.defaults = defaults;
  }

  @override
  Future<void> fetchAndActivate() async {
    await fetch?.call();
    activated = true;
  }

  @override
  String getString(String key) {
    if (readError case final e?) throw e;
    if (activated && remote.containsKey(key)) return remote[key]!;
    return '${defaults[key] ?? ''}';
  }
}

Future<RemotePolicy> _load(
  _FakeSource source, {
  Set<String> allowed = const {},
}) => RemotePolicy.load(
  source,
  compiledCloudModel: 'compiled-model',
  allowedCloudModels: allowed,
);

RouteInput _input(
  String feature, {
  bool localOnly = false,
  bool cloudApproved = true,
  RemoteRouting? remote,
}) => RouteInput(
  feature: feature,
  estimatedTokens: 100,
  languageTag: 'en',
  localOnly: localOnly,
  online: true,
  cloudApproved: cloudApproved,
  capabilities: fakeWebCapabilities,
  status: OnDeviceStatus.available,
  remote: remote,
);

/// configure() completes only when the test says so (a slow bridge).
class _SlowConfigure extends FakeHybridInference {
  final gate = Completer<void>();
  @override
  Future<void> configure(HybridConfig config) async {
    await gate.future;
    this.config = config;
  }
}

class _Privacy implements PrivacySettings {
  final Set<String> local = {};
  @override
  bool localOnly(String feature) => local.contains(feature);
}

class _AllowConsent extends ConsentGate {
  @override
  Future<bool> confirm(ConsentAsk ask, {Uint8List? preview}) async => true;
}

void main() {
  group('defaults', () {
    test('ship in the app for every feature', () {
      final defaults = remoteConfigDefaults();
      expect(defaults[RemoteKeys.hybridEnabled], true);
      expect(defaults[RemoteKeys.cloudModel], '');
      for (final feature in featureRoutes.keys) {
        expect(defaults[RemoteKeys.mode(feature)], '');
      }
    });

    test('a fetch that fails leaves the defaults in force', () async {
      final source = _FakeSource(
        remote: {RemoteKeys.hybridEnabled: 'false'},
        fetch: () async => throw StateError('offline'),
      );
      final policy = await _load(source);
      expect(policy.fetched, isFalse);
      expect(policy.hybridEnabled, isTrue);
      expect(policy.routing().modes, isEmpty);
      expect(policy.cloudModel, 'compiled-model');
      expect(source.defaults, remoteConfigDefaults());
    });

    test('an unconfigured backend (configure and reads throw) is '
        'defaults, not a crash', () async {
      final source = _FakeSource(
        configureError: StateError('no Firebase app'),
        readError: StateError('no Firebase app'),
      );
      final policy = await _load(source);
      expect(policy.fetched, isFalse);
      expect(policy.hybridEnabled, isTrue);
      expect(policy.routing().modes, isEmpty);
      expect(policy.cloudModel, 'compiled-model');
      final routes = policy.gate(
        const CloudRoutes({CloudRoute.hybridFallback}),
      );
      expect(routes.allows(CloudRoute.hybridFallback), isTrue);
    });

    test('a fetch that hangs never blocks startup past 2 s', () {
      fakeAsync((async) {
        final never = Completer<void>();
        final source = _FakeSource(
          remote: {RemoteKeys.hybridEnabled: 'false'},
          fetch: () => never.future,
        );
        RemotePolicy? policy;
        unawaited(_load(source).then((p) => policy = p));
        async.elapse(const Duration(milliseconds: 1999));
        expect(policy, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(policy, isNotNull);
        expect(policy!.fetched, isFalse);
        expect(policy!.hybridEnabled, isTrue);
        expect(source.fetchTimeout, const Duration(seconds: 2));
      });
    });

    test('RemotePolicy.defaults reads nothing', () {
      final policy = RemotePolicy.defaults(compiledCloudModel: 'm');
      expect(policy.cloudModel, 'm');
      expect(policy.hybridEnabled, isTrue);
      expect(policy.routing().modes, isEmpty);
    });
  });

  group('per-feature modes', () {
    test('parse mode names and drop unknown values', () async {
      final policy = await _load(
        _FakeSource(
          remote: {
            RemoteKeys.mode('pantry_scan'): 'onlyOnDevice',
            RemoteKeys.mode('label_check'): ' preferOnDevice ',
            RemoteKeys.mode('recipe_draft'): 'turbo',
            RemoteKeys.mode('not_a_feature'): 'onlyOnDevice',
          },
        ),
      );
      expect(policy.routing().modes, {
        'pantry_scan': HybridMode.onlyOnDevice,
        'label_check': HybridMode.preferOnDevice,
      });
    });

    test('a remote value can tighten a feature to on-device only', () async {
      final policy = await _load(
        _FakeSource(remote: {RemoteKeys.mode('pantry_scan'): 'onlyOnDevice'}),
      );
      expect(
        decideRoute(_input('pantry_scan')).mode,
        HybridMode.preferOnDevice,
      );
      final decision = decideRoute(
        _input('pantry_scan', remote: policy.routing()),
      );
      expect(decision.mode, HybridMode.onlyOnDevice);
      expect(decision.mayUpload, isFalse);
    });

    test(
      'a cloud-primary remote value never sends a feature to the cloud',
      () async {
        final policy = await _load(
          _FakeSource(
            remote: {
              RemoteKeys.mode('coach_lite'): 'onlyInCloud',
              RemoteKeys.mode('local_watch'): 'preferInCloud',
            },
          ),
        );
        for (final feature in ['coach_lite', 'local_watch']) {
          final decision = decideRoute(
            _input(feature, remote: policy.routing()),
          );
          expect(decision.mode, HybridMode.onlyOnDevice, reason: feature);
          expect(decision.mayUpload, isFalse, reason: feature);
        }
      },
    );

    test(
      'local-only and an unapproved cloud route win over Remote Config',
      () async {
        final policy = await _load(
          _FakeSource(
            remote: {
              RemoteKeys.mode('label_check'): 'preferOnDevice',
              RemoteKeys.mode('pantry_scan'): 'onlyInCloud',
            },
          ),
        );
        for (final feature in ['label_check', 'pantry_scan']) {
          for (final input in [
            _input(feature, localOnly: true, remote: policy.routing()),
            _input(feature, cloudApproved: false, remote: policy.routing()),
          ]) {
            final decision = decideRoute(input);
            expect(decision.mode, HybridMode.onlyOnDevice, reason: feature);
            expect(decision.mayUpload, isFalse, reason: feature);
          }
        }
      },
    );
  });

  group('hybrid_enabled kill switch', () {
    const compiled = CloudRoutes({
      CloudRoute.hybridFallback,
      CloudRoute.research,
    });

    test('off removes hybrid fallback only', () async {
      final policy = await _load(
        _FakeSource(remote: {RemoteKeys.hybridEnabled: 'false'}),
      );
      final routes = policy.gate(compiled);
      expect(routes.allows(CloudRoute.hybridFallback), isFalse);
      expect(routes.allows(CloudRoute.research), isTrue);
    });

    test('on never adds a route the build did not approve', () async {
      final policy = await _load(
        _FakeSource(remote: {RemoteKeys.hybridEnabled: 'true'}),
      );
      final routes = policy.gate(const CloudRoutes({}));
      for (final route in CloudRoute.values) {
        expect(routes.allows(route), isFalse, reason: route.name);
      }
    });

    test('an unrecognised value is off (the cautious side)', () async {
      for (final raw in ['nope', 'FALSE', '0', 'disabled']) {
        final policy = await _load(
          _FakeSource(remote: {RemoteKeys.hybridEnabled: raw}),
        );
        expect(policy.hybridEnabled, isFalse, reason: raw);
      }
      for (final raw in ['true', 'TRUE', '1', 'on', 'yes']) {
        final policy = await _load(
          _FakeSource(remote: {RemoteKeys.hybridEnabled: raw}),
        );
        expect(policy.hybridEnabled, isTrue, reason: raw);
      }
    });

    test('is read live: a value activated after startup applies to the '
        'next send', () async {
      final late = Completer<void>();
      final source = _FakeSource(
        remote: {RemoteKeys.hybridEnabled: 'false'},
        fetch: () => late.future,
      );
      final policy = await RemotePolicy.load(
        source,
        compiledCloudModel: 'compiled-model',
        timeout: const Duration(milliseconds: 10),
      );
      final routes = policy.gate(compiled);
      expect(routes.allows(CloudRoute.hybridFallback), isTrue);
      late.complete();
      await Future<void>.delayed(Duration.zero);
      expect(routes.allows(CloudRoute.hybridFallback), isFalse);
    });

    test('through the real dispatcher, off keeps a preferOnDevice feature '
        'on the device, including the semantic retry', () async {
      final inference = FakeHybridInference()..enqueueText('not valid');
      final policy = await _load(
        _FakeSource(remote: {RemoteKeys.hybridEnabled: 'false'}),
      );
      final dispatcher = DefaultHybridDispatcher(
        inference: inference,
        privacy: _Privacy(),
        cloudRoutes: policy.gate(
          const CloudRoutes({CloudRoute.hybridFallback}),
        ),
        consent: _AllowConsent(),
        ledger: InferenceLedger(sessionId: 's'),
        remoteRouting: policy.routing,
      );
      final result = await dispatcher
          .start(
            HybridTask(
              feature: 'recipe_draft',
              parts: const [HybridText('Draft a recipe')],
              maxOutputTokens: 64,
              timeout: const Duration(seconds: 5),
            ),
            sessionId: 's',
            validate: (_) => 'rejected',
          )
          .result;
      expect(inference.requests.single.mode, HybridMode.onlyOnDevice);
      // The blocked retry is recorded, but nothing was allowed to leave.
      expect(result.legs, isNotEmpty);
      expect(result.legs.every((leg) => !leg.transferPermitted), isTrue);
      expect(result.text, isNull);
    });
  });

  group('cloud model id', () {
    test('empty or the compiled id uses the compiled model', () async {
      for (final raw in ['', '  ', 'compiled-model']) {
        final policy = await _load(
          _FakeSource(remote: {RemoteKeys.cloudModel: raw}),
          allowed: {'gemini-x'},
        );
        expect(policy.cloudModel, 'compiled-model');
      }
    });

    test('a model the build allowlists is used', () async {
      final policy = await _load(
        _FakeSource(remote: {RemoteKeys.cloudModel: 'gemini-x'}),
        allowed: {'gemini-x'},
      );
      expect(policy.cloudModel, 'gemini-x');
    });

    test('a model the build does not allowlist is ignored', () async {
      for (final raw in ['gemini-paid', 'Gemini X', 'a/b', 'x' * 200]) {
        final policy = await _load(
          _FakeSource(remote: {RemoteKeys.cloudModel: raw}),
          allowed: {'gemini-x', 'Gemini X', 'a/b'},
        );
        expect(policy.cloudModel, 'compiled-model', reason: raw);
      }
    });

    test('the allowlist define parses a comma list', () {
      expect(parseModelAllowlist(''), isEmpty);
      expect(parseModelAllowlist(' a, ,b '), {'a', 'b'});
    });

    test('HybridRuntime configures the backend, adapter and consent copy '
        'with the chosen model', () async {
      final policy = await _load(
        _FakeSource(remote: {RemoteKeys.cloudModel: 'gemini-x'}),
        allowed: {'gemini-x'},
      );
      final inference = FakeHybridInference();
      final hybrid = HybridRuntime.create(
        inference: inference,
        cloudRoutes: const CloudRoutes({CloudRoute.hybridFallback}),
        isOnline: () => true,
        remote: policy,
      );
      await (hybrid.inference as ConfiguredHybridInference).configured;
      expect(inference.config?.cloudModel, 'gemini-x');
      expect(hybrid.cloudModel, 'gemini-x');
      expect(hybrid.consent.cloudModel, 'gemini-x');
      expect(hybrid.cloudRoutes, isA<RemoteGatedCloudRoutes>());
    });
  });

  group('a late kill switch while the backend is still configuring', () {
    HybridTask draft() => HybridTask(
      feature: 'recipe_draft',
      parts: const [HybridText('Draft a recipe')],
      maxOutputTokens: 64,
      timeout: const Duration(seconds: 5),
    );

    test('routing waits for configuration, so the decision sees it', () async {
      final activation = Completer<void>();
      final source = _FakeSource(
        remote: {RemoteKeys.hybridEnabled: 'false'},
        fetch: () => activation.future,
      );
      final policy = await RemotePolicy.load(
        source,
        compiledCloudModel: 'm',
        timeout: const Duration(milliseconds: 10),
      );
      final inference = _SlowConfigure()..enqueueText('ok');
      final hybrid = HybridRuntime.create(
        inference: inference,
        cloudRoutes: const CloudRoutes({CloudRoute.hybridFallback}),
        isOnline: () => true,
        remote: policy,
      );
      // The runtime's current session: a run for any other is stale.
      final op = hybrid.dispatcher.start(draft(), sessionId: hybrid.sessionId);
      await Future<void>.delayed(Duration.zero);
      expect(inference.requests, isEmpty);
      // Remote Config activates late, while the backend is still starting.
      activation.complete();
      await Future<void>.delayed(Duration.zero);
      inference.gate.complete();
      final result = await op.result;
      expect(inference.requests.single.mode, HybridMode.onlyOnDevice);
      expect(result.legs.every((leg) => !leg.transferPermitted), isTrue);
    });

    test('a request that may upload is re-checked after the wait and '
        'refused, never forwarded', () async {
      var allowed = true;
      final inner = _SlowConfigure()..enqueueText('local');
      final configured = ConfiguredHybridInference(
        inner,
        const HybridConfig(cloudModel: 'm'),
        mayForward: (_) => allowed,
      );
      final cloud = configured.generate(
        HybridRequest(
          requestId: 'r1',
          mode: HybridMode.preferOnDevice,
          task: draft(),
        ),
      );
      final local = configured.generate(
        HybridRequest(
          requestId: 'r2',
          mode: HybridMode.onlyOnDevice,
          task: draft(),
        ),
      );
      allowed = false;
      inner.gate.complete();
      await expectLater(
        cloud,
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.blocked,
          ),
        ),
      );
      // On-device requests never needed the cloud route.
      expect((await local).text, 'local');
      expect(inner.requests.map((r) => r.requestId), ['r2']);
    });

    test(
      'the runtime re-checks local-only as well as the kill switch',
      () async {
        final inner = _SlowConfigure()..enqueueText('x');
        final hybrid = HybridRuntime.create(
          inference: inner,
          cloudRoutes: const CloudRoutes({CloudRoute.hybridFallback}),
          isOnline: () => true,
        );
        final configured = hybrid.inference as ConfiguredHybridInference;
        final request = HybridRequest(
          requestId: 'r',
          mode: HybridMode.onlyInCloud,
          task: draft(),
        );
        inner.gate.complete();
        await configured.configured;
        expect(configured.mayForward!(request), isTrue);
        hybrid.privacy.setLocalOnly('recipe_draft', true);
        expect(configured.mayForward!(request), isFalse);
      },
    );

    test("a sub-step honours its parent feature's local-only switch", () async {
      final inner = _SlowConfigure();
      final hybrid = HybridRuntime.create(
        inference: inner,
        cloudRoutes: const CloudRoutes({CloudRoute.hybridFallback}),
        isOnline: () => true,
      );
      final configured = hybrid.inference as ConfiguredHybridInference;
      final check = HybridRequest(
        requestId: 'frame',
        mode: HybridMode.onlyInCloud,
        task: HybridTask(
          feature: 'local_watch_cloud_check',
          parts: const [HybridText('Is it golden?')],
          maxOutputTokens: 64,
          timeout: const Duration(seconds: 5),
        ),
      );
      expect(configured.mayForward!(check), isTrue);
      // Only the parent (the watch) is set to on-device only.
      hybrid.privacy.setLocalOnly('local_watch', true);
      expect(configured.mayForward!(check), isFalse);
    });
  });
}
