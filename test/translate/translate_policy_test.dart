// Routing for `recipe_translate` (SS-106): the policy table, and the real
// DefaultHybridDispatcher over FakeHybridInference with an in-memory ledger.
// Fakes only: nothing reaches a model, network or device.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/ai/hybrid/inference_policy.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/recipe_language_view.dart';
import 'package:soussight/translate/recipe_translator.dart';

import 'translate_fixtures.dart';

const _f = recipeTranslateFeature;
const _local = HybridMode.onlyOnDevice;
const _prefer = HybridMode.preferOnDevice;
const _cloud = HybridMode.onlyInCloud;

RouteInput _in({
  String lang = 'es',
  int tokens = 2000,
  bool localOnly = false,
  bool online = true,
  bool cloud = true,
  HybridCapabilities caps = fakeWebCapabilities,
  OnDeviceStatus status = OnDeviceStatus.available,
  RemoteRouting? remote,
}) => RouteInput(
  feature: _f,
  estimatedTokens: tokens,
  languageTag: lang,
  localOnly: localOnly,
  online: online,
  cloudApproved: cloud,
  capabilities: caps,
  status: status,
  remote: remote,
);

class _Privacy implements PrivacySettings {
  final Set<String> localOnlyFeatures = {};
  @override
  bool localOnly(String feature) => localOnlyFeatures.contains(feature);
}

class _Consent implements ConsentGate {
  final asks = <ConsentAsk>[];
  @override
  Future<ConsentGrant?> request(ConsentAsk ask) async {
    asks.add(ask);
    return ConsentGrant(ask);
  }
}

