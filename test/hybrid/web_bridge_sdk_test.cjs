// node --test test/hybrid/web_bridge_sdk_test.cjs
// Runs the web bridge against the REAL shipped firebase-ai.js 13.1.0 bundle (vendored
// unmodified in fixtures/, see NOTICE.txt), evaluated offline: its firebase-app.js
// imports are replaced by in-memory stubs and every fetch is recorded and answered
// locally. Nothing leaves the machine. The point is the privacy guarantee: an
// onlyOnDevice request must never reach the SDK's cloud path.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const BUNDLE = path.join(__dirname, 'fixtures/firebase-ai-13.1.0.js');
const BUNDLE_SHA256 = '683abbb67b55e6d22dcedc5ac91c2dd5276b4629175905b7df2ad2f0f874bce8';
const bridgeSource = fs.readFileSync(
  path.join(__dirname, '../../packages/ai_logic_hybrid/assets/ai_logic_hybrid.js'),
  'utf8',
);
const bundle = fs.readFileSync(BUNDLE, 'utf8');

// Turns the ES module into a function of its imports, `window` and `fetch`.
function compileBundle() {
  const importMatch = bundle.match(/^import\{([^}]*)\}from"https:\/\/www\.gstatic\.com\/firebasejs\/13\.1\.0\/firebase-app\.js";/);
  assert.ok(importMatch, 'bundle starts with its firebase-app.js import');
  const imports = importMatch[1].split(',').map(spec => {
    const [name, local] = spec.split(' as ');
    return { name: name.trim(), local: (local ?? name).trim() };
  });
  const exportStart = bundle.lastIndexOf('export{');
  const exportEnd = bundle.indexOf('}', exportStart);
  const exported = bundle.slice(exportStart + 7, exportEnd).split(',').map(spec => {
    const [local, name] = spec.split(' as ');
    return `${(name ?? local).trim()}: ${local.trim()}`;
  });
  const body = bundle.slice(importMatch[0].length, exportStart) + `\nreturn {${exported.join(',')}};`;
  const factory = new Function(...imports.map(i => i.local), 'window', 'fetch', body);
  return { imports, factory };
}

function loadSdk({ window, fetch }) {
  const { imports, factory } = compileBundle();
  const components = new Map();
  const app = {
    name: '[DEFAULT]',
    options: { apiKey: 'test-key', projectId: 'test-project', appId: '1:2:web:3' },
    automaticDataCollectionEnabled: false,
  };
  const container = {
    getProvider: name => ({ getImmediate: () => (name === 'app' ? app : null) }),
  };
  const firebaseApp = {
    _registerComponent: component => { components.set(component.name, component); },
    registerVersion: () => {},
    _getProvider: (_, name) => {
      const instances = new Map();
      return {
        getImmediate: ({ identifier }) => {
          if (!instances.has(identifier)) {
            instances.set(identifier, components.get(name).instanceFactory(container, { instanceIdentifier: identifier }));
          }
          return instances.get(identifier);
        },
      };
    },
    getApp: () => app,
    _isFirebaseServerApp: () => false,
  };
  const sdk = factory(...imports.map(i => firebaseApp[i.name]), window, fetch);
  return { sdk, app };
}

