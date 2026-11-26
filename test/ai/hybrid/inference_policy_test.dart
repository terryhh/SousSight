import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_policy.dart';

const _local = HybridMode.onlyOnDevice;
const _prefer = HybridMode.preferOnDevice;
const _cloud = HybridMode.onlyInCloud;

RouteInput _in(
  String feature, {
  bool image = false,
  bool audio = false,
  int tokens = 500,
  String lang = 'en',
  bool localOnly = false,
  bool online = true,
  bool cloud = true,
  HybridCapabilities caps = fakeWebCapabilities,
  OnDeviceStatus status = OnDeviceStatus.available,
  RemoteRouting? remote,
}) => RouteInput(
  feature: feature,
  hasImage: image,
  hasAudio: audio,
  estimatedTokens: tokens,
  languageTag: lang,
  localOnly: localOnly,
  online: online,
  cloudApproved: cloud,
  capabilities: caps,
  status: status,
  remote: remote,
);

typedef _Row = (
  String name,
  RouteInput input,
  HybridMode? mode,
  RouteReason reason,
  bool consent,
);

void main() {
  const none = HybridCapabilities.none();
  const toCloud = RemoteRouting(
    modes: {'pantry_scan': _cloud, 'label_check': _cloud},
  );
  const relax = RemoteRouting(
    modes: {
      'label_check': _prefer,
      'local_watch': _prefer,
      'coach_lite': _prefer,
      'pantry_scan': _local,
    },
  );

  final rows = <_Row>[
    // localOnly: only onlyOnDevice or null, whatever else is set.
    (
      'localOnly, ready',
      _in('pantry_scan', localOnly: true),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'localOnly, remote says cloud',
      _in('pantry_scan', localOnly: true, remote: toCloud),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'localOnly, remote says prefer',
      _in('label_check', localOnly: true, remote: relax, image: true),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'localOnly, audio',
      _in('pantry_voice', localOnly: true, audio: true),
      null,
      RouteReason.localOnlySetting,
      false,
    ),
    (
      'localOnly, iOS photo',
      _in(
        'pantry_scan',
        localOnly: true,
        image: true,
        caps: fakeIosCapabilities,
      ),
      null,
      RouteReason.localOnlySetting,
      false,
    ),
    (
      'localOnly, downloading',
      _in('pantry_scan', localOnly: true, status: OnDeviceStatus.downloading),
      null,
      RouteReason.modelDownloading,
      false,
    ),
    (
      'localOnly beats offline and unapproved',
      _in(
        'recipe_draft',
        localOnly: true,
        online: false,
        cloud: false,
        tokens: 99999,
      ),
      null,
      RouteReason.localOnlySetting,
      false,
    ),
    (
      'localOnly, no bridge',
      _in(
        'pantry_scan',
        localOnly: true,
        caps: none,
        status: OnDeviceStatus.unavailable,
      ),
      null,
      RouteReason.localOnlySetting,
      false,
    ),
    // cloudApproved false: same restriction.
    (
      'unapproved, ready',
      _in('pantry_scan', cloud: false),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'unapproved, remote says cloud',
      _in('pantry_scan', cloud: false, remote: toCloud),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'unapproved, too large',
      _in('recipe_draft', cloud: false, tokens: 9217),
      null,
      RouteReason.cloudNotApproved,
      false,
    ),
    (
      'unapproved, not downloaded',
      _in('recipe_draft', cloud: false, status: OnDeviceStatus.downloadable),
      null,
      RouteReason.modelNotReady,
      false,
    ),
    (
      'unapproved, voice',
      _in('pantry_voice', cloud: false, audio: true),
      null,
      RouteReason.cloudNotApproved,
      false,
    ),
    // Offline behaves like a restriction.
    (
      'offline, ready',
      _in('coach_lite', online: false),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'offline, voice',
      _in('pantry_voice', online: false, audio: true),
      null,
      RouteReason.offline,
      false,
    ),
    // Hard limits, cloud permitted.
    (
      'voice clip',
      _in('pantry_voice', audio: true),
      _cloud,
      RouteReason.audioNeedsCloud,
      false,
    ),
    (
      'audio on a local feature',
      _in('local_watch', audio: true),
      null,
      RouteReason.audioNeedsCloud,
      false,
    ),
    (
      'iOS pantry photo → cloud with consent',
      _in('pantry_scan', image: true, caps: fakeIosCapabilities),
      _cloud,
      RouteReason.imageNeedsCloud,
      true,
    ),
    (
      'iOS label photo → cloud with consent',
      _in('label_check', image: true, caps: fakeIosCapabilities),
      _cloud,
      RouteReason.imageNeedsCloud,
      true,
    ),
    (
      'iOS watch frame stays blocked',
      _in('local_watch', image: true, caps: fakeIosCapabilities),
      null,
      RouteReason.imageNeedsCloud,
      false,
    ),
    (
      'budget: exactly at limit runs locally',
      _in('recipe_draft', tokens: 9216),
      _prefer,
      RouteReason.onDevice,
      false,
    ),
    (
      'budget: one over goes to cloud',
      _in('recipe_draft', tokens: 9217),
      _cloud,
      RouteReason.tooLargeForDevice,
      false,
    ),
    (
      'budget: Android 4000',
      _in('pantry_scan', tokens: 4001, caps: _android),
      _cloud,
      RouteReason.tooLargeForDevice,
      false,
    ),
    (
      'budget: coach lite has no cloud',
      _in('coach_lite', tokens: 9217),
      null,
      RouteReason.tooLargeForDevice,
      false,
    ),
    (
      'language: region tag matches',
      _in('pantry_scan', lang: 'en-GB'),
      _prefer,
      RouteReason.onDevice,
      false,
    ),
    (
      'language: unvalidated → cloud',
      _in('pantry_scan', lang: 'ko', caps: fakeIosCapabilities),
      _cloud,
      RouteReason.languageNotSupported,
      false,
    ),
    (
      'language: watch stays local-only',
      _in('local_watch', lang: 'ko', caps: fakeIosCapabilities),
      null,
      RouteReason.languageNotSupported,
      false,
    ),
    (
      'no bridge → cloud route',
      _in('pantry_scan', caps: none, status: OnDeviceStatus.unavailable),
      _cloud,
      RouteReason.noLocalModel,
      false,
    ),
    (
      'no onlyOnDevice support',
      _in('pantry_scan', caps: _cloudOnly),
      _cloud,
      RouteReason.noLocalModel,
      false,
    ),
    // Availability.
    (
      'downloading: SDK falls back',
      _in('pantry_scan', status: OnDeviceStatus.downloading),
      _prefer,
      RouteReason.modelDownloading,
      false,
    ),
    (
      // Consented media goes onlyInCloud so the exact allowed bytes are sent
      // (Android's preferOnDevice re-encodes an image on fallback).
      'downloadable photo: consent, onlyInCloud',
      _in('pantry_scan', image: true, status: OnDeviceStatus.downloadable),
      _cloud,
      RouteReason.modelNotReady,
      true,
    ),
    (
      'downloading photo: consent, onlyInCloud',
      _in('recipe_draft', image: true, status: OnDeviceStatus.downloading),
      _cloud,
      RouteReason.modelDownloading,
      true,
    ),
    (
      // A ready model may answer a consented photo locally; the SDK's own
      // fallback is documented in DESIGN.md §5.
      'available photo: preferOnDevice, consent',
      _in('pantry_scan', image: true),
      _prefer,
      RouteReason.onDevice,
      true,
    ),
    (
      'unavailable: SDK falls back',
      _in('recipe_draft', status: OnDeviceStatus.unavailable),
      _prefer,
      RouteReason.noLocalModel,
      false,
    ),
    (
      'unavailable: watch blocked',
      _in('local_watch', image: true, status: OnDeviceStatus.unavailable),
      null,
      RouteReason.noLocalModel,
      false,
    ),
    (
      'downloading: label blocked',
      _in('label_check', image: true, status: OnDeviceStatus.downloading),
      null,
      RouteReason.modelDownloading,
      false,
    ),
    (
      'downloading: coach lite blocked',
      _in('coach_lite', status: OnDeviceStatus.downloading),
      null,
      RouteReason.modelDownloading,
      false,
    ),
    (
      'availability beats remote override',
      _in('pantry_scan', status: OnDeviceStatus.downloading, remote: relax),
      null,
      RouteReason.modelDownloading,
      false,
    ),
    // Remote overrides.
    (
      'remote cannot push to cloud',
      _in('pantry_scan', remote: toCloud),
      _prefer,
      RouteReason.onDevice,
      false,
    ),
    (
      'remote can tighten',
      _in('pantry_scan', remote: relax),
      _local,
      RouteReason.onDevice,
      false,
    ),
    // Codex P2: an on-device-only feature is never widened remotely.
    (
      'remote cannot widen label check',
      _in('label_check', image: true, remote: relax),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'remote cannot widen local watch (ready image model)',
      _in('local_watch', image: true, remote: relax),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'remote cannot widen coach lite',
      _in('coach_lite', remote: relax),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'remote cannot make a downloading watch fall back',
      _in(
        'local_watch',
        image: true,
        remote: relax,
        status: OnDeviceStatus.downloading,
      ),
      null,
      RouteReason.modelDownloading,
      false,
    ),
    // Codex P2: the typed-label path never goes to the cloud quietly.
    (
      'typed label in an unvalidated language stays blocked',
      _in('label_check', lang: 'fr', caps: fakeIosCapabilities),
      null,
      RouteReason.languageNotSupported,
      false,
    ),
    (
      'typed label too large stays blocked',
      _in('label_check', tokens: 9217),
      null,
      RouteReason.tooLargeForDevice,
      false,
    ),
    // A watch frame's explicit cloud check: cloud only, consent always.
    (
      'cloud check, ready',
      _in('local_watch_cloud_check', image: true),
      _cloud,
      RouteReason.cloudRetryAfterCheck,
      true,
    ),
    (
      'cloud check, downloading',
      _in(
        'local_watch_cloud_check',
        image: true,
        status: OnDeviceStatus.downloading,
      ),
      _cloud,
      RouteReason.cloudRetryAfterCheck,
      true,
    ),
    (
      'cloud check, iOS',
      _in('local_watch_cloud_check', image: true, caps: fakeIosCapabilities),
      _cloud,
      RouteReason.cloudRetryAfterCheck,
      true,
    ),
    (
      'cloud check, text still needs consent',
      _in('local_watch_cloud_check'),
      _cloud,
      RouteReason.cloudRetryAfterCheck,
      true,
    ),
    (
      'cloud check, localOnly is not run locally',
      _in('local_watch_cloud_check', image: true, localOnly: true),
      null,
      RouteReason.localOnlySetting,
      false,
    ),
    (
      'cloud check, unapproved',
      _in('local_watch_cloud_check', image: true, cloud: false),
      null,
      RouteReason.cloudNotApproved,
      false,
    ),
    (
      'cloud check, offline',
      _in('local_watch_cloud_check', image: true, online: false),
      null,
      RouteReason.offline,
      false,
    ),
    (
      'voice clip needs no per-clip consent',
      _in('pantry_voice', audio: true, status: OnDeviceStatus.downloading),
      _cloud,
      RouteReason.audioNeedsCloud,
      false,
    ),
    // Feature defaults.
    (
      'pantry photo, ready',
      _in('pantry_scan', image: true),
      _prefer,
      RouteReason.onDevice,
      true,
    ),
    (
      'pantry text, ready',
      _in('pantry_scan'),
      _prefer,
      RouteReason.onDevice,
      false,
    ),
    ('recipe draft', _in('recipe_draft'), _prefer, RouteReason.onDevice, false),
    (
      'local watch',
      _in('local_watch', image: true),
      _local,
      RouteReason.onDevice,
      false,
    ),
    ('coach lite', _in('coach_lite'), _local, RouteReason.onDevice, false),
    (
      'label check',
      _in('label_check', image: true),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'unknown feature fails closed',
      _in('mystery'),
      _local,
      RouteReason.onDevice,
      false,
    ),
    (
      'unknown feature, no local',
      _in('mystery', status: OnDeviceStatus.unavailable),
      null,
      RouteReason.noLocalModel,
      false,
    ),
    (
      'iOS recipe draft prefers on-device',
      _in('recipe_draft', caps: fakeIosCapabilities),
      _prefer,
      RouteReason.onDevice,
      false,
    ),
    (
      'no preferOnDevice support runs local',
      _in('recipe_draft', caps: _onlyLocal),
      _local,
      RouteReason.onDevice,
      false,
    ),
  ];

  for (final (name, input, mode, reason, consent) in rows) {
    test(name, () {
      final d = decideRoute(input);
      expect(d.mode, mode, reason: '$d');
      expect(d.reason, reason, reason: '$d');
      expect(d.needsConsent, consent, reason: '$d');
      expect(d.mayUpload, mode != null && mode != HybridMode.onlyOnDevice);
    });
  }

  test(
    'localOnly and unapproved never yield anything but onlyOnDevice or null',
    () {
      for (final feature in [...featureRoutes.keys, 'mystery']) {
        for (final status in OnDeviceStatus.values) {
          for (final caps in [
            fakeWebCapabilities,
            fakeIosCapabilities,
            _android,
            none,
          ]) {
            for (final (lo, ca) in [
              (true, true),
              (false, false),
              (true, false),
            ]) {
              for (final remote in [null, toCloud, relax]) {
                for (final image in [true, false]) {
                  final d = decideRoute(
                    _in(
                      feature,
                      image: image,
                      localOnly: lo,
                      cloud: ca,
                      status: status,
                      caps: caps,
                      remote: remote,
                    ),
                  );
                  expect(
                    d.mode,
                    anyOf(isNull, HybridMode.onlyOnDevice),
                    reason: '$feature $status $d',
                  );
                  expect(d.mayUpload, isFalse);
                }
              }
            }
          }
        }
      }
    },
  );

  group('pantry voice inherits pantry scan (SS-096)', () {
    test('pantry_voice names pantry_scan as its parent', () {
      expect(featureRouteFor('pantry_voice').parentFeature, 'pantry_scan');
    });

    test('"Keep Pantry scan on this device" keeps the voice clip local', () {
      final privacy = _Privacy({'pantry_scan'});
      expect(localOnlyFor(privacy, 'pantry_voice'), isTrue);
      final decision = decideRoute(
        _in(
          'pantry_voice',
          audio: true,
          localOnly: localOnlyFor(privacy, 'pantry_voice'),
        ),
      );
      expect(decision.blocked, isTrue);
      expect(decision.mayUpload, isFalse);
      expect(decision.reason, RouteReason.localOnlySetting);
      expect(
        decideCloudRetry(
          feature: 'pantry_voice',
          kinds: const {DataKind.audio},
          localOnly: localOnlyFor(privacy, 'pantry_voice'),
          cloudApproved: true,
          online: true,
        ).blocked,
        isTrue,
      );
    });

    test('the voice switch does not reach up to the parent', () {
      final privacy = _Privacy({'pantry_voice'});
      expect(localOnlyFor(privacy, 'pantry_voice'), isTrue);
      expect(localOnlyFor(privacy, 'pantry_scan'), isFalse);
      expect(localOnlyFor(_Privacy({}), 'pantry_voice'), isFalse);
    });
  });

  test('label check asks consent for any upload, text included', () {
    expect(consentRequired('label_check', {DataKind.text}), isTrue);
    expect(
      consentRequired('label_check', {DataKind.text, DataKind.image}),
      isTrue,
    );
    expect(consentRequired('pantry_scan', {DataKind.text}), isFalse);
  });

  group('decideCloudRetry', () {
    test('respects the live settings in order', () {
      RouteDecision r({
        bool lo = false,
        bool ca = true,
        bool on = true,
        Set<DataKind> kinds = const {DataKind.text},
      }) => decideCloudRetry(
        feature: 'recipe_draft',
        kinds: kinds,
        localOnly: lo,
        cloudApproved: ca,
        online: on,
      );
      expect(
        r(lo: true, ca: false, on: false).reason,
        RouteReason.localOnlySetting,
      );
      expect(r(ca: false, on: false).reason, RouteReason.cloudNotApproved);
      expect(r(on: false).reason, RouteReason.offline);
      final ok = r();
      expect(ok.mode, HybridMode.onlyInCloud);
      expect(ok.reason, RouteReason.cloudRetryAfterCheck);
      expect(ok.needsConsent, isFalse);
      expect(r(kinds: {DataKind.text, DataKind.image}).needsConsent, isTrue);
    });
  });

  group('estimateLocalTokens (§4)', () {
    test(
      'counts instruction, text and schema chars / 4, images, and output',
      () {
        final task = HybridTask(
          feature: 'pantry_scan',
          systemInstruction: 'x' * 40, // 40
          parts: [
            HybridText('y' * 20),
            HybridInlineData(Uint8List(10), 'image/jpeg'),
            const HybridText('z'),
          ], // 21
          jsonSchema: const {'type': 'object'}, // {"type":"object"} = 17
          maxOutputTokens: 256,
          timeout: const Duration(seconds: 5),
        );
        // ceil(78 / 4) = 20, + 1000 per image, + 256.
        expect(
          estimateLocalTokens(task, imageTokenEstimate: 1000),
          20 + 1000 + 256,
        );
        expect(estimateLocalTokens(task, imageTokenEstimate: 0), 20 + 256);
      },
    );

    test('audio is not charged as an image', () {
      final task = HybridTask(
        feature: 'pantry_voice',
        parts: [HybridInlineData(Uint8List(10), 'audio/wav')],
        maxOutputTokens: 10,
        timeout: const Duration(seconds: 5),
      );
      expect(estimateLocalTokens(task, imageTokenEstimate: 1000), 10);
    });
  });
}

