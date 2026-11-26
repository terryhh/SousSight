// Contract: `rejectedBeforeSend` is the bridge's proof that it refused a
// request before any SDK or network call. Its wire name must match the iOS
// bridge's `HybridErrorCode.rejectedBeforeSend` raw value.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the wire name is stable and distinct from unsupportedInput', () {
    expect(HybridErrorCode.rejectedBeforeSend.name, 'rejectedBeforeSend');
    expect(
      HybridErrorCode.values.asNameMap()['rejectedBeforeSend'],
      HybridErrorCode.rejectedBeforeSend,
    );
    expect(
      HybridErrorCode.rejectedBeforeSend,
      isNot(HybridErrorCode.unsupportedInput),
    );
  });

  test('the method channel decodes a native rejectedBeforeSend', () async {
    const channel = MethodChannel(
      MethodChannelHybridInference.methodChannelName,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'rejectedBeforeSend',
            message: 'iOS hybrid sessions are text only',
          );
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await expectLater(
      MethodChannelHybridInference().generate(
        HybridRequest(
          requestId: 'r1',
          mode: HybridMode.onlyInCloud,
          task: const HybridTask(
            feature: 'label_check',
            parts: [HybridText('hi')],
            maxOutputTokens: 16,
            timeout: Duration(seconds: 5),
          ),
        ),
      ),
      throwsA(
        isA<HybridException>().having(
          (e) => e.code,
          'code',
          HybridErrorCode.rejectedBeforeSend,
        ),
      ),
    );
  });
}
