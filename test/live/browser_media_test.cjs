const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../web/soussight_live.js'), 'utf8');

function eventTarget() {
  const listeners = new Map();
  return {
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(listener);
    },
    removeEventListener(type, listener) { listeners.get(type)?.delete(listener); },
    dispatch(type) { for (const listener of [...(listeners.get(type) ?? [])]) listener(); },
    listenerCount() { return [...listeners.values()].reduce((sum, set) => sum + set.size, 0); },
  };
}

function harness(permission, { frameBytes, audioDisabled = false, now } = {}) {
  const tracks = [{ stopped: false, enabled: true, stop() { this.stopped = true; } }, { stopped: false, enabled: true, stop() { this.stopped = true; } }];
  const stream = { getTracks: () => tracks, getAudioTracks: () => [tracks[1]] };
  const contexts = [];
  const playback = [];
  const intervals = new Set();
  let workletSource;
  const audioAttempts = [];
  class AudioContext {
    constructor() { audioAttempts.push(1); if (audioDisabled) throw new Error('AudioContext creation disabled'); this.state = 'running'; this.currentTime = 0; this.destination = {}; this.audioWorklet = { addModule: async () => {} }; contexts.push(this); }
    resume() { this.resumes = (this.resumes ?? 0) + 1; this.state = 'running'; return Promise.resolve(); }
    close() { this.state = 'closed'; return Promise.resolve(); }
    createMediaStreamSource() { return { connect() {}, disconnect() {} }; }
    createGain() { return { gain: {}, connect() {}, disconnect() {} }; }
    createBuffer(_, count, rate) { return { duration: count / rate, getChannelData: () => new Float32Array(count) }; }
    createBufferSource() {
      const source = { stopped: false, connect() {}, disconnect() {}, start() {}, stop() { this.stopped = true; } };
      playback.push(source);
      return source;
    }
  }
  const constraints = [];
  const video = { videoWidth: 768, videoHeight: 768, play: async () => {}, pause() {} };
  const canvas = { getContext: () => ({ drawImage() {} }), toBlob: callback => callback({ arrayBuffer: frameBytes ?? (async () => new Uint8Array([1, 2, 3]).buffer) }) };
  const sandbox = {
    window: { isSecureContext: true, AudioContext, ...eventTarget() },
    document: { hidden: false, createElement: name => name === 'video' ? video : canvas, ...eventTarget() },
    navigator: { mediaDevices: { getUserMedia: request => { constraints.push(request); return (permission ?? (async () => stream))(request); } } },
    AudioWorkletNode: class { constructor() { if (audioDisabled) throw new Error('AudioWorkletNode creation disabled'); this.port = {}; } connect() {} disconnect() {} },
    Blob: class { constructor(parts) { workletSource = parts.join(''); } },
    URL: { createObjectURL: () => 'blob:worklet', revokeObjectURL() {} },
    setInterval: () => { intervals.add(1); return 1; }, clearInterval: id => intervals.delete(id),
    Uint8Array, Float32Array, Int16Array, DataView, ArrayBuffer, Math, Promise,
    Date: { now: now ?? (() => 1700000000000) },
  };
  vm.runInNewContext(source, sandbox);
  return { bridge: sandbox.soussightLive, stream, tracks, contexts, audioAttempts, constraints, playback, intervals, window: sandbox.window, document: sandbox.document, getWorklet: () => workletSource };
}

test('stopping while camera permission is pending releases a late stream', async () => {
  let grant;
  const permission = new Promise(resolve => { grant = resolve; });
  const h = harness(() => permission);
  let sent = 0;
  const media = h.bridge.create(() => sent++, () => sent++, () => {});
  const starting = media.start();
  media.stop();
  grant(h.stream);
  await starting;
  assert.equal(h.tracks.every(track => track.stopped), true);
  assert.equal(h.contexts[0].state, 'closed');
  assert.equal(sent, 0);
});

test('mute blocks outgoing microphone and stop shuts down all capture tracks', async () => {
  const h = harness();
  const chunks = [];
  const media = h.bridge.create(value => chunks.push(value), () => {}, () => {});
  await media.start();
  media.worklet.port.onmessage({ data: new ArrayBuffer(8) });
  media.mute(true);
  media.worklet.port.onmessage({ data: new ArrayBuffer(8) });
  assert.equal(chunks.length, 1);
  assert.equal(h.tracks[1].enabled, false);
  media.stop();
  assert.equal(h.tracks.every(track => track.stopped), true);
  assert.equal(h.contexts[0].state, 'closed');
});

