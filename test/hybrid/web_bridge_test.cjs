// node --test test/hybrid/web_bridge_test.cjs
// Exercises packages/ai_logic_hybrid/assets/ai_logic_hybrid.js against a stubbed
// firebase-ai.js module and a stubbed Chrome LanguageModel. No network, no model.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '../../packages/ai_logic_hybrid/assets/ai_logic_hybrid.js'),
  'utf8',
);

function loadScript(global) {
  // The script is an IIFE over `globalThis`; run it against a fake global.
  new Function('globalThis', source)(global);
  return global.aiLogicHybrid;
}

function fakeCore(version = '13.1.0') {
  return { SDK_VERSION: version, getApp: () => ({ name: '[DEFAULT]' }) };
}

function fakeSdk(respond) {
  const models = [];
  const calls = [];
  class GoogleAIBackend {}
  return {
    models,
    calls,
    GoogleAIBackend,
    getAI(app, options) { return { app, backend: options.backend }; },
    getGenerativeModel(ai, params) {
      const model = {
        ai,
        params,
        async generateContent(request, options) {
          calls.push({ model, request, options });
          return respond(model, request, options);
        },
      };
      models.push(model);
      return model;
    },
  };
}

function okResponse(model, text = 'ok') {
  const source = model.params.mode === 'only_in_cloud' || model.params.mode === 'prefer_in_cloud' ? 'in_cloud' : 'on_device';
  return { response: { inferenceSource: source, text: () => text } };
}

function fakeLanguageModel({ text = 'available', image = 'available', create } = {}) {
  const availabilityCalls = [];
  const createCalls = [];
  return {
    availabilityCalls,
    createCalls,
    async availability(options) {
      availabilityCalls.push(options);
      return options.expectedInputs.some(i => i.type === 'image') ? image : text;
    },
    create(options) {
      createCalls.push(options);
      return create ? create(options) : Promise.resolve({ destroy() {} });
    },
  };
}

function setup(options = {}) {
  const { respond = model => okResponse(model), languageModel = fakeLanguageModel(), importer } = options;
  const core = 'core' in options ? options.core : fakeCore();
  const sdk = fakeSdk(respond);
  const imports = [];
  const global = { firebase_core: core, setTimeout, clearTimeout, AbortController };
  const bridge = loadScript(global).create({
    global,
    languageModel,
    importer: importer ?? (async url => { imports.push(url); return sdk; }),
  });
  return { bridge, sdk, imports, global, languageModel };
}

async function configured(options) {
  const h = setup(options);
  await h.bridge.configure({ cloudModel: 'cloud-model-x', androidModel: 'preview', languages: ['en'] });
  return h;
}

let nextId = 0;
function request(overrides = {}) {
  return {
    requestId: `r${++nextId}`,
    mode: 'preferOnDevice',
    feature: 'test',
    systemInstruction: null,
    parts: [{ type: 'text', text: 'hello' }],
    jsonSchema: null,
    maxOutputTokens: 256,
    timeoutMs: 5000,
    ...overrides,
  };
}

async function rejectsWith(promise, code) {
  await assert.rejects(promise, e => {
    assert.equal(e.code, code, `expected ${code}, got ${e.code}: ${e.message}`);
    return true;
  });
}

function png(width, height) {
  const b = new Uint8Array(33);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  new DataView(b.buffer).setUint32(16, width);
  new DataView(b.buffer).setUint32(20, height);
  return b;
}

function jpeg(width, height) {
  // SOI, an APP0 segment, then SOF0 with the dimensions.
  return new Uint8Array([
    0xff, 0xd8,
    0xff, 0xe0, 0x00, 0x04, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 255, width >> 8, width & 255, 0x03,
  ]);
}

test('Dart mode names map to the SDK InferenceMode values and the SDK loads at firebase_core.SDK_VERSION', async () => {
  const h = await configured();
  const expected = {
    preferOnDevice: 'prefer_on_device',
    onlyOnDevice: 'only_on_device',
    preferInCloud: 'prefer_in_cloud',
    onlyInCloud: 'only_in_cloud',
  };
  for (const [mode, sdkMode] of Object.entries(expected)) {
    await h.bridge.generate(request({ mode }));
    assert.equal(h.sdk.calls.at(-1).model.params.mode, sdkMode);
  }
  assert.deepEqual(h.imports, ['https://www.gstatic.com/firebasejs/13.1.0/firebase-ai.js']);
  assert.equal(h.sdk.models[0].ai.app.name, '[DEFAULT]');
  assert.ok(h.sdk.models[0].ai.backend instanceof h.sdk.GoogleAIBackend);
  await rejectsWith(h.bridge.generate(request({ mode: 'sometimesOnDevice' })), 'unsupportedMode');
});