function harness({ languageModel } = {}) {
  const fetches = [];
  const fetch = async (url, init) => {
    fetches.push({ url: String(url), body: init && init.body });
    return new Response(JSON.stringify({ candidates: [{ content: { role: 'model', parts: [{ text: 'from the cloud' }] }, finishReason: 'STOP' }] }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  };
  // One mutable window shared by the SDK and the bridge, so a test can add the model.
  const window = languageModel ? { LanguageModel: languageModel } : {};
  const { sdk, app } = loadSdk({ window, fetch });
  const global = {
    firebase_core: { SDK_VERSION: '13.1.0', getApp: () => app },
    setTimeout, clearTimeout, AbortController,
  };
  new Function('globalThis', bridgeSource)(global);
  const bridge = global.aiLogicHybrid.create({
    global,
    get languageModel() { return window.LanguageModel ?? null; },
    importer: async () => sdk,
  });
  const network = () => fetches.filter(f => !f.url.startsWith('data:'));
  return { bridge, fetches, network, window };
}

function languageModel(status, { promptCalls = [], createCalls = [] } = {}) {
  return {
    promptCalls,
    createCalls,
    async availability() { return status; },
    async create(options) {
      createCalls.push(options);
      return {
        async prompt(messages, promptOptions) { promptCalls.push({ messages, promptOptions }); return '{"changed":false}'; },
        destroy() {},
      };
    },
  };
}

const SECRET = 'PRIVATE-PANTRY-NOTE-7731';
let n = 0;
function request(mode, extra = {}) {
  return {
    requestId: `sdk-${++n}`,
    mode,
    feature: 'test',
    systemInstruction: 'Answer in JSON.',
    parts: [{ type: 'text', text: SECRET }],
    jsonSchema: { type: 'object', properties: { changed: { type: 'boolean' } }, required: ['changed'] },
    maxOutputTokens: 64,
    timeoutMs: 5000,
    ...extra,
  };
}

async function expectCode(promise, code) {
  await assert.rejects(promise, e => { assert.equal(e.code, code, e.message); return true; });
}

test('the vendored bundle is the shipped 13.1.0 file', () => {
  assert.equal(crypto.createHash('sha256').update(fs.readFileSync(BUNDLE)).digest('hex'), BUNDLE_SHA256);
});

test('harness control: onlyInCloud reaches the stubbed fetch through the real SDK', async () => {
  const h = harness();
  await h.bridge.configure({ cloudModel: 'cloud-model-x' });
  const result = await h.bridge.generate(request('onlyInCloud'));
  assert.equal(result.source, 'cloud');
  assert.equal(result.text, 'from the cloud');
  assert.equal(h.network().length, 1);
  const body = JSON.parse(h.network()[0].body);
  assert.equal(body.generationConfig.responseMimeType, 'application/json');
  assert.deepEqual(body.generationConfig.responseSchema.required, ['changed']);
});

for (const [label, lm] of [
  ['LanguageModel is absent', undefined],
  ['the local model is unavailable', languageModel('unavailable')],
  ['the local model is downloadable', languageModel('downloadable')],
  ['the local model is downloading', languageModel('downloading')],
]) {
  test(`onlyOnDevice sends nothing to the cloud when ${label}`, async () => {
    const h = harness({ languageModel: lm });
    await h.bridge.configure({ cloudModel: 'cloud-model-x' });
    await expectCode(h.bridge.generate(request('onlyOnDevice')), 'unavailable');
    await expectCode(
      h.bridge.generate(request('onlyOnDevice', { parts: [{ type: 'text', text: SECRET }, { type: 'inlineData', mimeType: 'image/jpeg', bytes: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]) }] })),
      'unavailable',
    );
    assert.equal(h.fetches.length, 0, 'no fetch of any kind');
  });
}

test('onlyOnDevice with an unsupported attachment type is refused before the SDK', async () => {
  const h = harness({ languageModel: languageModel('available') });
  await h.bridge.configure({ cloudModel: 'cloud-model-x' });
  await expectCode(
    h.bridge.generate(request('onlyOnDevice', { parts: [{ type: 'inlineData', mimeType: 'image/webp', bytes: new Uint8Array(8) }] })),
    'unsupportedInput',
  );
  assert.equal(h.fetches.length, 0);
});

test('onlyOnDevice with a ready model runs locally with initialPrompts and responseConstraint and no fetch', async () => {
  const promptCalls = [];
  const createCalls = [];
  const h = harness({ languageModel: languageModel('available', { promptCalls, createCalls }) });
  await h.bridge.configure({ cloudModel: 'cloud-model-x' });
  const result = await h.bridge.generate(request('onlyOnDevice'));
  assert.equal(result.source, 'onDevice');
  assert.equal(result.text, '{"changed":false}');
  assert.equal(h.fetches.length, 0);
  assert.deepEqual(createCalls[0].initialPrompts, [{ role: 'system', content: 'Answer in JSON.' }]);
  assert.deepEqual(promptCalls[0].promptOptions.responseConstraint.required, ['changed']);
  assert.equal(promptCalls[0].messages[0].content[0].value, SECRET);
});

test('onlyOnDevice refused while LanguageModel is absent works locally once it appears, still with no fetch', async () => {
  const h = harness();
  await h.bridge.configure({ cloudModel: 'cloud-model-x' });
  await expectCode(h.bridge.generate(request('onlyOnDevice')), 'unavailable');
  h.window.LanguageModel = languageModel('available');
  const local = await h.bridge.generate(request('onlyOnDevice'));
  assert.equal(local.source, 'onDevice');
  assert.equal(h.fetches.length, 0);
});