class _Adapter implements CloudFallbackSender {
  final requests = <HybridRequest>[];
  @override
  Future<HybridResult> send(HybridRequest request) async {
    requests.add(request);
    return HybridResult(
      requestId: request.requestId,
      text: answerFor(request.task),
      source: InferenceSource.cloud,
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

/// Runs [onCapabilities] on each capability read, to change the world in
/// the middle of a dispatch.
class _CapsHook extends FakeHybridInference {
  _CapsHook({super.capabilities});
  void Function(int call)? onCapabilities;
  int _calls = 0;

  @override
  Future<HybridCapabilities> capabilities() async {
    onCapabilities?.call(++_calls);
    return super.capabilities();
  }
}

class _Harness {
  _Harness({
    HybridCapabilities caps = fakeWebCapabilities,
    String routes = 'hybridFallback',
    String language = 'es',
    String? Function(String feature)? featureLanguage,
  }) : bridge = _CapsHook(capabilities: caps) {
    var seq = 0;
    dispatcher = DefaultHybridDispatcher(
      inference: bridge,
      privacy: privacy,
      cloudRoutes: CloudRoutes.parse(routes),
      consent: consent,
      ledger: ledger,
      cloudFallback: adapter,
      languageTag: () => language,
      featureLanguageTag: featureLanguage,
      isOnline: () => online,
      newId: () => 'id-${++seq}',
    );
    translator = RecipeTranslator(dispatcher: dispatcher);
  }

  final _CapsHook bridge;
  bool online = true;
  final adapter = _Adapter();
  final privacy = _Privacy();
  final consent = _Consent();
  final ledger = InferenceLedger(sessionId: 's1');
  late final DefaultHybridDispatcher dispatcher;
  late final RecipeTranslator translator;

  void answer({
    InferenceSource source = InferenceSource.onDevice,
    String Function(HybridRequest request)? text,
    void Function()? before,
  }) => bridge.script.add((HybridRequest r) {
    before?.call();
    return HybridResult(
      requestId: '',
      text: text?.call(r) ?? answerFor(r.task),
      source: source,
    );
  });
}

typedef _Row = (
  String name,
  RouteInput input,
  HybridMode? mode,
  RouteReason reason,
);

void main() {
  group('policy table: recipe_translate', () {
    const toCloud = RemoteRouting(modes: {_f: _cloud});
    const pin = RemoteRouting(modes: {_f: _local});
    final rows = <_Row>[
      ('ready, English', _in(lang: 'en'), _prefer, RouteReason.onDevice),
      ('ready, Spanish on web', _in(), _prefer, RouteReason.onDevice),
      (
        'Spanish not validated on device → cloud',
        _in(caps: fakeIosCapabilities),
        _cloud,
        RouteReason.languageNotSupported,
      ),
      (
        'too large for the device → cloud',
        _in(tokens: 9217),
        _cloud,
        RouteReason.tooLargeForDevice,
      ),
      (
        'local-only, ready → on device only',
        _in(localOnly: true),
        _local,
        RouteReason.onDevice,
      ),
      (
        'local-only blocks the cloud for an unsupported language',
        _in(localOnly: true, caps: fakeIosCapabilities),
        null,
        RouteReason.localOnlySetting,
      ),
      (
        'local-only blocks the cloud for a large recipe',
        _in(localOnly: true, tokens: 9217),
        null,
        RouteReason.localOnlySetting,
      ),
      (
        'route not approved → on device only',
        _in(cloud: false),
        _local,
        RouteReason.onDevice,
      ),
      (
        'route not approved, unsupported language',
        _in(cloud: false, caps: fakeIosCapabilities),
        null,
        RouteReason.cloudNotApproved,
      ),
      (
        'offline, unsupported language',
        _in(online: false, caps: fakeIosCapabilities),
        null,
        RouteReason.offline,
      ),
      (
        'model downloading → SDK may answer from the cloud',
        _in(status: OnDeviceStatus.downloading),
        _prefer,
        RouteReason.modelDownloading,
      ),
      (
        'model downloading, local-only',
        _in(status: OnDeviceStatus.downloading, localOnly: true),
        null,
        RouteReason.modelDownloading,
      ),
      (
        'Remote Config cannot push it to the cloud',
        _in(remote: toCloud),
        _prefer,
        RouteReason.onDevice,
      ),
      (
        'Remote Config can pin it on device',
        _in(remote: pin),
        _local,
        RouteReason.onDevice,
      ),
    ];
    for (final (name, input, mode, reason) in rows) {
      test(name, () {
        final d = decideRoute(input);
        expect(d.mode, mode, reason: '$d');
        expect(d.reason, reason, reason: '$d');
        // Recipe text only: no per-payload prompt, but every leg is ledgered.
        expect(d.needsConsent, isFalse, reason: '$d');
        expect(d.mayUpload, mode != null && mode != _local);
      });
    }

    test('route defaults and retry rules', () {
      final route = featureRouteFor(_f);
      expect(route.defaultMode, _prefer);
      expect(route.cloudWhenLocalCannot, isTrue);
      expect(route.semanticRetry, isTrue);
      expect(consentRequired(_f, {DataKind.text}), isFalse);
      expect(
        decideCloudRetry(
          feature: _f,
          kinds: {DataKind.text},
          localOnly: true,
          cloudApproved: true,
          online: true,
        ).reason,
        RouteReason.localOnlySetting,
      );
    });
  });

  group('through DefaultHybridDispatcher', () {
    test('on device: one ledgered leg, no consent prompt', () async {
      final h = _Harness();
      h.answer();
      final t = await h.translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.complete);
      expect(h.bridge.requests.single.mode, _prefer);
      expect(h.bridge.requests.single.task.feature, _f);
      expect(h.consent.asks, isEmpty);
      expect(h.ledger.legs, hasLength(1));
      expect(h.ledger.legs.single.provenance, Provenance.sdkOnDevice);
      expect(t.legs.single.requestId, h.ledger.legs.single.requestId);
      expect(translationOriginSentence(t.legs), 'Translated on this device.');
    });

    test('local-only blocks the cloud: nothing is sent', () async {
      final h = _Harness(caps: fakeIosCapabilities);
      h.privacy.localOnlyFeatures.add(_f);
      final t = await h.translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.blocked);
      expect(t.blocked, RouteReason.localOnlySetting);
      expect(h.bridge.requests, isEmpty);
      expect(h.adapter.requests, isEmpty);
      expect(h.ledger.legs, isEmpty);
      expect(t.legs, isEmpty);
    });

    test('local-only on a capable device runs on device only', () async {
      final h = _Harness();
      h.privacy.localOnlyFeatures.add(_f);
      h.answer();
      final t = await h.translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.complete);
      expect(h.bridge.requests.single.mode, _local);
      expect(h.ledger.legs.single.transferPermitted, isFalse);
    });

    test('malformed on-device answer: one cloud retry, both legs', () async {
      final h = _Harness();
      h.answer(text: (_) => 'Aquí está tu receta.');
      h.answer(source: InferenceSource.cloud);
      final t = await h.translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.status, TranslationStatus.complete);
      expect([for (final r in h.bridge.requests) r.mode], [_prefer, _cloud]);
      expect(
        [for (final l in h.ledger.legs) l.provenance],
        [Provenance.sdkOnDevice, Provenance.sdkCloud],
      );
      expect(t.legs, hasLength(2));
      expect(
        translationOriginSentence(t.legs),
        'Some or all of this was translated in the cloud.',
      );
    });

    test(
      'the retry is blocked when local-only is switched on mid-way',
      () async {
        final h = _Harness();
        h.answer(
          text: (_) => 'not json',
          before: () => h.privacy.localOnlyFeatures.add(_f),
        );
        final t = await h.translator.translate(
          testRecipe(),
          spanish,
          sessionId: 's1',
        );
        expect(h.bridge.requests, hasLength(1));
        expect(t.status, TranslationStatus.blocked);
        expect(t.blocked, RouteReason.localOnlySetting);
        // The blocked retry is a leg too, and it did not transfer.
        expect(t.legs.last.transferPermitted, isFalse);
        expect(t.legs.last.error, HybridErrorCode.blocked);
      },
    );

    test('privacy is re-read before each chunk is sent', () async {
      final h = _Harness(caps: fakeIosCapabilities);
      // The first chunk goes to the cloud (Spanish is not validated on this
      // device); the cook then turns on local-only.
      h.answer(
        source: InferenceSource.cloud,
        before: () => h.privacy.localOnlyFeatures.add(_f),
      );
      h.answer(source: InferenceSource.cloud);
      final t = await h.translator.translate(
        testRecipe(extraSteps: 40),
        spanish,
        sessionId: 's1',
        maxTotalTokens: 4000,
      );
      expect(h.bridge.requests, hasLength(1));
      expect(h.bridge.requests.single.mode, _cloud);
      expect(t.status, TranslationStatus.partial);
      expect(t.blocked, RouteReason.localOnlySetting);
      expect(h.ledger.legs, hasLength(1));
    });

    test('the per-feature language tag drives the language check', () async {
      final h = _Harness(
        caps: fakeIosCapabilities,
        language: 'en',
        featureLanguage: (f) => f == _f ? 'es' : null,
      );
      h.answer(source: InferenceSource.cloud);
      final t = await h.translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      // Spanish is not validated on this device, so it went to the cloud.
      expect(h.bridge.requests.single.mode, _cloud);
      expect(t.status, TranslationStatus.complete);
      // Other features keep the app's language and stay on device.
      h.bridge.enqueueText('ok');
      final other = await h.dispatcher
          .start(
            const HybridTask(
              feature: 'coach_lite',
              parts: [HybridText('q')],
              maxOutputTokens: 10,
              timeout: Duration(seconds: 5),
            ),
            sessionId: 's1',
          )
          .result;
      expect(other.text, 'ok');
      expect(h.bridge.requests.last.mode, _local);
    });

    test('connectivity is re-read before the retry is sent', () async {
      // Codex #5: offline during the retry's capability lookup.
      final h = _Harness();
      h.answer(text: (_) => 'not json');
      h.answer(source: InferenceSource.cloud);
      h.bridge.onCapabilities = (call) {
        if (call == 2) h.online = false;
      };
      final t = await h.translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect([for (final r in h.bridge.requests) r.mode], [_prefer]);
      expect(h.adapter.requests, isEmpty);
      expect(t.blocked, RouteReason.offline);
      expect(t.legs.last.transferPermitted, isFalse);
    });

    test('an unapproved route never reaches the cloud', () async {
      final h = _Harness(caps: fakeIosCapabilities, routes: '');
      final t = await h.translator.translate(
        testRecipe(),
        spanish,
        sessionId: 's1',
      );
      expect(t.blocked, RouteReason.cloudNotApproved);
      expect(h.bridge.requests, isEmpty);
      expect(h.adapter.requests, isEmpty);
    });
  });
}