test('two incompatible tasks alternate without inheriting each other\'s instruction or schema', async () => {
  const h = await configured();
  const schemaA = { type: 'object', properties: { items: { type: 'array', items: { type: 'string' } } }, required: ['items'] };
  const taskA = () => request({ systemInstruction: 'List pantry items.', jsonSchema: schemaA });
  const taskB = () => request({ systemInstruction: 'Describe the pan.' });
  for (const make of [taskA, taskB, taskA, taskB, taskA]) await h.bridge.generate(make());

  assert.equal(h.sdk.models.length, 2, 'one instance per configuration');
  const [a, b] = h.sdk.models;
  assert.deepEqual(h.sdk.calls.map(c => c.model === a ? 'A' : 'B'), ['A', 'B', 'A', 'B', 'A']);
  assert.equal(a.params.inCloudParams.systemInstruction, 'List pantry items.');
  assert.deepEqual(a.params.onDeviceParams.createOptions.initialPrompts, [{ role: 'system', content: 'List pantry items.' }]);
  assert.deepEqual(a.params.onDeviceParams.promptOptions.responseConstraint, schemaA);
  assert.equal(b.params.inCloudParams.systemInstruction, 'Describe the pan.');
  assert.deepEqual(b.params.onDeviceParams.createOptions.initialPrompts, [{ role: 'system', content: 'Describe the pan.' }]);
  assert.equal(b.params.onDeviceParams.promptOptions, undefined, 'B has no schema constraint');
  assert.equal(b.params.inCloudParams.generationConfig.responseSchema, undefined);
  assert.equal(b.params.inCloudParams.generationConfig.responseMimeType, undefined);
});

test('every part of the configuration key separates instances; equal schemas in another key order share one', async () => {
  const h = await configured();
  await h.bridge.generate(request({ jsonSchema: { type: 'object', required: ['a'], properties: { a: { type: 'string' } } } }));
  await h.bridge.generate(request({ jsonSchema: { properties: { a: { type: 'string' } }, type: 'object', required: ['a'] } }));
  assert.equal(h.sdk.models.length, 1);
  await h.bridge.generate(request({ maxOutputTokens: 64 }));
  await h.bridge.generate(request({ mode: 'onlyInCloud' }));
  await h.bridge.generate(request({ parts: [{ type: 'text', text: 'see' }, { type: 'inlineData', mimeType: 'image/jpeg', bytes: jpeg(640, 480) }] }));
  assert.equal(h.sdk.models.length, 4);
  await h.bridge.configure({ cloudModel: 'cloud-model-y', languages: ['en'] });
  await h.bridge.generate(request({ maxOutputTokens: 64 }));
  assert.equal(h.sdk.models.length, 5);
  assert.equal(h.sdk.models[4].params.inCloudParams.model, 'cloud-model-y');
});

test('local params carry modality-specific expected inputs, initialPrompts and responseConstraint', async () => {
  const h = await configured();
  const schema = { type: 'object', properties: { changed: { type: 'boolean' } }, required: ['changed'] };
  await h.bridge.generate(request({
    systemInstruction: 'Compare frames.',
    jsonSchema: schema,
    parts: [{ type: 'text', text: 'changed?' }, { type: 'inlineData', mimeType: 'image/png', bytes: png(64, 64) }],
  }));
  await h.bridge.generate(request({ systemInstruction: 'Text only.' }));
  const [image, text] = h.sdk.models;
  assert.deepEqual(image.params.onDeviceParams.createOptions.expectedInputs, [{ type: 'text', languages: ['en'] }, { type: 'image' }]);
  assert.deepEqual(image.params.onDeviceParams.createOptions.expectedOutputs, [{ type: 'text', languages: ['en'] }]);
  assert.deepEqual(image.params.onDeviceParams.promptOptions, { responseConstraint: schema });
  assert.deepEqual(text.params.onDeviceParams.createOptions.expectedInputs, [{ type: 'text', languages: ['en'] }]);
  const sent = h.sdk.calls[0].request.contents[0];
  assert.equal(sent.role, 'user');
  assert.deepEqual(sent.parts[0], { text: 'changed?' });
  assert.equal(sent.parts[1].inlineData.mimeType, 'image/png');
  assert.equal(sent.parts[1].inlineData.data, Buffer.from(png(64, 64)).toString('base64'));
});

