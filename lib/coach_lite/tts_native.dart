// Android and iOS read-aloud through flutter_tts (the OS text-to-speech
// engine: Android TextToSpeech, iOS AVSpeechSynthesizer).

import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import 'tts.dart';

TextToSpeech createDeviceTextToSpeech() => NativeTextToSpeech();

class NativeTextToSpeech implements TextToSpeech {
  FlutterTts? _tts;

  @override
  Future<TtsSupport> probe() async {
    try {
      final tts = _tts ??= FlutterTts();
      // 1 = the engine has this language; 0 = it does not (or, on Android
      // 11+, no engine is visible to the app). Either way, hide the toggle.
      final ok = await tts
          .setLanguage('en-US')
          .timeout(const Duration(seconds: 2));
      return TtsSupport(
        available: ok == 1,
        locality: VoiceLocality.deviceEngine,
      );
    } catch (_) {
      // No plugin (tests, unsupported platform) or no engine.
      return TtsSupport.unavailable;
    }
  }

  @override
  Future<void> speak(String text) async {
    await _tts?.speak(text);
  }

  @override
  Future<void> stop() async {
    await _tts?.stop();
  }
}
