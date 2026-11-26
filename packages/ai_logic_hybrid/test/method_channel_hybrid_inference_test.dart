import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _method = MethodChannel(MethodChannelHybridInference.methodChannelName);
const _prepare = EventChannel(MethodChannelHybridInference.prepareChannel);

HybridRequest _request(
  String id, {
  Duration timeout = const Duration(seconds: 5),
}) => HybridRequest(
  requestId: id,
  mode: HybridMode.onlyOnDevice,
  task: HybridTask(
    feature: 'local_watch',
    systemInstruction: 'Look for the cue.',
    parts: [
      const HybridText('Is it golden?'),
      HybridInlineData(Uint8List.fromList([1, 2, 3]), 'image/jpeg'),
    ],
    jsonSchema: const {'type': 'object'},
    maxOutputTokens: 64,
    timeout: timeout,
  ),
);

class _Stream extends MockStreamHandler {
  _Stream(this.onListenFn);
  final void Function(Object? args, MockStreamHandlerEventSink sink) onListenFn;
  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) =>
      onListenFn(arguments, events);
  @override
  void onCancel(Object? arguments) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('missing native plugin', () {
    test(
      'never throws from configure, capabilities, availability or cancel',
      () async {
        final bridge = MethodChannelHybridInference();
        await bridge.configure(const HybridConfig(cloudModel: 'm'));
        final caps = await bridge.capabilities();
        expect(caps.platform, 'none');
        expect(caps.local, isNull);
        expect(caps.supportedModes, isEmpty);
        final a = await bridge.availability(withImage: true);
        expect(a.status, OnDeviceStatus.unavailable);
        expect(a.reason, 'bridge_unavailable');
        await bridge.cancel('r1');
      },
    );

    test(
      'generate and prepare fail with unavailable instead of hanging',
      () async {
        final bridge = MethodChannelHybridInference();
        await expectLater(
          bridge.generate(_request('r1')),
          throwsA(
            isA<HybridException>().having(
              (e) => e.code,
              'code',
              HybridErrorCode.unavailable,
            ),
          ),
        );
        await expectLater(
          bridge.prepare(withImage: false),
          emitsError(
            isA<HybridException>().having(
              (e) => e.code,
              'code',
              HybridErrorCode.unavailable,
            ),
          ),
        );
      },
    );
  });

  test('requests and results follow the wire format', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call);
      return switch (call.method) {
        'capabilities' => fakeIosCapabilities.toMap(),
        'availability' => {
          'status': 'downloadable',
          'reason': 'model_not_ready',
        },
        'generate' => {
          'requestId': (call.arguments as Map)['requestId'],
          'text': '{"state":"ready"}',
          'source': 'onDevice',
          'modelLabel': null,
        },
        _ => null,
      };
    });
    final bridge = MethodChannelHybridInference();
    await bridge.configure(const HybridConfig(cloudModel: 'gemini-x'));
    expect(calls.single.arguments, {
      'cloudModel': 'gemini-x',
      'androidModel': 'stable',
      'languages': ['en'],
    });

    final caps = await bridge.capabilities();
    expect(caps.platform, 'ios');
    expect(caps.supportedModes, fakeIosCapabilities.supportedModes);

    final a = await bridge.availability(withImage: false);
    expect(calls.last.arguments, {'withImage': false});
    expect(a.status, OnDeviceStatus.downloadable);

    final r = await bridge.generate(_request('r7'));
    final args = calls.last.arguments as Map;
    expect(args['mode'], 'onlyOnDevice');
    expect(args['timeoutMs'], 5000);
    expect((args['parts'] as List).last, {
      'type': 'inlineData',
      'mimeType': 'image/jpeg',
      'bytes': Uint8List.fromList([1, 2, 3]),
    });
    expect(r.requestId, 'r7');
    expect(r.source, InferenceSource.onDevice);

    await bridge.cancel('r7');
    expect(calls.last.method, 'cancel');
    expect(calls.last.arguments, {'requestId': 'r7'});
  });

  test(
    'PlatformException codes map to HybridErrorCode, unknown codes to failed',
    () async {
      var code = 'busy';
      messenger.setMockMethodCallHandler(_method, (call) async {
        throw PlatformException(code: code, message: 'nope');
      });
      final bridge = MethodChannelHybridInference();
      for (final c in HybridErrorCode.values) {
        code = c.name;
        await expectLater(
          bridge.generate(_request('r')),
          throwsA(isA<HybridException>().having((e) => e.code, 'code', c)),
        );
      }
      code = 'SOMETHING_ELSE';
      await expectLater(
        bridge.generate(_request('r')),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.failed,
          ),
        ),
      );
    },
  );

  test('a native unavailable error during init reads as no bridge', () async {
    messenger.setMockMethodCallHandler(_method, (call) async {
      throw PlatformException(
        code: 'unavailable',
        message: 'device_not_eligible',
      );
    });
    final bridge = MethodChannelHybridInference();
    expect((await bridge.capabilities()).platform, 'none');
    final a = await bridge.availability(withImage: false);
    expect(a.status, OnDeviceStatus.unavailable);
    expect(a.reason, 'device_not_eligible');
  });

  test(
    'a result without a readable source or for another request fails',
    () async {
      var reply = <String, Object?>{
        'requestId': 'r1',
        'text': 'x',
        'source': 'guess',
      };
      messenger.setMockMethodCallHandler(_method, (call) async => reply);
      final bridge = MethodChannelHybridInference();
      await expectLater(
        bridge.generate(_request('r1')),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.failed,
          ),
        ),
      );
      reply = {'requestId': 'other', 'text': 'x', 'source': 'cloud'};
      await expectLater(
        bridge.generate(_request('r1')),
        throwsA(
          isA<HybridException>().having(
            (e) => e.message,
            'message',
            'Stale result',
          ),
        ),
      );
    },
  );

  test(
    'generate times out and cancels when the native side never answers',
    () async {
      final hang = Completer<Object?>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_method, (call) {
        calls.add(call.method);
        return call.method == 'generate' ? hang.future : Future.value();
      });
      final bridge = MethodChannelHybridInference();
      final clock = Stopwatch()..start();
      await expectLater(
        bridge.generate(
          _request('r1', timeout: const Duration(milliseconds: 20)),
        ),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.timeout,
          ),
        ),
      );
      // The caller's deadline, with no grace period (it was 2 s).
      expect(clock.elapsedMilliseconds, lessThan(1000));
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['generate', 'cancel']);
      // A native answer that arrives after the deadline goes nowhere.
      hang.complete({'requestId': 'r1', 'text': 'late', 'source': 'onDevice'});
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'prepare starts at call time and streams fractions until done',
    () async {
      final listened = <Object?>[];
      messenger.setMockStreamHandler(
        _prepare,
        _Stream((args, sink) {
          listened.add(args);
          sink
            ..success({'fraction': 0.25})
            ..success({'fraction': null})
            ..success({'fraction': 1})
            ..endOfStream();
        }),
      );
      final bridge = MethodChannelHybridInference();
      final stream = bridge.prepare(withImage: true);
      // Native work is asked for at call time, before anyone listens.
      expect(listened, [
        {'withImage': true},
      ]);
      final early = stream.toList();
      expect(await early, [0.25, null, 1.0]);
      // A listener that arrives after completion still sees the last state.
      expect(await stream.toList(), [1.0]);
    },
  );

  test('prepare errors carry the HybridErrorCode', () async {
    messenger.setMockStreamHandler(
      _prepare,
      _Stream((args, sink) => sink.error(code: 'quota', message: 'battery')),
    );
    final bridge = MethodChannelHybridInference();
    final stream = bridge.prepare(withImage: false);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // Even a listener that arrives after the failure must see it, never a
    // bare done that reads as "ready".
    await expectLater(
      stream,
      emitsError(
        isA<HybridException>().having(
          (e) => e.code,
          'code',
          HybridErrorCode.quota,
        ),
      ),
    );
  });

  test(
    'defaultHybridInference is the method channel unless a backend registers',
    () {
      expect(defaultHybridInference(), isA<MethodChannelHybridInference>());
      expect(
        identical(defaultHybridInference(), defaultHybridInference()),
        isTrue,
      );
      final fake = FakeHybridInference();
      registerHybridInferenceBackend(() => fake);
      expect(defaultHybridInference(), same(fake));
      // Clearing the override restores the platform default (the VM has no
      // web backend, so the method channel).
      registerHybridInferenceBackend(null);
      expect(defaultHybridInference(), isA<MethodChannelHybridInference>());
    },
  );
}