test('cloud params ask for JSON with both responseMimeType and responseSchema', async () => {
  const h = await configured();
  const schema = { type: 'object', properties: { ok: { type: 'boolean' } } };
  await h.bridge.generate(request({ mode: 'onlyInCloud', jsonSchema: schema, maxOutputTokens: 300, systemInstruction: 'Be brief.' }));
  const cloud = h.sdk.models[0].params.inCloudParams;
  assert.equal(cloud.model, 'cloud-model-x');
  assert.equal(cloud.systemInstruction, 'Be brief.');
  assert.deepEqual(cloud.generationConfig, { maxOutputTokens: 300, responseMimeType: 'application/json', responseSchema: schema });
  assert.deepEqual(Object.keys(h.sdk.models[0].params).sort(), ['inCloudParams', 'mode', 'onDeviceParams']);
  assert.equal(h.sdk.calls[0].options.timeout, 5000);
  assert.ok(h.sdk.calls[0].options.signal, 'cloud calls get an abort signal');
});

test('availability is reported per modality from LanguageModel.availability', async () => {
  const lm = fakeLanguageModel({ text: 'available', image: 'unavailable' });
  const h = await configured({ languageModel: lm });
  assert.deepEqual({ ...(await h.bridge.availability({ withImage: false })) }, { status: 'available' });
  assert.deepEqual({ ...(await h.bridge.availability({ withImage: true })) }, { status: 'unavailable', reason: 'image_input_unavailable' });
  assert.deepEqual(lm.availabilityCalls.map(o => o.expectedInputs.map(i => i.type)), [['text'], ['text', 'image']]);

  const downloading = await configured({ languageModel: fakeLanguageModel({ text: 'downloadable', image: 'downloading' }) });
  assert.deepEqual({ ...(await downloading.bridge.availability({ withImage: false })) }, { status: 'downloadable', reason: 'model_not_ready' });
  assert.deepEqual({ ...(await downloading.bridge.availability({ withImage: true })) }, { status: 'downloading', reason: 'model_not_ready' });

  const old = await configured({ languageModel: null });
  assert.deepEqual({ ...(await old.bridge.availability({ withImage: false })) }, { status: 'unavailable', reason: 'unsupported_browser' });
  const caps = await old.bridge.capabilities();
  assert.equal(caps.platform, 'web');
  assert.equal(caps.local, null);
  assert.deepEqual([...caps.supportedModes], ['preferOnDevice', 'preferInCloud', 'onlyInCloud']);
});

test('a missing bridge never throws: platform none, bridge_unavailable, generate rejects unavailable', async () => {
  for (const options of [
    { core: undefined },
    { core: { SDK_VERSION: '13.1.0' } },
    { core: { SDK_VERSION: '13.1.0/../evil', getApp: () => ({}) } },
    { importer: async () => { throw new TypeError('Failed to fetch dynamically imported module'); } },
  ]) {
    const h = setup(options);
    await h.bridge.configure({ cloudModel: 'cloud-model-x' });
    const caps = await h.bridge.capabilities();
    assert.equal(caps.platform, 'none');
    assert.equal(caps.local, null);
    assert.deepEqual([...caps.supportedModes], []);
    assert.equal(caps.maxImages, 1);
    assert.deepEqual({ ...(await h.bridge.availability({ withImage: true })) }, { status: 'unavailable', reason: 'bridge_unavailable' });
    await rejectsWith(h.bridge.generate(request()), 'unavailable');
  }
});

test('a failed SDK import is retried once the Firebase core appears', async () => {
  const h = setup({ core: undefined });
  await h.bridge.configure({ cloudModel: 'cloud-model-x' });
  assert.equal((await h.bridge.capabilities()).platform, 'none');
  h.global.firebase_core = fakeCore();
  const caps = await h.bridge.capabilities();
  assert.equal(caps.platform, 'web');
  assert.equal(caps.local.modelFamily, 'Gemini Nano');
  assert.equal(caps.local.maxTotalTokens, 9216);
  assert.deepEqual([...caps.supportedModes], ['preferOnDevice', 'onlyOnDevice', 'preferInCloud', 'onlyInCloud']);
});

