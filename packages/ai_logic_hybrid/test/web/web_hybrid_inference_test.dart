// Runs only in a browser: flutter test --platform chrome test/web
// Covers the Dart <-> JS marshalling against a stub globalThis.aiLogicHybrid. The
// script's own behaviour is covered by test/hybrid/web_bridge_test.cjs (node --test).
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:ai_logic_hybrid/src/web/web_hybrid_inference.dart';
import 'package:flutter_test/flutter_test.dart';

const _stub = r'''
globalThis.aiLogicHybrid = {
  calls: [],
  configure(c) { this.calls.push(['configure', c]); return Promise.resolve(); },
  capabilities() {
    return Promise.resolve({
      platform: 'web',
      local: { modelFamily: 'Gemini Nano', supportsImage: true, supportsJsonSchema: true,
               maxTotalTokens: 9216, defaultOutputReserve: 512, imageTokenEstimate: 1000,
               validatedLanguages: ['en'] },
      maxImages: 1, maxImageBytes: 1048576, maxImageDimension: 768,
      supportedModes: ['preferOnDevice', 'onlyInCloud'],
    });
  },
  availability(a) {
    this.calls.push(['availability', a.withImage]);
    return Promise.resolve(a.withImage ? { status: 'downloadable', reason: 'model_not_ready' } : { status: 'available' });
  },
  prepare(a, onProgress) {
    this.calls.push(['prepare', a.withImage]);
    onProgress(0.5); onProgress(null);
    return a.withImage ? Promise.reject(Object.assign(new Error('no gesture'), { code: 'unavailable' })) : Promise.resolve();
  },
  generate(r) {
    this.calls.push(['generate', r.requestId, r.mode, r.parts.map(p => p.type === 'inlineData' ? p.bytes instanceof Uint8Array : p.text),
                     r.jsonSchema ? r.jsonSchema.required[0] : null, r.systemInstruction ?? null, r.timeoutMs]);
    if (r.mode === 'onlyInCloud') return Promise.reject(Object.assign(new Error('slow down'), { code: 'quota' }));
    if (r.mode === 'preferInCloud') return Promise.reject(Object.assign(new Error('odd'), { code: 'notACode' }));
    return Promise.resolve({ requestId: r.requestId, text: 'hi', source: r.mode === 'onlyOnDevice' ? 'onDevice' : 'cloud', modelLabel: null });
  },
  cancel(id) { this.calls.push(['cancel', id]); return Promise.resolve(); },
  settle(p) {
    return Promise.resolve(p).then(value => ({ ok: true, value }), e => ({ ok: false, code: e.code, message: e.message }));
  },
};
''';

List<Object?> _calls() =>
    ((globalContext['aiLogicHybrid'] as JSObject)['calls'].dartify() as List)
        .cast<Object?>();

void main() {
  late HybridInference inference;

  setUp(() {
    globalContext.callMethod('eval'.toJS, _stub.toJS);
    inference = webHybridInference()!;
  });

  test(
    'configure and capabilities cross the boundary with ints intact',
    () async {
      await inference.configure(const HybridConfig(cloudModel: 'm-1'));
      final caps = await inference.capabilities();
      expect(caps.platform, 'web');
      expect(caps.local!.maxTotalTokens, 9216);
      expect(caps.maxImageBytes, 1048576);
      expect(caps.supportedModes, {
        HybridMode.preferOnDevice,
        HybridMode.onlyInCloud,
      });
      final configure = _calls().first as List;
      expect((configure[1] as Map)['cloudModel'], 'm-1');
      expect((configure[1] as Map)['languages'], ['en']);
    },
  );

  test('availability is asked per modality', () async {
    expect(
      (await inference.availability(withImage: false)).status,
      OnDeviceStatus.available,
    );
    final image = await inference.availability(withImage: true);
    expect(image.status, OnDeviceStatus.downloadable);
    expect(image.reason, 'model_not_ready');
    expect(_calls(), [
      ['availability', false],
      ['availability', true],
    ]);
  });

  test('prepare starts synchronously and streams fractions, then completes or errors', () async {
    final text = inference.prepare(withImage: false);
    expect(_calls(), [
      ['prepare', false],
    ], reason: 'started at call time, not on listen');
    expect(await text.toList(), [0.5, null]);
    await expectLater(
      inference.prepare(withImage: true),
      emitsThrough(
        emitsError(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.unavailable,
          ),
        ),
      ),
    );
  });

  test(
    'generate sends bytes as Uint8Array and the schema as a JS object',
    () async {
      final result = await inference.generate(
        HybridRequest(
          requestId: 'r1',
          mode: HybridMode.onlyOnDevice,
          task: HybridTask(
            feature: 'local_watch',
            systemInstruction: 'Compare.',
            parts: [
              const HybridText('changed?'),
              HybridInlineData(Uint8List.fromList([1, 2, 3]), 'image/jpeg'),
            ],
            jsonSchema: const {
              'type': 'object',
              'required': ['changed'],
            },
            maxOutputTokens: 64,
            timeout: const Duration(seconds: 3),
          ),
        ),
      );
      expect(result.requestId, 'r1');
      expect(result.text, 'hi');
      expect(result.source, InferenceSource.onDevice);
      expect(result.modelLabel, isNull);
      expect(_calls().single, [
        'generate',
        'r1',
        'onlyOnDevice',
        ['changed?', true],
        'changed',
        'Compare.',
        3000,
      ]);
    },
  );

  test('rejections become HybridException with the bridge code; unknown codes are failed', () async {
    HybridRequest req(HybridMode mode) => HybridRequest(
      requestId: mode.name,
      mode: mode,
      task: const HybridTask(
        feature: 't',
        parts: [HybridText('x')],
        maxOutputTokens: 8,
        timeout: Duration(seconds: 1),
      ),
    );
    await expectLater(
      inference.generate(req(HybridMode.onlyInCloud)),
      throwsA(
        isA<HybridException>().having(
          (e) => e.code,
          'code',
          HybridErrorCode.quota,
        ),
      ),
    );
    await expectLater(
      inference.generate(req(HybridMode.preferInCloud)),
      throwsA(
        isA<HybridException>().having(
          (e) => e.code,
          'code',
          HybridErrorCode.failed,
        ),
      ),
    );
    await inference.cancel('r9');
    expect(_calls().last, ['cancel', 'r9']);
  });

  test(
    'a missing bridge never throws from capabilities or availability',
    () async {
      globalContext.delete('aiLogicHybrid'.toJS);
      final caps = await inference.capabilities();
      expect(caps.platform, 'none');
      expect(caps.supportedModes, isEmpty);
      final availability = await inference.availability(withImage: true);
      expect(availability.status, OnDeviceStatus.unavailable);
      expect(availability.reason, 'bridge_unavailable');
      await expectLater(
        inference.generate(
          const HybridRequest(
            requestId: 'x',
            mode: HybridMode.preferOnDevice,
            task: HybridTask(
              feature: 't',
              parts: [HybridText('x')],
              maxOutputTokens: 8,
              timeout: Duration(seconds: 1),
            ),
          ),
        ),
        throwsA(
          isA<HybridException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.unavailable,
          ),
        ),
      );
      await expectLater(
        inference.prepare(withImage: false),
        emitsError(isA<HybridException>()),
      );
    },
  );
}
