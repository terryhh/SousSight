import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
        parts: [const HybridText('hi'), HybridInlineData(Uint8List(2), 'image/jpeg')],
        maxOutputTokens: 64,
        timeout: const Duration(seconds: 5),
      ),
    ).toMap();
    expect(map['mode'], 'onlyOnDevice');
    expect(map['timeoutMs'], 5000);
    expect((map['parts'] as List).last, containsPair('type', 'inlineData'));
  });

  test('fake returns scripted results with the request id and records calls', () async {
    final fake = FakeHybridInference()..enqueueText('ok', source: InferenceSource.cloud);
    final r = await fake.generate(const HybridRequest(
      requestId: 'r2',
      mode: HybridMode.preferOnDevice,
      task: HybridTask(feature: 'f', parts: [HybridText('q')], maxOutputTokens: 8, timeout: Duration(seconds: 1)),
    ));
    expect(r.requestId, 'r2');
    expect(r.source, InferenceSource.cloud);
    expect(fake.requests, hasLength(1));
  });
}