test('attachment limits and the local token budget reject before any SDK call', async () => {
  const h = await configured();
  const big = new Uint8Array(1024 * 1024 + 1);
  big.set(jpeg(100, 100));
  const cases = [
    [{ type: 'inlineData', mimeType: 'image/jpeg', bytes: jpeg(10, 10) }, { type: 'inlineData', mimeType: 'image/jpeg', bytes: jpeg(10, 10) }],
    [{ type: 'inlineData', mimeType: 'image/jpeg', bytes: big }],
    [{ type: 'inlineData', mimeType: 'image/png', bytes: png(1024, 10) }],
    [{ type: 'inlineData', mimeType: 'image/jpeg', bytes: jpeg(700, 800) }],
    [{ type: 'inlineData', mimeType: 'image/gif', bytes: new Uint8Array(4) }],
    [{ type: 'inlineData', mimeType: 'audio/pcm', bytes: new Uint8Array(4) }],
    [{ type: 'audio', bytes: new Uint8Array(4) }],
    [],
  ];
  for (const parts of cases) await rejectsWith(h.bridge.generate(request({ parts })), 'unsupportedInput');
  await rejectsWith(
    h.bridge.generate(request({ mode: 'onlyOnDevice', parts: [{ type: 'text', text: 'x'.repeat(4 * 9000) }] })),
    'unsupportedInput',
  );
  assert.equal(h.sdk.calls.length, 0);
  // The token budget binds only a local-only run; the same text may go to the cloud.
  await h.bridge.generate(request({ mode: 'onlyInCloud', parts: [{ type: 'text', text: 'x'.repeat(4 * 9000) }] }));
  // A 768 px image passes.
  await h.bridge.generate(request({ parts: [{ type: 'inlineData', mimeType: 'image/jpeg', bytes: jpeg(768, 768) }] }));
  assert.equal(h.sdk.calls.length, 2);
});

test('timeout rejects within task.timeout, aborts the cloud signal and discards the late result', async () => {
  let release;
  let signal;
  const h = await configured({
    respond: (model, req, options) => { signal = options.signal; return new Promise(r => { release = () => r(okResponse(model, 'late')); }); },
  });
  const started = Date.now();
  await rejectsWith(h.bridge.generate(request({ timeoutMs: 30 })), 'timeout');
  assert.ok(Date.now() - started < 1000);
  assert.equal(signal.aborted, true);
  release();
  await new Promise(r => setTimeout(r, 5));
  // The id is free again and a fresh request works.
  const ok = await configured();
  assert.equal((await ok.bridge.generate(request())).text, 'ok');
});

test('cancel abandons an in-flight request and rejects it with cancelled; early cancel also wins', async () => {
  let signal;
  const h = await configured({ respond: (model, req, options) => { signal = options.signal; return new Promise(() => {}); } });
  const r = request();
  const pending = h.bridge.generate(r);
  await new Promise(resolve => setTimeout(resolve, 5));
  await h.bridge.cancel(r.requestId);
  await rejectsWith(pending, 'cancelled');
  assert.equal(signal.aborted, true);

  const early = request();
  await h.bridge.cancel(early.requestId);
  await rejectsWith(h.bridge.generate(early), 'cancelled');
  await h.bridge.cancel('unknown-id'); // never throws
});

test('inferenceSource comes from the SDK and is never inferred', async () => {
  const sources = ['on_device', 'in_cloud', undefined, 'somewhere'];
  let i = 0;
  const h = await configured({ respond: () => ({ response: { inferenceSource: sources[i++], text: () => '{"ok":true}' } }) });
  const local = await h.bridge.generate(request());
  assert.deepEqual({ ...local }, { requestId: local.requestId, text: '{"ok":true}', source: 'onDevice', modelLabel: null });
  assert.equal((await h.bridge.generate(request())).source, 'cloud');
  await rejectsWith(h.bridge.generate(request()), 'failed');
  await rejectsWith(h.bridge.generate(request()), 'failed');
});

test('a result that contradicts an only-* mode is refused, not reported', async () => {
  const h = await configured({ respond: () => ({ response: { inferenceSource: 'in_cloud', text: () => 'x' } }) });
  await rejectsWith(h.bridge.generate(request({ mode: 'onlyOnDevice' })), 'failed');
});