test('worklet converts 48 kHz microphone samples into 100ms PCM16 little-endian packets', async () => {
  const h = harness();
  const media = h.bridge.create(() => {}, () => {}, () => {});
  await media.start();
  let Worklet;
  const packets = [];
  vm.runInNewContext(h.getWorklet(), {
    AudioWorkletProcessor: class { constructor() { this.port = { postMessage: value => packets.push(value) }; } },
    sampleRate: 48000,
    registerProcessor: (_, type) => { Worklet = type; },
    Int16Array, ArrayBuffer, DataView, Math,
  });
  const worklet = new Worklet();
  worklet.process([[new Float32Array(4800).fill(0.5)]]);
  assert.equal(packets.length, 1);
  assert.equal(packets[0].byteLength, 3200);
  assert.equal(new DataView(packets[0]).getInt16(0, true), 16384);
  media.stop();
});

for (const reason of ['hidden tab', 'page exit', 'device disconnect']) {
  test(`${reason} releases capture and playback and discards a pending frame`, async () => {
    let releaseFrame;
    const frame = new Promise(resolve => { releaseFrame = resolve; });
    const h = harness(undefined, { frameBytes: () => frame });
    const frames = [];
    const errors = [];
    const media = h.bridge.create(() => {}, value => frames.push(value), error => errors.push(error));
    await media.start();
    await Promise.resolve();
    assert.equal(media.frameBusy, true);
    media.play(new Uint8Array([0, 1, 0, 2]));
    assert.equal(h.playback.length, 1);
    assert.equal(h.document.listenerCount(), 1);
    assert.equal(h.window.listenerCount(), 1);
    if (reason === 'hidden tab') {
      // Becoming visible must not stop an otherwise active session.
      h.document.dispatch('visibilitychange');
      assert.equal(media.active, true);
      h.document.hidden = true;
      h.document.dispatch('visibilitychange');
    } else if (reason === 'page exit') {
      h.window.dispatch('pagehide');
    } else {
      h.tracks[0].onended();
    }
    releaseFrame(new Uint8Array([1, 2, 3]).buffer);
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(media.active, false);
    assert.equal(h.tracks.every(track => track.stopped && track.onended === null), true);
    assert.equal(h.contexts[0].state, 'closed');
    assert.equal(h.playback.every(source => source.stopped), true);
    assert.equal(h.intervals.size, 0);
    assert.equal(h.document.listenerCount(), 0);
    assert.equal(h.window.listenerCount(), 0);
    assert.equal(frames.length, 0);
    assert.equal(errors.length, reason === 'page exit' ? 0 : 1);
    h.document.hidden = false;
    h.document.dispatch('visibilitychange');
    assert.equal(media.active, false);
  });
}

test('playback keeps long answers queued, resumes a suspended context and flushes only past 60s', async () => {
  const h = harness();
  const media = h.bridge.create(() => {}, () => {}, () => {});
  await media.start();
  const context = h.contexts[0];
  const before = context.resumes ?? 0;
  context.state = 'suspended';
  // 24 kHz PCM16: 48000 bytes per second; enqueue 30 seconds of speech.
  const second = new Uint8Array(48000);
  for (let i = 0; i < 30; i++) media.play(second);
  assert.equal(context.resumes, before + 1);
  assert.equal(context.state, 'running');
  assert.equal(h.playback.length, 30);
  assert.equal(h.playback.some(source => source.stopped), false);
  // Push past the 60s runaway threshold; the stale queue is flushed once.
  for (let i = 0; i < 32; i++) media.play(second);
  assert.equal(h.playback.filter(source => source.stopped).length > 0, true);
  media.stop();
});


const flush = () => new Promise(resolve => setImmediate(resolve));

function videoOnlyStream() {
  const tracks = [{ stopped: false, enabled: true, stop() { this.stopped = true; } }];
  return { getTracks: () => tracks, getAudioTracks: () => [], tracks };
}