const _android = HybridCapabilities(
  platform: 'android',
  local: LocalModelLimits(
    modelFamily: 'Gemini Nano',
    supportsImage: true,
    supportsJsonSchema: true,
    maxTotalTokens: 4000,
    defaultOutputReserve: 256,
    imageTokenEstimate: 1000,
    validatedLanguages: ['en', 'ko'],
  ),
  supportedModes: {
    HybridMode.preferOnDevice,
    HybridMode.onlyOnDevice,
    HybridMode.preferInCloud,
    HybridMode.onlyInCloud,
  },
);

const _cloudOnly = HybridCapabilities(
  platform: 'web',
  local: null,
  supportedModes: {HybridMode.onlyInCloud},
);

const _onlyLocal = HybridCapabilities(
  platform: 'web',
  local: LocalModelLimits(
    modelFamily: 'Gemini Nano',
    supportsImage: true,
    supportsJsonSchema: true,
    maxTotalTokens: 9216,
    defaultOutputReserve: 512,
    imageTokenEstimate: 1000,
    validatedLanguages: ['en'],
  ),
  supportedModes: {HybridMode.onlyOnDevice, HybridMode.onlyInCloud},
);

class _Privacy implements PrivacySettings {
  _Privacy(this.features);
  final Set<String> features;
  @override
  bool localOnly(String feature) => features.contains(feature);
}
