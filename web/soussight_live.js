/* SousSight browser camera + PCM audio bridge. Loaded before Flutter bootstrap.
   start() captures camera and microphone for Live; startCameraOnly() captures
   the camera alone for the on-device watch. Frames are published as
   onFrame(jpegBytes, capturedAtMillis). */
(() => {
  'use strict';
  const workletSource = `
class SousSightPcmInput extends AudioWorkletProcessor {
  constructor() {
    super();
    this.phase = 0; this.sum = 0; this.count = 0;
    this.samples = new Int16Array(1600); this.index = 0;
  }
  process(inputs) {
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    for (const sample of channel) {
      this.sum += sample; this.count++; this.phase += 16000;
      if (this.phase >= sampleRate) {
        this.phase -= sampleRate;
        const value = Math.max(-1, Math.min(1, this.sum / this.count));
        this.samples[this.index++] = Math.round(value * (value < 0 ? 32768 : 32767));
        this.sum = 0; this.count = 0;
        if (this.index === this.samples.length) {
          const buffer = new ArrayBuffer(this.samples.length * 2);
          const view = new DataView(buffer);
          for (let i = 0; i < this.samples.length; i++) view.setInt16(i * 2, this.samples[i], true);
          this.port.postMessage(buffer, [buffer]); this.index = 0;
        }
      }
    }
    return true;
  }
}
registerProcessor('soussight-pcm-input', SousSightPcmInput);
`;

  class CookingMedia {
    constructor(onAudio, onFrame, onError) {
      this.onAudio = onAudio; this.onFrame = onFrame; this.onError = onError;
      this.active = false; this.muted = false; this.sources = new Set();
      this.nextPlayAt = 0; this.frameBusy = false; this.generation = 0;
      this.onHidden = () => {
        if (document.hidden && this.active) {
          this.stop();
          this.onError('Camera paused because this tab is hidden. Return and reconnect.');
        }
      };
      this.onPageHide = () => this.stop();
    }
    // Camera and microphone for the Live coach.
    start() { return this.begin(true); }
    // Camera only, for the on-device watch. Never requests the microphone and
    // never creates an AudioContext, so it works with the microphone denied.
    startCameraOnly() { return this.begin(false); }
    async begin(withAudio) {
      if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
        throw new Error(withAudio ? 'Camera and microphone need HTTPS or localhost.' : 'The camera needs HTTPS or localhost.');
      }
      // A second start on the same object first releases the previous capture.
      if (this.active) this.stop();
      this.active = true;
      this.withAudio = withAudio;
      // Each start is a generation; a frame acquired under an older one is never
      // published, even if this object is started again before it settles.
      const generation = ++this.generation;
      this.frameBusy = false;
      let resume = Promise.resolve();
      if (withAudio) {
        // Initialize and resume within the Connect button's user gesture, before
        // permission/network awaits, so Gemini speech can play on mobile browsers.
        const AudioContextType = window.AudioContext || window.webkitAudioContext;
        this.audioContext = new AudioContextType();
        resume = this.audioContext.resume();
      }
      const current = () => this.active && this.generation === generation;
      try {
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: { ideal: 'environment' }, width: { ideal: 768 }, height: { ideal: 768 } },
          audio: withAudio ? { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true } : false
        });
        if (!current()) { stream.getTracks().forEach(track => track.stop()); return; }
        this.stream = stream;
        this.video = document.createElement('video');
        this.video.muted = true; this.video.autoplay = true; this.video.playsInline = true;
        this.video.srcObject = stream;
        await this.video.play();
        await resume;
        if (!current()) return;
        if (withAudio) {
          if (!this.audioContext.audioWorklet) throw new Error('This browser does not support live audio recording.');
          const workletUrl = URL.createObjectURL(new Blob([workletSource], { type: 'application/javascript' }));
          try { await this.audioContext.audioWorklet.addModule(workletUrl); }
          finally { URL.revokeObjectURL(workletUrl); }
          if (!current()) return;
          this.input = this.audioContext.createMediaStreamSource(stream);
          this.worklet = new AudioWorkletNode(this.audioContext, 'soussight-pcm-input');
          this.worklet.port.onmessage = event => {
            if (current() && !this.muted) this.onAudio(new Uint8Array(event.data));
          };
          this.silentGain = this.audioContext.createGain(); this.silentGain.gain.value = 0;
          this.input.connect(this.worklet); this.worklet.connect(this.silentGain);
          this.silentGain.connect(this.audioContext.destination);
        }
        this.canvas = document.createElement('canvas');
        this.frameTimer = setInterval(() => this.captureFrame(), 1000);
        this.captureFrame();
        for (const track of stream.getTracks()) {
          track.onended = () => {
            if (current()) { this.stop(); this.onError(withAudio ? 'Camera or microphone disconnected.' : 'Camera disconnected.'); }
          };
        }
        document.addEventListener('visibilitychange', this.onHidden);
        window.addEventListener('pagehide', this.onPageHide);
      } catch (error) { if (this.generation === generation) this.stop(); throw error; }
    }
    async captureFrame() {
      if (!this.active || this.frameBusy || !this.video?.videoWidth) return;
      const generation = this.generation;
      const current = () => this.active && this.generation === generation;
      this.frameBusy = true;
      try {
        const scale = Math.min(1, 768 / Math.max(this.video.videoWidth, this.video.videoHeight));
        this.canvas.width = Math.round(this.video.videoWidth * scale);
        this.canvas.height = Math.round(this.video.videoHeight * scale);
        // Stamp at acquisition: the encode below can lag behind the pixels.
        const capturedAt = Date.now();
        this.canvas.getContext('2d', { alpha: false }).drawImage(this.video, 0, 0, this.canvas.width, this.canvas.height);
        const blob = await new Promise(resolve => this.canvas.toBlob(resolve, 'image/jpeg', 0.76));
        if (blob && current()) {
          const bytes = new Uint8Array(await blob.arrayBuffer());
          if (current()) this.onFrame(bytes, capturedAt);
        }
      } catch (_) {
        if (current()) { this.stop(); this.onError('Camera frames could not be read. Please reconnect.'); }
      } finally { if (this.generation === generation) this.frameBusy = false; }
    }
    mute(value) {
      this.muted = value;
      this.stream?.getAudioTracks().forEach(track => { track.enabled = !value; });
    }
    play(bytes) {
      if (!this.active || !this.audioContext || bytes.byteLength < 2) return;
      const count = Math.floor(bytes.byteLength / 2);
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      const buffer = this.audioContext.createBuffer(1, count, 24000);
      const samples = buffer.getChannelData(0);
      for (let i = 0; i < count; i++) samples[i] = view.getInt16(i * 2, true) / 32768;
      // Browsers may suspend audio (autoplay policy, backgrounding); resume so
      // queued speech is heard instead of silently piling up.
      if (this.audioContext.state === 'suspended') this.audioContext.resume().catch(() => {});
      // Flush only a runaway queue; long spoken answers can legitimately queue
      // tens of seconds of audio ahead of the playhead.
      if (this.nextPlayAt - this.audioContext.currentTime > 60) this.interrupt();
      const source = this.audioContext.createBufferSource(); source.buffer = buffer;
      source.connect(this.audioContext.destination);
      this.sources.add(source);
      source.onended = () => { this.sources.delete(source); source.disconnect(); };
      const when = Math.max(this.audioContext.currentTime + 0.02, this.nextPlayAt);
      source.start(when); this.nextPlayAt = when + buffer.duration;
    }
    interrupt() {
      for (const source of this.sources) { try { source.stop(); } catch (_) {} }
      this.sources.clear(); this.nextPlayAt = 0;
    }
    stop() {
      this.active = false;
      this.generation++;
      clearInterval(this.frameTimer);
      this.interrupt();
      this.stream?.getTracks().forEach(track => { track.onended = null; track.stop(); });
      this.stream = null;
      if (this.video) { this.video.pause(); this.video.srcObject = null; }
      this.input?.disconnect(); this.worklet?.disconnect(); this.silentGain?.disconnect();
      if (this.worklet) this.worklet.port.onmessage = null;
      if (this.audioContext && this.audioContext.state !== 'closed') this.audioContext.close().catch(() => {});
      this.input = this.worklet = this.silentGain = this.audioContext = null;
      document.removeEventListener('visibilitychange', this.onHidden);
      window.removeEventListener('pagehide', this.onPageHide);
    }
  }
  globalThis.soussightLive = { create: (audio, frame, error) => new CookingMedia(audio, frame, error) };
})();