// Grants the camera but denies the microphone, like a cook who blocked the mic.
function cameraOnlyPermission(stream) {
  return async request => {
    if (request.audio) { const error = new Error('Permission denied'); error.name = 'NotAllowedError'; throw error; }
    return stream;
  };
}

test('camera-only capture delivers stamped frames with audio creation disabled and the microphone denied', async () => {
  const video = videoOnlyStream();
  let clock = 1700000000000;
  const h = harness(cameraOnlyPermission(video), { audioDisabled: true, now: () => clock });
  const frames = [];
  const audio = [];
  const errors = [];
  const media = h.bridge.create(value => audio.push(value), (bytes, capturedAt) => frames.push({ bytes, capturedAt }), error => errors.push(error));
  // The full audio/video start fails with the microphone denied ...
  await assert.rejects(media.start(), /Permission denied|AudioContext creation disabled/);
  assert.equal(h.audioAttempts.length, 1);
  // ... but the camera-only path never touches audio and still works.
  clock = 1700000005000;
  await media.startCameraOnly();
  await flush();
  assert.equal(h.audioAttempts.length, 1, 'camera-only must not create an AudioContext');
  assert.equal(h.constraints.at(-1).audio, false);
  assert.ok(h.constraints.at(-1).video);
  assert.equal(frames.length, 1);
  assert.deepEqual([...frames[0].bytes], [1, 2, 3]);
  assert.equal(frames[0].capturedAt, 1700000005000);
  assert.equal(media.audioContext, null);
  assert.equal(audio.length, 0);
  // Playback and mute are inert without an audio graph.
  media.play(new Uint8Array([0, 1, 0, 2]));
  media.mute(true);
  assert.equal(h.playback.length, 0);
  media.stop();
  assert.equal(video.tracks.every(track => track.stopped), true);
  assert.equal(h.intervals.size, 0);
  assert.equal(errors.length, 0);
});

test('frames are stamped when acquired, not when the encode finishes', async () => {
  let clock = 1000;
  let releaseFrame;
  const h = harness(async () => videoOnlyStream(), { audioDisabled: true, now: () => clock, frameBytes: () => new Promise(resolve => { releaseFrame = resolve; }) });
  const frames = [];
  const media = h.bridge.create(() => {}, (bytes, capturedAt) => frames.push(capturedAt), () => {});
  await media.startCameraOnly();
  await flush();
  clock = 4000;
  releaseFrame(new Uint8Array([9]).buffer);
  await flush();
  assert.deepEqual(frames, [1000]);
  media.stop();
});

test('stopping camera-only capture while permission is pending releases the late stream and publishes nothing', async () => {
  let grant;
  const video = videoOnlyStream();
  const h = harness(() => new Promise(resolve => { grant = resolve; }), { audioDisabled: true });
  let published = 0;
  const media = h.bridge.create(() => published++, () => published++, () => published++);
  const starting = media.startCameraOnly();
  media.stop();
  grant(video);
  await starting;
  assert.equal(video.tracks.every(track => track.stopped), true);
  assert.equal(h.intervals.size, 0);
  assert.equal(published, 0);
});

test('a frame in flight at handoff is never published into the next capture', async () => {
  const pending = [];
  const h = harness(async () => videoOnlyStream(), { frameBytes: () => new Promise(resolve => pending.push(resolve)) });
  const frames = [];
  const media = h.bridge.create(() => {}, bytes => frames.push([...bytes]), () => {});
  await media.startCameraOnly();
  await flush();
  assert.equal(pending.length, 1);
  // Hand the same object over to the audio/video path before the frame settles.
  await media.start();
  await flush();
  assert.equal(pending.length, 2);
  pending[0](new Uint8Array([7]).buffer);
  await flush();
  assert.deepEqual(frames, []);
  pending[1](new Uint8Array([8]).buffer);
  await flush();
  assert.deepEqual(frames, [[8]]);
  media.stop();
});

test('a disconnected camera stops camera-only capture with a camera-only message', async () => {
  const video = videoOnlyStream();
  const h = harness(async () => video, { audioDisabled: true });
  const errors = [];
  const media = h.bridge.create(() => {}, () => {}, error => errors.push(error));
  await media.startCameraOnly();
  video.tracks[0].onended();
  assert.equal(media.active, false);
  assert.deepEqual(errors, ['Camera disconnected.']);
  assert.equal(h.document.listenerCount(), 0);
});
