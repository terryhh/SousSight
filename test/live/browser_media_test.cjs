const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../web/soussight_live.js'), 'utf8');

function harness(permission) {
  const tracks = [{ stopped: false, enabled: true, stop() { this.stopped = true; } }, { stopped: false, enabled: true, stop() { this.stopped = true; } }];
  const stream = { getTracks: () => tracks, getAudioTracks: () => [tracks[1]] };
  const contexts = [];
  let workletSource;
  class AudioContext {
    constructor() { this.state = 'running'; this.currentTime = 0; this.destination = {}; this.audioWorklet = { addModule: async () => {} }; contexts.push(this); }
    resume() { return Promise.resolve(); }
    close() { this.state = 'closed'; return Promise.resolve(); }
    createMediaStreamSource() { return { connect() {}, disconnect() {} }; }
    createGain() { return { gain: {}, connect() {}, disconnect() {} }; }
  }
  const video = { videoWidth: 768, videoHeight: 768, play: async () => {}, pause() {} };
  const canvas = { getContext: () => ({ drawImage() {} }), toBlob: callback => callback({ arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer }) };
  const sandbox = {
    window: { isSecureContext: true, AudioContext, addEventListener() {}, removeEventListener() {} },
    document: { hidden: false, createElement: name => name === 'video' ? video : canvas, addEventListener() {}, removeEventListener() {} },
    navigator: { mediaDevices: { getUserMedia: permission ?? (async () => stream) } },
    AudioWorkletNode: class { constructor() { this.port = {}; } connect() {} disconnect() {} },
    Blob: class { constructor(parts) { workletSource = parts.join(''); } },
    URL: { createObjectURL: () => 'blob:worklet', revokeObjectURL() {} },
    setInterval: () => 1, clearInterval() {},
    Uint8Array, Float32Array, Int16Array, DataView, ArrayBuffer, Math, Promise,
  };
  vm.runInNewContext(source, sandbox);
  return { bridge: sandbox.soussightLive, stream, tracks, contexts, getWorklet: () => workletSource };
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
