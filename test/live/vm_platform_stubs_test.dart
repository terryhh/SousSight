// The VM/native halves of conditional imports. On a phone or desktop host
// these answer "unsupported" in a way the UI can show, instead of crashing.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/live/browser_live_media.dart';
import 'package:soussight/live/native_live_media_factory_stub.dart'
    as web_factory;
import 'package:soussight/nearby/geolocation.dart';

void main() {
  group('browser live media off the web', () {
    test(
      'every stream is empty and capture is refused with a clear reason',
      () async {
        final media = createBrowserLiveMedia();
        expect(await media.microphone.isEmpty, isTrue);
        expect(await media.frames.isEmpty, isTrue);
        expect(await media.timedFrames.isEmpty, isTrue);
        expect(await media.errors.isEmpty, isTrue);
        for (final start in [media.start, media.startCameraOnly]) {
          await expectLater(
            start(),
            throwsA(
              isA<UnsupportedError>().having(
                (e) => e.message,
                'message',
                'The cooking camera currently requires a browser.',
              ),
            ),
          );
        }
      },
    );

    test('stop, mute and playback calls are harmless no-ops', () async {
      final media = createBrowserLiveMedia();
      media
        ..setMicrophoneMuted(true)
        ..playAudio(Uint8List(4))
        ..interruptPlayback();
      await expectLater(media.stop(), completes);
    });
  });

  test('web builds never construct native capture', () {
    expect(web_factory.createNativeLiveMedia, throwsA(isA<UnsupportedError>()));
  });

  test('geolocation off the web asks the cook to type a place instead', () {
    expect(locateOnce(), throwsA(isA<LocationUnavailable>()));
  });
}
