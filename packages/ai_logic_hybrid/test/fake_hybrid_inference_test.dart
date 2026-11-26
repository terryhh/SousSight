// FakeHybridInference backs every app test and Rehearsal mode, so its
// scripted behaviour is itself a contract: these pin the parts the contract
// test does not.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';

HybridRequest _req(String id) => HybridRequest(
  requestId: id,
  mode: HybridMode.preferOnDevice,
  task: const HybridTask(
    feature: 'pantry_scan',
    parts: [HybridText('q')],
    maxOutputTokens: 8,
    timeout: Duration(seconds: 1),
  ),
);

void main() {
  test('configure records the config; capabilities default to web', () async {
    final fake = FakeHybridInference();
    expect(fake.config, isNull);
    const config = HybridConfig(cloudModel: 'gemini-cloud-test');
    await fake.configure(config);
    expect(fake.config, same(config));
    expect(await fake.capabilities(), same(fakeWebCapabilities));

    final ios = FakeHybridInference(capabilities: fakeIosCapabilities);
    expect((await ios.capabilities()).platform, 'ios');
  });

  test('availability answers per modality and follows later changes', () async {
    final fake = FakeHybridInference(
      imageAvailability: const HybridAvailability(
        status: OnDeviceStatus.unavailable,
        reason: 'device_not_eligible',
      ),
    );
    expect(
      (await fake.availability(withImage: false)).status,
      OnDeviceStatus.available,
    );
    final image = await fake.availability(withImage: true);
    expect(image.status, OnDeviceStatus.unavailable);
    expect(image.reason, 'device_not_eligible');

    fake.textAvailability = const HybridAvailability(
      status: OnDeviceStatus.downloadable,
    );
    expect(
      (await fake.availability(withImage: false)).status,
      OnDeviceStatus.downloadable,
    );
  });

  test('prepare reports progress through to completion', () async {
    final fake = FakeHybridInference();
    expect(await fake.prepare(withImage: true).toList(), [0.5, 1.0]);
  });

  test('an empty script fails rather than inventing an answer', () async {
    await expectLater(
      FakeHybridInference().generate(_req('r')),
      throwsA(
        isA<HybridException>().having(
          (e) => e.code,
          'code',
          HybridErrorCode.failed,
        ),
      ),
    );
  });

  test(
    'scripted exceptions are thrown and functions see the request',
    () async {
      final fake = FakeHybridInference();
      fake.script
        ..add(const HybridException(HybridErrorCode.quota, 'quota'))
        ..add(
          (HybridRequest r) => HybridResult(
            requestId: 'ignored',
            text: 'echo ${r.task.feature}',
            source: InferenceSource.cloud,
            modelLabel: 'cloud-test',
          ),
        )
        ..add(
          (HybridRequest r) =>
              const HybridException(HybridErrorCode.unsupportedInput, 'nope'),
        );

      await expectLater(
        fake.generate(_req('a')),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.quota,
          ),
        ),
      );
      final echoed = await fake.generate(_req('b'));
      expect(echoed.requestId, 'b', reason: 'request id always replaced');
      expect(echoed.text, 'echo pantry_scan');
      expect(echoed.source, InferenceSource.cloud);
      expect(echoed.modelLabel, 'cloud-test');
      await expectLater(
        fake.generate(_req('c')),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.unsupportedInput,
          ),
        ),
      );
      expect(fake.requests.map((r) => r.requestId), ['a', 'b', 'c']);
    },
  );

  test('cancel is recorded even for an unknown request', () async {
    final fake = FakeHybridInference();
    await fake.cancel('never-started');
    expect(fake.cancelled, ['never-started']);
  });
}
