// Android and iOS: no read-aloud yet, so the speaker toggle stays hidden.
//
// flutter_tts was dropped: it has no Swift Package Manager support, and the
// iOS build is SwiftPM-only. A native voice can be added later behind the
// same TextToSpeech interface (Android TextToSpeech, iOS
// AVSpeechSynthesizer) without touching CoachLiteSpeaker or the toggle.

import 'tts.dart';

TextToSpeech createDeviceTextToSpeech() => const UnavailableTextToSpeech();

class UnavailableTextToSpeech implements TextToSpeech {
  const UnavailableTextToSpeech();

  @override
  Future<TtsSupport> probe() async => TtsSupport.unavailable;

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}
