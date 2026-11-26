// Runs only in a browser: `flutter test --platform chrome
// test/coach_lite/tts_web_test.dart`. It exercises the real Web Speech API in
// the test browser; it does not show how any voice sounds or where it runs.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/coach_lite/tts.dart';
import 'package:soussight/coach_lite/tts_web.dart';

void main() {
  test('the web build uses the Web Speech API implementation', () {
    expect(deviceTextToSpeech(), isA<WebTextToSpeech>());
  });

  test('probe, speak and stop never throw; locality is never assumed '
      'local without the browser saying so', () async {
    final tts = WebTextToSpeech();
    final support = await tts.probe();
    if (support.available) {
      expect(
        support.locality,
        isIn([VoiceLocality.browserLocal, VoiceLocality.browserMayUseNetwork]),
      );
    } else {
      expect(support.locality, VoiceLocality.browserMayUseNetwork);
    }
    await tts.speak('Stir the sauce.');
    await tts.stop();
  });
}
