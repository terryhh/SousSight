// Web backend of the ai_logic_hybrid bridge (docs/buildhybridai/DESIGN.md §3 Web, §4).
//
// A classic script, injected at app start by AiLogicHybridWeb.registerWith. It exposes
// globalThis.aiLogicHybrid over the Firebase AI Logic JS SDK (firebase-ai.js), loaded
// by dynamic import at the exact version FlutterFire loaded (firebase_core.SDK_VERSION),
// and over Chrome's built-in LanguageModel (Prompt API) for availability and download.
//
// Facts this relies on were read from the shipped firebase-ai.js 13.1.0 bundle:
// - getGenerativeModel(ai, {mode, inCloudParams, onDeviceParams}); top-level config is
//   ignored once `mode` is set, so everything goes into inCloudParams / onDeviceParams.
// - The SDK does NOT forward systemInstruction or responseSchema to the local model. The
//   bridge sets onDeviceParams.createOptions.initialPrompts and
//   onDeviceParams.promptOptions.responseConstraint itself. Whether Chrome honours that
//   exact shape is Unproven until gate G2b runs on real hardware.
// - Those options live on the model instance, so instances are cached by the FULL config.
// - result.response.inferenceSource is 'on_device' | 'in_cloud'.
// Nothing here has run against a live model. Tests stub LanguageModel and either stub
// the SDK or run the shipped 13.1.0 bundle offline with a stubbed fetch.
(function (root) {
  'use strict';

  const MODES = Object.freeze({
    preferOnDevice: 'prefer_on_device',
    onlyOnDevice: 'only_on_device',
    preferInCloud: 'prefer_in_cloud',
    onlyInCloud: 'only_in_cloud',
  });
  const SOURCES = Object.freeze({ on_device: 'onDevice', in_cloud: 'cloud' });
  const STATUSES = new Set(['available', 'downloadable', 'downloading', 'unavailable']);

  // Attachment limits for every route (DESIGN §4). Local types follow the SDK's
  // ChromeAdapterImpl.SUPPORTED_MIME_TYPES.
  const LIMITS = Object.freeze({ maxImages: 1, maxImageBytes: 1024 * 1024, maxImageDimension: 768 });
  const IMAGE_TYPES = new Set(['image/jpeg', 'image/png']);

  // Limits of Chrome's local model (Docs, not measured). imageTokenEstimate is a guess
  // until G2b measures it.
  const LOCAL = Object.freeze({
    modelFamily: 'Gemini Nano',
    supportsImage: true,
    supportsJsonSchema: true,
    maxTotalTokens: 9216,
    defaultOutputReserve: 512,
    imageTokenEstimate: 1000,
    validatedLanguages: ['en', 'es', 'ja'],
  });

  const MAX_MODELS = 16;
  const DEFAULT_TIMEOUT_MS = 30000;

  function hybridError(code, message) {
    const error = new Error(message);
    error.name = 'HybridError';
    error.code = code;
    error.hybrid = true;
    return error;
  }

  // Maps SDK (AIError codes), Prompt API (DOMException names) and fetch failures to
  // HybridErrorCode names.
  function toHybridError(e) {
    if (e && e.hybrid) return e;
    const message = String((e && e.message) || e || 'unknown error');
    const code = e && e.code;
    switch (code) {
      case 'fetch-error': {
        const status = e.customErrorData && e.customErrorData.status;
        if (status === 429) return hybridError('quota', message);
        if (status === 401 || status === 403) return hybridError('attestation', message);
        if (status === 503) return hybridError('busy', message);
        if (status === 408 || status === 504) return hybridError('network', message);
        return hybridError('failed', message);
      }
      case 'api-not-enabled':
      case 'unsupported':
        return hybridError('unavailable', message);
      case 'request-error':
      case 'invalid-content':
      case 'invalid-schema':
        return hybridError('unsupportedInput', message);
      case 'response-error':
        return hybridError('blocked', message);
      case 'error':
        return hybridError(/Error fetching from/.test(message) ? 'network' : 'failed', message);
      default:
        break;
    }
    switch (e && e.name) {
      case 'QuotaExceededError': return hybridError('unsupportedInput', message); // prompt too long
      case 'NotSupportedError':
      case 'NotAllowedError': return hybridError('unavailable', message);
      case 'NetworkError': return hybridError('network', message);
      case 'AbortError': return hybridError('cancelled', message);
      case 'TypeError': if (/fetch/i.test(message)) return hybridError('network', message); break;
      default: break;
    }
    return hybridError('failed', message);
  }

  // Stable JSON with sorted keys, so equal schemas give equal cache keys.
  function stableStringify(value) {
    if (value === null || value === undefined) return 'null';
    if (Array.isArray(value)) return '[' + value.map(stableStringify).join(',') + ']';
    if (typeof value === 'object') {
      return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + stableStringify(value[k])).join(',') + '}';
    }
    return JSON.stringify(value);
  }

  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function base64(bytes) {
    let out = '';
    let i = 0;
    for (; i + 2 < bytes.length; i += 3) {
      const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    if (i < bytes.length) {
      const n = (bytes[i] << 16) | ((i + 1 < bytes.length ? bytes[i + 1] : 0) << 8);
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63];
      out += i + 1 < bytes.length ? B64[(n >> 6) & 63] + '=' : '==';
    }
    return out;
  }

  // Reads width/height from a PNG or JPEG header without decoding. Null if unknown.
  function imageSize(bytes) {
    const b = bytes;
    if (b.length >= 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
      const u32 = o => ((b[o] << 24) >>> 0) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3];
      return { width: u32(16), height: u32(20) };
    }
    if (b.length >= 4 && b[0] === 0xff && b[1] === 0xd8) {
      let i = 2;
      while (i + 3 < b.length) {
        if (b[i] !== 0xff) return null;
        const marker = b[i + 1];
        if (marker === 0xff) { i += 1; continue; }
        if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) { i += 2; continue; }
        const length = (b[i + 2] << 8) | b[i + 3];
        const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
        if (isSof && i + 8 < b.length) {
          return { height: (b[i + 5] << 8) | b[i + 6], width: (b[i + 7] << 8) | b[i + 8] };
        }
        if (length < 2) return null;
        i += 2 + length;
      }
    }
    return null;
  }

  function create(deps) {
    deps = deps || {};
    const g = deps.global || root;
    const importer = deps.importer || (url => import(url));
    const getLanguageModel = () => ('languageModel' in deps ? deps.languageModel : g.LanguageModel);
    const setTimer = deps.setTimeout || ((fn, ms) => g.setTimeout(fn, ms));
    const clearTimer = deps.clearTimeout || (id => g.clearTimeout(id));
    const AbortCtl = deps.AbortController || g.AbortController;

    let config = null;
    let sdkPromise = null;
    const models = new Map();
    const inflight = new Map();
    const cancelledEarly = new Set();
    const preparing = new Map();

    function languages() {
      return config && Array.isArray(config.languages) && config.languages.length ? config.languages.slice() : ['en'];
    }

    // A request's own languages (e.g. a translation answered in Spanish), else the
    // configured ones. Only that request's model uses them; other features keep theirs.
    function requestLanguages(request) {
      return request && Array.isArray(request.languages) && request.languages.length
        ? request.languages.map(String)
        : languages();
    }

    // The same create options are used for availability, download and generation, so
    // download readiness is a per-modality fact that matches what generate will ask for.
    function createOptions(withImage, langs) {
      const list = langs || languages();
      const text = { type: 'text', languages: list };
      return {
        expectedInputs: withImage ? [text, { type: 'image' }] : [text],
        expectedOutputs: [{ type: 'text', languages: list }],
      };
    }

    function loadSdk() {
      if (!sdkPromise) {
        sdkPromise = (async () => {
          const core = g.firebase_core;
          const version = core && core.SDK_VERSION;
          if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version) || typeof core.getApp !== 'function') {
            throw hybridError('unavailable', 'bridge_unavailable: Firebase JS core is not loaded');
          }
          const sdk = await importer(`https://www.gstatic.com/firebasejs/${version}/firebase-ai.js`);
          // firebase-ai.js imports firebase-app.js from the same versioned path, which is
          // the module FlutterFire stored on window.firebase_core, so this is its app.
          const ai = sdk.getAI(core.getApp(), { backend: new sdk.GoogleAIBackend() });
          return { sdk, ai };
        })();
        sdkPromise.catch(() => { sdkPromise = null; });
      }
      return sdkPromise;
    }

    async function bridgeReady() {
      try { await loadSdk(); return true; } catch (_) { return false; }
    }

    function modelFor(sdk, ai, request, withImage) {
      const schema = request.jsonSchema == null ? null : request.jsonSchema;
      const instruction = request.systemInstruction == null ? null : String(request.systemInstruction);
      const key = stableStringify([
        request.mode, withImage, config.cloudModel, instruction, schema, request.maxOutputTokens || null, requestLanguages(request),
        !!getLanguageModel(), // an instance built without LanguageModel has no local adapter
      ]);
      const cached = models.get(key);
      if (cached) {
        models.delete(key);
        models.set(key, cached);
        return cached;
      }
      const generationConfig = {};
      if (request.maxOutputTokens) generationConfig.maxOutputTokens = request.maxOutputTokens;
      if (schema) {
        generationConfig.responseMimeType = 'application/json';
        generationConfig.responseSchema = schema;
      }
      const inCloudParams = { model: config.cloudModel, generationConfig };
      if (instruction) inCloudParams.systemInstruction = instruction;
      const onDeviceCreate = createOptions(withImage, requestLanguages(request));
      if (instruction) onDeviceCreate.initialPrompts = [{ role: 'system', content: instruction }];
      const onDeviceParams = { createOptions: onDeviceCreate };
      if (schema) onDeviceParams.promptOptions = { responseConstraint: schema };
      const model = sdk.getGenerativeModel(ai, { mode: MODES[request.mode], inCloudParams, onDeviceParams });
      models.set(key, model);
      while (models.size > MAX_MODELS) models.delete(models.keys().next().value);
      return model;
    }

    // Attachment limits (every route) and the local token budget (onlyOnDevice).
    function checkInput(request) {
      const parts = Array.isArray(request.parts) ? request.parts : [];
      if (!parts.length) throw hybridError('unsupportedInput', 'A request needs at least one part.');
      let images = 0;
      let chars = (request.systemInstruction ? String(request.systemInstruction).length : 0)
        + (request.jsonSchema ? JSON.stringify(request.jsonSchema).length : 0);
      for (const part of parts) {
        if (part && part.type === 'text' && typeof part.text === 'string') {
          chars += part.text.length;
        } else if (part && part.type === 'inlineData') {
          images += 1;
          const bytes = part.bytes;
          if (!IMAGE_TYPES.has(part.mimeType)) throw hybridError('unsupportedInput', `Unsupported attachment type ${part.mimeType}.`);
          if (!bytes || typeof bytes.length !== 'number') throw hybridError('unsupportedInput', 'Attachment has no bytes.');
          if (bytes.length > LIMITS.maxImageBytes) throw hybridError('unsupportedInput', `Image is ${bytes.length} bytes; the limit is ${LIMITS.maxImageBytes}.`);
          const size = imageSize(bytes);
          if (size && (size.width > LIMITS.maxImageDimension || size.height > LIMITS.maxImageDimension)) {
            throw hybridError('unsupportedInput', `Image is ${size.width}x${size.height}; the limit is ${LIMITS.maxImageDimension} px.`);
          }
        } else {
          throw hybridError('unsupportedInput', 'Only text and one image part are supported.');
        }
      }
      if (images > LIMITS.maxImages) throw hybridError('unsupportedInput', `At most ${LIMITS.maxImages} image per request.`);
      if (request.mode === 'onlyOnDevice') {
        const budget = Math.ceil(chars / 4) + images * LOCAL.imageTokenEstimate + (request.maxOutputTokens || 0);
        if (budget > LOCAL.maxTotalTokens) {
          throw hybridError('unsupportedInput', `Estimated ${budget} tokens exceeds the local limit of ${LOCAL.maxTotalTokens}.`);
        }
      }
      return images > 0;
    }

    function toContents(parts) {
      return [{
        role: 'user',
        parts: parts.map(p => (p.type === 'text'
          ? { text: p.text }
          : { inlineData: { mimeType: p.mimeType, data: base64(p.bytes) } })),
      }];
    }

    // A local-only request must never reach the SDK unless the local model is present
    // and ready for this modality. In firebase-ai.js 13.1.0, a model built while
    // LanguageModel is absent has no on-device adapter, and callCloudOrDevice then runs
    // the CLOUD path even for only_on_device; checking the source afterwards would be
    // too late, because the payload would already have been uploaded.
    async function requireLocalReady(withImage) {
      const lm = getLanguageModel();
      if (!lm || typeof lm.availability !== 'function') {
        throw hybridError('unavailable', 'unsupported_browser: no local model in this browser.');
      }
      let status;
      try { status = await lm.availability(createOptions(withImage)); } catch (e) {
        throw hybridError('unavailable', 'availability_error: ' + (e && e.message));
      }
      if (status !== 'available') {
        throw hybridError('unavailable', `model_not_ready: local model is ${status} for ${withImage ? 'image' : 'text'} input.`);
      }
    }

    // `isCurrent` is false once the request timed out or was cancelled. It is checked
    // after every await, so abandoned work never goes on to send anything.
    async function run(request, withImage, signal, isCurrent) {
      const stale = () => { if (!isCurrent()) throw hybridError('cancelled', 'request is no longer current'); };
      const localOnly = request.mode === 'onlyOnDevice';
      if (localOnly) { await requireLocalReady(withImage); stale(); }
      let loaded;
      try { loaded = await loadSdk(); } catch (e) { throw hybridError('unavailable', 'bridge_unavailable: ' + (e && e.message)); }
      stale();
      // Re-checked synchronously right before the instance is built and the call made:
      // the SDK reads window.LanguageModel when it creates the instance.
      if (localOnly && !getLanguageModel()) throw hybridError('unavailable', 'unsupported_browser: local model disappeared.');
      const model = modelFor(loaded.sdk, loaded.ai, request, withImage);
      const options = { timeout: request.timeoutMs };
      if (signal) options.signal = signal;
      const result = await model.generateContent({ contents: toContents(request.parts) }, options);
      const response = result && result.response;
      const source = response && SOURCES[response.inferenceSource];
      if (!source) throw hybridError('failed', 'The SDK did not report an inference source.');
      // Second line of defence: refuse a result that contradicts the mode rather than
      // report it. (For onlyOnDevice the guard above is what keeps data on the device.)
      if ((request.mode === 'onlyOnDevice' && source !== 'onDevice') || (request.mode === 'onlyInCloud' && source !== 'cloud')) {
        throw hybridError('failed', `Mode ${request.mode} produced a ${source} result.`);
      }
      const text = response.text();
      return { requestId: request.requestId, text: typeof text === 'string' ? text : '', source, modelLabel: null };
    }

    const bridge = {
      version: 1,

      async configure(next) {
        if (!next || typeof next.cloudModel !== 'string' || !next.cloudModel) {
          throw hybridError('failed', 'configure needs a cloudModel.');
        }
        config = {
          cloudModel: next.cloudModel,
          androidModel: next.androidModel,
          languages: Array.isArray(next.languages) ? next.languages.map(String) : ['en'],
        };
        models.clear();
        await bridgeReady(); // warm the SDK import; a missing bridge is reported, not thrown
      },

      async capabilities() {
        if (!(await bridgeReady())) {
          return { platform: 'none', local: null, ...LIMITS, supportedModes: [] };
        }
        const hasLocal = !!getLanguageModel();
        return {
          platform: 'web',
          local: hasLocal ? { ...LOCAL, validatedLanguages: LOCAL.validatedLanguages.slice() } : null,
          ...LIMITS,
          supportedModes: hasLocal
            ? ['preferOnDevice', 'onlyOnDevice', 'preferInCloud', 'onlyInCloud']
            : ['preferOnDevice', 'preferInCloud', 'onlyInCloud'],
        };
      },

      async availability(args) {
        const withImage = !!(args && args.withImage);
        if (!(await bridgeReady())) return { status: 'unavailable', reason: 'bridge_unavailable' };
        const lm = getLanguageModel();
        if (!lm || typeof lm.availability !== 'function') return { status: 'unavailable', reason: 'unsupported_browser' };
        let raw;
        try {
          raw = await lm.availability(createOptions(withImage));
        } catch (_) {
          return { status: 'unavailable', reason: withImage ? 'image_input_unavailable' : 'device_not_eligible' };
        }
        if (!STATUSES.has(raw)) return { status: 'unavailable', reason: 'unknown_status' };
        if (raw === 'unavailable') {
          return { status: 'unavailable', reason: withImage ? 'image_input_unavailable' : 'device_not_eligible' };
        }
        return raw === 'available' ? { status: raw } : { status: raw, reason: 'model_not_ready' };
      },

      // Starts the download synchronously, inside the caller's user gesture, by calling
      // LanguageModel.create with a download monitor (what the SDK's initializeDeviceModel
      // does, minus the awaits before it). Settles when the model is ready. Concurrent
      // calls for one modality share one download.
      prepare(args, onProgress) {
        const withImage = !!(args && args.withImage);
        const key = withImage ? 'image' : 'text';
        const report = typeof onProgress === 'function' ? onProgress : null;
        const existing = preparing.get(key);
        if (existing) {
          if (report) existing.listeners.add(report);
          return existing.promise;
        }
        const lm = getLanguageModel();
        if (!lm || typeof lm.create !== 'function') {
          return Promise.reject(hybridError('unavailable', 'unsupported_browser: LanguageModel is not available.'));
        }
        const listeners = new Set(report ? [report] : []);
        const emit = value => { for (const l of listeners) { try { l(value); } catch (_) { /* ignore */ } } };
        let created;
        try {
          created = lm.create({
            ...createOptions(withImage),
            monitor(m) {
              m.addEventListener('downloadprogress', event => {
                const loaded = Number(event && event.loaded);
                emit(Number.isFinite(loaded) ? Math.min(1, Math.max(0, loaded)) : null);
              });
            },
          });
        } catch (e) {
          return Promise.reject(toHybridError(e));
        }
        const promise = Promise.resolve(created).then(
          session => { try { session && session.destroy && session.destroy(); } catch (_) { /* ignore */ } },
          e => { throw toHybridError(e); },
        ).finally(() => { preparing.delete(key); });
        preparing.set(key, { promise, listeners });
        return promise;
      },

      generate(request) {
        return new Promise((resolve, reject) => {
          const id = request && request.requestId;
          if (typeof id !== 'string' || !id) { reject(hybridError('failed', 'generate needs a requestId.')); return; }
          if (cancelledEarly.delete(id)) { reject(hybridError('cancelled', 'cancelled before start')); return; }
          if (inflight.has(id)) { reject(hybridError('failed', `requestId ${id} is already running.`)); return; }
          if (!Object.prototype.hasOwnProperty.call(MODES, request.mode)) {
            reject(hybridError('unsupportedMode', `Unknown mode ${request.mode}.`)); return;
          }
          if (!config) { reject(hybridError('failed', 'configure() was not called.')); return; }
          let withImage;
          try { withImage = checkInput(request); } catch (e) { reject(e); return; }

          const controller = AbortCtl ? new AbortCtl() : null;
          const timeoutMs = Number.isFinite(request.timeoutMs) && request.timeoutMs > 0 ? request.timeoutMs : DEFAULT_TIMEOUT_MS;
          const entry = {
            settle(error, value) {
              if (inflight.get(id) !== entry) return; // late result after timeout/cancel: discarded
              inflight.delete(id);
              clearTimer(entry.timer);
              if (error) reject(error); else resolve(value);
            },
            abort(code, message) {
              if (inflight.get(id) !== entry) return;
              try { controller && controller.abort(); } catch (_) { /* ignore */ }
              entry.settle(hybridError(code, message));
            },
          };
          inflight.set(id, entry);
          entry.timer = setTimer(() => entry.abort('timeout', `No result within ${timeoutMs} ms.`), timeoutMs);
          run({ ...request, timeoutMs }, withImage, controller && controller.signal, () => inflight.get(id) === entry).then(
            value => entry.settle(null, value),
            e => entry.settle(toHybridError(e)),
          );
        });
      },

      // Cloud calls are aborted; a local prompt cannot be interrupted through the SDK, so
      // it is abandoned: the caller gets `cancelled` now and the late result is dropped.
      async cancel(requestId) {
        const entry = inflight.get(requestId);
        if (entry) { entry.abort('cancelled', 'cancelled'); return; }
        cancelledEarly.add(requestId);
        if (cancelledEarly.size > 64) cancelledEarly.delete(cancelledEarly.values().next().value);
      },

      // For Dart: turns a promise into {ok, value} | {ok: false, code, message} so the
      // Dart side never depends on how a compiler surfaces a JS rejection.
      settle(promise) {
        return Promise.resolve(promise).then(
          value => ({ ok: true, value }),
          e => { const h = toHybridError(e); return { ok: false, code: h.code, message: h.message }; },
        );
      },
    };
    return bridge;
  }

  if (!root.aiLogicHybrid) {
    const bridge = create();
    bridge.create = create;
    bridge._internals = { imageSize, base64, stableStringify, toHybridError };
    root.aiLogicHybrid = bridge;
  }
})(globalThis);
