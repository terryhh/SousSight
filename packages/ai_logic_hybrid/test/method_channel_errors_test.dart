// Native errors through MethodChannelHybridInference: which ones read as "no
// bridge" and which surface as a HybridException with the native code. Mock
// channels only; no platform code runs.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _method = MethodChannel(MethodChannelHybridInference.methodChannelName);
const _prepareMethod = MethodChannel(
  MethodChannelHybridInference.prepareChannel,
);
const _prepare = EventChannel(MethodChannelHybridInference.prepareChannel);

Matcher _code(HybridErrorCode code) =>
    isA<HybridException>().having((e) => e.code, 'code', code);

class _Silent extends MockStreamHandler {
  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) {}
  @override
  void onCancel(Object? arguments) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_method, null);
    messenger.setMockMethodCallHandler(_prepareMethod, null);
    messenger.setMockStreamHandler(_prepare, null);
  });

  void nativeThrows(String code) =>
      messenger.setMockMethodCallHandler(_method, (call) async {
        throw PlatformException(code: code, message: 'native said no');
      });

  test('configure surfaces a native error with its code', () async {
    nativeThrows('quota');
    await expectLater(
      MethodChannelHybridInference().configure(
        const HybridConfig(cloudModel: 'm'),
      ),
      throwsA(_code(HybridErrorCode.quota)),
    );
  });

  test('capabilities and availability rethrow errors other than '
      'unavailable instead of reporting no bridge', () async {
    nativeThrows('attestation');
    final bridge = MethodChannelHybridInference();
    await expectLater(
      bridge.capabilities(),
      throwsA(_code(HybridErrorCode.attestation)),
    );
    await expectLater(
      bridge.availability(withImage: true),
      throwsA(_code(HybridErrorCode.attestation)),
    );
  });

  test('cancel is best effort: a native error is swallowed', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'failed');
    });
    await MethodChannelHybridInference().cancel('r1');
    expect(calls, ['cancel']);
  });

  test('a prepare for the other modality while one runs fails busy; the '
      'same modality shares the running stream', () async {
    messenger.setMockStreamHandler(_prepare, _Silent());
    final bridge = MethodChannelHybridInference();
    final text = bridge.prepare(withImage: false);
    expect(bridge.prepare(withImage: false), same(text));
    await expectLater(
      bridge.prepare(withImage: true),
      emitsError(_code(HybridErrorCode.busy)),
    );
  });

  test('a native error starting prepare fails the stream with its code, '
      'and the next prepare starts fresh', () async {
    final listens = <Object?>[];
    messenger.setMockMethodCallHandler(_prepareMethod, (call) async {
      listens.add(call.arguments);
      throw PlatformException(code: 'quota', message: 'battery saver');
    });
    final bridge = MethodChannelHybridInference();
    await expectLater(
      bridge.prepare(withImage: true),
      emitsError(_code(HybridErrorCode.quota)),
    );
    await expectLater(
      bridge.prepare(withImage: false),
      emitsError(_code(HybridErrorCode.quota)),
    );
    expect(listens, [
      {'withImage': true},
      {'withImage': false},
    ]);
  });

  test('HybridException names its code in toString', () {
    expect(
      const HybridException(HybridErrorCode.timeout, 'too slow').toString(),
      'HybridException(timeout): too slow',
    );
  });
}