test('SDK and Prompt API errors map to HybridErrorCode names', async () => {
  const sdkError = (code, extra) => Object.assign(new Error(code), { code, ...extra });
  const domError = name => Object.assign(new Error(name), { name });
  const cases = [
    [sdkError('fetch-error', { customErrorData: { status: 429 } }), 'quota'],
    [sdkError('fetch-error', { customErrorData: { status: 401 } }), 'attestation'],
    [sdkError('fetch-error', { customErrorData: { status: 403 } }), 'attestation'],
    [sdkError('fetch-error', { customErrorData: { status: 503 } }), 'busy'],
    [sdkError('response-error'), 'blocked'],
    [sdkError('unsupported'), 'unavailable'],
    [sdkError('api-not-enabled'), 'unavailable'],
    [sdkError('request-error'), 'unsupportedInput'],
    [Object.assign(new Error('Error fetching from https://x: Failed to fetch'), { code: 'error' }), 'network'],
    [domError('QuotaExceededError'), 'unsupportedInput'],
    [domError('NotSupportedError'), 'unavailable'],
    [domError('InvalidStateError'), 'failed'],
  ];
  let k = 0;
  const h = await configured({ respond: () => { throw cases[k++][0]; } });
  for (const [, code] of cases) await rejectsWith(h.bridge.generate(request()), code);
  // A blocked response surfaces when the text is read.
  const blocked = await configured({ respond: () => ({ response: { inferenceSource: 'in_cloud', text: () => { throw sdkError('response-error'); } } }) });
  await rejectsWith(blocked.bridge.generate(request()), 'blocked');
});

test('generate before configure fails; configure needs a cloud model', async () => {
  const h = setup();
  await rejectsWith(h.bridge.generate(request()), 'failed');
  await rejectsWith(h.bridge.configure({}), 'failed');
});

test('prepare starts LanguageModel.create synchronously, forwards progress and shares one download per modality', async () => {
  let finish;
  const destroyed = [];
  const lm = fakeLanguageModel({
    create: options => {
      const listeners = [];
      options.monitor({ addEventListener: (type, fn) => listeners.push([type, fn]) });
      for (const [type, fn] of listeners) if (type === 'downloadprogress') { fn({ loaded: 0.25 }); fn({ loaded: 1.5 }); }
      return new Promise(r => { finish = () => r({ destroy: () => destroyed.push(true) }); });
    },
  });
  const h = await configured({ languageModel: lm });
  const seen = [];
  const other = [];
  const first = h.bridge.prepare({ withImage: true }, f => seen.push(f));
  assert.equal(lm.createCalls.length, 1, 'create is called before prepare returns');
  assert.deepEqual(lm.createCalls[0].expectedInputs, [{ type: 'text', languages: ['en'] }, { type: 'image' }]);
  const second = h.bridge.prepare({ withImage: true }, f => other.push(f));
  assert.equal(lm.createCalls.length, 1, 'concurrent prepare shares the download');
  assert.deepEqual(seen, [0.25, 1]);
  finish();
  await Promise.all([first, second]);
  assert.deepEqual(destroyed, [true], 'the warm-up session is released');

  const none = await configured({ languageModel: null });
  await rejectsWith(none.bridge.prepare({ withImage: false }, () => {}), 'unavailable');
  const refused = await configured({ languageModel: fakeLanguageModel({ create: () => Promise.reject(Object.assign(new Error('no'), { name: 'NotAllowedError' })) }) });
  await rejectsWith(refused.bridge.prepare({ withImage: false }), 'unavailable');
});

test('settle turns rejections into envelopes for Dart', async () => {
  const h = setup();
  assert.deepEqual({ ...(await h.bridge.settle(Promise.resolve(3))) }, { ok: true, value: 3 });
  const failed = await h.bridge.settle(Promise.reject(Object.assign(new Error('slow'), { code: 'fetch-error', customErrorData: { status: 429 } })));
  assert.deepEqual({ ...failed }, { ok: false, code: 'quota', message: 'slow' });
});

test('header helpers read PNG and JPEG sizes and base64 matches Node', () => {
  const { imageSize, base64 } = loadScript({})._internals;
  assert.deepEqual(imageSize(png(640, 480)), { width: 640, height: 480 });
  assert.deepEqual(imageSize(jpeg(768, 432)), { width: 768, height: 432 });
  assert.equal(imageSize(new Uint8Array([1, 2, 3])), null);
  for (const n of [0, 1, 2, 3, 4, 5, 257]) {
    const bytes = Uint8Array.from({ length: n }, (_, i) => (i * 37) & 255);
    assert.equal(base64(bytes), Buffer.from(bytes).toString('base64'));
  }
});
