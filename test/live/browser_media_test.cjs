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

function harness(permission, { frameBytes } = {}) {
  const tracks = [{ stopped: false, enabled: true, stop() { this.stopped = true; } }, { stopped: false, enabled: true, stop() { this.stopped = true; } }];
  const stream = { getTracks: () => tracks, getAudioTracks: () => [tracks[1]] };
  const contexts = [];
  const playback = [];
  const intervals = new Set();
  let workletSource;
  class AudioContext {
    constructor() { this.state = 'running'; this.currentTime = 0; this.destination = {}; this.audioWorklet = { addModule: async () => {} }; contexts.push(this); }
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
  const video = { videoWidth: 768, videoHeight: 768, play: async () => {}, pause() {} };
  const canvas = { getContext: () => ({ drawImage() {} }), toBlob: callback => callback({ arrayBuffer: frameBytes ?? (async () => new Uint8Array([1, 2, 3]).buffer) }) };
  const sandbox = {
    window: { isSecureContext: true, AudioContext, ...eventTarget() },
    document: { hidden: false, createElement: name => name === 'video' ? video : canvas, ...eventTarget() },
    navigator: { mediaDevices: { getUserMedia: permission ?? (async () => stream) } },
    AudioWorkletNode: class { constructor() { this.port = {}; } connect() {} disconnect() {} },
    Blob: class { constructor(parts) { workletSource = parts.join(''); } },
    URL: { createObjectURL: () => 'blob:worklet', revokeObjectURL() {} },
    setInterval: () => { intervals.add(1); return 1; }, clearInterval: id => intervals.delete(id),
    Uint8Array, Float32Array, Int16Array, DataView, ArrayBuffer, Math, Promise,
  };
  vm.runInNewContext(source, sandbox);
  return { bridge: sandbox.soussightLive, stream, tracks, contexts, playback, intervals, window: sandbox.window, document: sandbox.document, getWorklet: () => workletSource };
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
