import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AndroidModelOption', () {
    test('auto is the default and travels as its name', () {
      const config = HybridConfig(cloudModel: 'm');
      expect(config.androidModel, AndroidModelOption.auto);
      expect(config.toMap()['androidModel'], 'auto');
      // The existing wire names are unchanged.
      expect(AndroidModelOption.values.map((o) => o.name), [
        'auto',
        'preview',
        'previewFast',
        'stable',
      ]);
    });

    test('fromName parses dart-define values; anything else is auto', () {
      expect(
        AndroidModelOption.fromName('preview'),
        AndroidModelOption.preview,
      );
      expect(
        AndroidModelOption.fromName('previewFast'),
        AndroidModelOption.previewFast,
      );
      expect(
        AndroidModelOption.fromName(' stable '),
        AndroidModelOption.stable,
      );
      expect(AndroidModelOption.fromName('auto'), AndroidModelOption.auto);
      expect(AndroidModelOption.fromName(null), AndroidModelOption.auto);
      expect(AndroidModelOption.fromName(''), AndroidModelOption.auto);
      expect(AndroidModelOption.fromName('nano4'), AndroidModelOption.auto);
      expect(AndroidModelOption.fromName('STABLE'), AndroidModelOption.auto);
    });
  });

  group('the chosen model is reported', () {
    test('availability carries the concrete option and observed name', () {
      final a = HybridAvailability.fromMap({
        'status': 'available',
        'reason': null,
        'modelLabel': 'nano-v3',
        'modelOption': 'stable',
      });
      expect(a.status, OnDeviceStatus.available);
      expect(a.modelLabel, 'nano-v3');
      expect(a.modelOption, AndroidModelOption.stable);
    });

    test('a missing, unknown or auto option is not a concrete model', () {
      for (final raw in <Object?>[null, 'auto', 'nano4', 3]) {
        final a = HybridAvailability.fromMap({
          'status': 'unavailable',
          'modelOption': raw,
        });
        expect(a.modelOption, isNull, reason: '$raw');
      }
    });

    test('capabilities carry the option once chosen', () {
      Map<Object?, Object?> caps(Object? option) => {
        'platform': 'android',
        'local': {
          'modelFamily': 'Gemini Nano',
          'modelOption': option,
          'supportsImage': true,
          'supportsJsonSchema': false,
          'maxTotalTokens': 4000,
          'defaultOutputReserve': 256,
          'imageTokenEstimate': 1000,
          'validatedLanguages': ['en'],
        },
        'maxImages': 1,
        'maxImageBytes': 1024 * 1024,
        'maxImageDimension': 768,
        'supportedModes': ['onlyOnDevice'],
      };
      final chosen = HybridCapabilities.fromMap(caps('preview'));
      expect(chosen.local!.modelOption, AndroidModelOption.preview);
      expect(chosen.toMap()['local'], containsPair('modelOption', 'preview'));
      expect(HybridCapabilities.fromMap(caps(null)).local!.modelOption, isNull);
      // Backends that never send the key (web, iOS) still parse.
      final noKey = caps(null)
        ..['local'] = (Map.of(caps(null)['local']! as Map)
          ..remove('modelOption'));
      expect(HybridCapabilities.fromMap(noKey).local!.modelOption, isNull);
    });
  });

  test('capabilities round-trip through the channel map format', () {
    final back = HybridCapabilities.fromMap(fakeIosCapabilities.toMap());
    expect(back.platform, 'ios');
    expect(back.local!.supportsImage, isFalse);
    expect(back.supportedModes, fakeIosCapabilities.supportedModes);
  });

  test('requests serialize modes and parts by their Dart names', () {
    final map = HybridRequest(
      requestId: 'r1',
      mode: HybridMode.onlyOnDevice,
      task: HybridTask(
        feature: 'local_watch',
        parts: [
          const HybridText('hi'),
          HybridInlineData(Uint8List(2), 'image/jpeg'),
        ],
        maxOutputTokens: 64,
        timeout: const Duration(seconds: 5),
      ),
    ).toMap();
    expect(map['mode'], 'onlyOnDevice');
    expect(map['timeoutMs'], 5000);
    expect((map['parts'] as List).last, containsPair('type', 'inlineData'));
  });

  test('hasImage and hasAudio look at the attachment type', () {
    HybridTask task(String mime) => HybridTask(
      feature: 'f',
      parts: [HybridInlineData(Uint8List(1), mime)],
      maxOutputTokens: 8,
      timeout: const Duration(seconds: 1),
    );
    expect(task('audio/wav').hasImage, isFalse);
    expect(task('audio/wav').hasAudio, isTrue);
    expect(task('image/jpeg').hasImage, isTrue);
    expect(task('image/jpeg').hasAudio, isFalse);
  });

  test('a cancelled call keeps its own scripted answer', () async {
    final fake = FakeHybridInference()
      ..enqueueText('old-frame')
      ..enqueueText('new-frame')
      ..delay = const Duration(milliseconds: 20);
    final a = fake.generate(_req('A'));
    await fake.cancel('A');
    await expectLater(
      a,
      throwsA(
        isA<HybridException>().having(
          (e) => e.code,
          'code',
          HybridErrorCode.cancelled,
        ),
      ),
    );
    final b = await fake.generate(_req('B'));
    expect(b.text, 'new-frame');
    expect(b.requestId, 'B');
  });

  test('the fake honours task.timeout and discards the late result', () async {
    final fake = FakeHybridInference()
      ..enqueueText('late')
      ..delay = const Duration(milliseconds: 50);
    await expectLater(
      fake.generate(_req('T', timeout: const Duration(milliseconds: 5))),
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
    'fake returns scripted results with the request id and records calls',
    () async {
      final fake = FakeHybridInference()
        ..enqueueText('ok', source: InferenceSource.cloud);
      final r = await fake.generate(
        const HybridRequest(
          requestId: 'r2',
          mode: HybridMode.preferOnDevice,
          task: HybridTask(
            feature: 'f',
            parts: [HybridText('q')],
            maxOutputTokens: 8,
            timeout: Duration(seconds: 1),
          ),
        ),
      );
      expect(r.requestId, 'r2');
      expect(r.source, InferenceSource.cloud);
      expect(fake.requests, hasLength(1));
    },
  );
}

HybridRequest _req(
  String id, {
  Duration timeout = const Duration(seconds: 1),
}) => HybridRequest(
  requestId: id,
  mode: HybridMode.preferOnDevice,
  task: HybridTask(
    feature: 'f',
    parts: const [HybridText('q')],
    maxOutputTokens: 8,
    timeout: timeout,
  ),
);
