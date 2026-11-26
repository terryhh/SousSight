// Practice-mode read-aloud caption (Codex #221).

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/coach_lite/tts.dart';
import 'package:soussight/coach_lite/tts_toggle.dart';

void main() {
  test('practice mode: local voice only, and says so', () {
    expect(
      readAloudCaption(VoiceLocality.browserLocal, practice: true),
      'Practice mode: only a voice on this device is used, never an online '
      'one.',
    );
    expect(
      readAloudCaption(VoiceLocality.deviceEngine, practice: true),
      startsWith('Practice mode: only a voice on this device'),
    );
    for (final (locality, silenced) in [
      (VoiceLocality.browserMayUseNetwork, false),
      (VoiceLocality.browserLocal, true),
    ]) {
      expect(
        readAloudCaption(
          locality,
          practice: true,
          silencedForLocalOnly: silenced,
        ),
        contains('Nothing is sent to an online voice'),
      );
    }
  });
}
