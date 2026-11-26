// Web read-aloud through the browser's Web Speech API.
//
// flutter_tts's web plugin is not used here: it ignores a speak that follows a
// stop until the browser's asynchronous end event arrives, and it does not
// expose whether a voice is local. The browser reports `localService` per
// voice; a local English voice is preferred, and when there is none the UI
// says the browser may use an online voice service.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'tts.dart';

TextToSpeech createDeviceTextToSpeech() => WebTextToSpeech();

class WebTextToSpeech implements TextToSpeech {
  bool get _supported {
    try {
      return (web.window as JSObject).has('speechSynthesis') &&
          globalContext.has('SpeechSynthesisUtterance');
    } catch (_) {
      return false;
    }
  }

  web.SpeechSynthesisVoice? _localVoice() {
    try {
      for (final voice in web.window.speechSynthesis.getVoices().toDart) {
        if (voice.localService && voice.lang.toLowerCase().startsWith('en')) {
          return voice;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<TtsSupport> probe() async {
    if (!_supported) return TtsSupport.unavailable;
    return TtsSupport(
      available: true,
      locality: _localVoice() == null
          ? VoiceLocality.browserMayUseNetwork
          : VoiceLocality.browserLocal,
    );
  }

  @override
  Future<bool> speak(String text, {bool localVoiceOnly = false}) async {
    if (!_supported) return false;
    final synth = web.window.speechSynthesis;
    synth.cancel();
    final voice = _localVoice();
    // Local-only: never fall back to the browser's default voice, which may
    // be an online service.
    if (voice == null && localVoiceOnly) return false;
    final utterance = web.SpeechSynthesisUtterance(text);
    if (voice != null) {
      utterance.voice = voice;
      utterance.lang = voice.lang;
    } else {
      utterance.lang = 'en-US';
    }
    synth.speak(utterance);
    return true;
  }

  @override
  Future<void> stop() async {
    if (_supported) web.window.speechSynthesis.cancel();
  }
}
