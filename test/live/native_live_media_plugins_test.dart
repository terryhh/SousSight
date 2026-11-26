import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:soussight/live/live_media_factory.dart';
import 'package:soussight/live/native_live_media.dart';
import 'package:soussight/live/native_live_media_plugins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the camera is opened with audio off so it never prompts for the mic',
    () {
      const back = CameraDescription(
        name: '0',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      );
      final controller = PluginNativeCamera.controllerFor(back);

      expect(controller.mediaSettings.enableAudio, isFalse);
      expect(
        controller.mediaSettings.resolutionPreset,
        ResolutionPreset.medium,
      );
    },
  );

  test('microphone capture is PCM16, 16 kHz, mono, echo-cancelled', () {
    expect(kNativeMicrophoneConfig.encoder, AudioEncoder.pcm16bits);
    expect(kNativeMicrophoneConfig.sampleRate, 16000);
    expect(kNativeMicrophoneConfig.numChannels, 1);
    expect(kNativeMicrophoneConfig.echoCancel, isTrue);
  });

  group('frame rotation', () {
    int rotation(
      TargetPlatform platform,
      DeviceOrientation device, {
      int sensor = 90,
      CameraLensDirection lens = CameraLensDirection.back,
    }) => nativeFrameRotation(
      platform: platform,
      sensorOrientation: sensor,
      lensDirection: lens,
      deviceOrientation: device,
    );

    test('Android back camera follows the sensor in portrait', () {
      expect(
        rotation(TargetPlatform.android, DeviceOrientation.portraitUp),
        90,
      );
      expect(
        rotation(TargetPlatform.android, DeviceOrientation.landscapeLeft),
        0,
      );
      expect(
        rotation(TargetPlatform.android, DeviceOrientation.landscapeRight),
        180,
      );
    });

    test('Android front camera adds the device rotation', () {
      expect(
        rotation(
          TargetPlatform.android,
          DeviceOrientation.portraitUp,
          sensor: 270,
          lens: CameraLensDirection.front,
        ),
        270,
      );
    });

    test('iOS frames are already upright', () {
      expect(rotation(TargetPlatform.iOS, DeviceOrientation.portraitUp), 0);
    });
  });

  group('MethodChannelPcmPlayer', () {
    const channel = MethodChannel('test/pcm_player');
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'open' ? 7 : null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('every call carries the token the native side issued', () async {
      final player = MethodChannelPcmPlayer(channel: channel);
      await player.open(sampleRate: 24000);
      player.feed(Uint8List.fromList([1, 0]));
      player.interrupt();
      await player.close();
      await pumpEventQueue();

      expect(calls.map((c) => c.method), [
        'open',
        'feed',
        'interrupt',
        'close',
      ]);
      expect(calls.first.arguments, {'sampleRate': 24000});
      for (final call in calls.skip(1)) {
        expect((call.arguments as Map)['token'], 7);
      }
    });

    test('nothing is sent after close', () async {
      final player = MethodChannelPcmPlayer(channel: channel);
      await player.open(sampleRate: 24000);
      await player.close();
      player.feed(Uint8List.fromList([1, 0]));
      player.interrupt();
      await player.close();
      await pumpEventQueue();

      expect(calls.map((c) => c.method), ['open', 'close']);
    });

    test('closing while opening releases the native player', () async {
      final player = MethodChannelPcmPlayer(channel: channel);
      final opening = player.open(sampleRate: 24000);
      await player.close();
      await opening;

      expect(calls.map((c) => c.method), ['open', 'close']);
    });
  });

  test('createLiveMedia returns native capture off the web', () {
    expect(createLiveMedia(), isA<NativeLiveMedia>());
  });
}
