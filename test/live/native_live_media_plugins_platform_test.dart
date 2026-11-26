// PluginNativeCamera and PluginNativeMicrophone against fake camera and record
// platform implementations. No device, camera, microphone or permission
// prompt: this proves the adapter's lifecycle (open, stream, close races),
// not the native plugins themselves.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:soussight/live/native_live_media.dart';
import 'package:soussight/live/native_live_media_plugins.dart';

const _back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const _front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

class _FakeCameraPlatform extends CameraPlatform {
  List<CameraDescription> cameras = const [_front, _back];
  Completer<void>? camerasGate;
  Completer<void>? initializeGate;
  Object? initializeError;
  Object? disposeError;
  final created = <(CameraDescription, MediaSettings)>[];
  ImageFormatGroup? requestedFormat;
  int availableCalls = 0;
  int disposed = 0;
  final frames = StreamController<CameraImageData>.broadcast();
  final errors = StreamController<CameraErrorEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async {
    availableCalls++;
    await camerasGate?.future;
    return cameras;
  }

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    created.add((cameraDescription, mediaSettings));
    return 1;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          640,
          480,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => errors.stream;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    requestedFormat = imageFormatGroup;
    await initializeGate?.future;
    if (initializeError case final error?) throw error;
  }

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => frames.stream;

  @override
  Future<void> dispose(int cameraId) async {
    disposed++;
    if (disposeError case final error?) throw error;
  }
}

CameraImageData _image(ImageFormatGroup group, {int planes = 3}) =>
    CameraImageData(
      format: CameraImageFormat(group, raw: 0),
      width: 4,
      height: 2,
      planes: [
        for (var i = 0; i < planes; i++)
          CameraImagePlane(
            bytes: Uint8List.fromList(List.filled(8, i)),
            bytesPerRow: 4,
            bytesPerPixel: 1,
          ),
      ],
    );

class _FakeRecordPlatform extends RecordPlatform {
  bool permission = true;
  Completer<void>? startGate;
  Object? startError;
  Object? stopError;
  Object? disposeError;
  final calls = <String>[];
  RecordConfig? config;
  final pcm = StreamController<Uint8List>();

  @override
  Future<void> create(String recorderId) async => calls.add('create');

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    calls.add('permission');
    return permission;
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    calls.add('startStream');
    this.config = config;
    await startGate?.future;
    if (startError case final error?) throw error;
    return pcm.stream;
  }

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    if (stopError case final error?) throw error;
    return null;
  }

  @override
  Future<void> dispose(String recorderId) async {
    calls.add('dispose');
    if (disposeError case final error?) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginNativeCamera', () {
    late _FakeCameraPlatform platform;
    setUp(() => CameraPlatform.instance = platform = _FakeCameraPlatform());

    test('opens the back camera once, audio off, in YUV on Android', () async {
      final camera = PluginNativeCamera();
      await Future.wait([camera.open(), camera.open()]);

      expect(platform.availableCalls, 1);
      final (description, settings) = platform.created.single;
      expect(description.name, 'back');
      expect(settings.enableAudio, isFalse);
      expect(platform.requestedFormat, ImageFormatGroup.yuv420);
      await camera.close();
      expect(platform.disposed, 1);
    });

    test('falls back to the first camera when none faces back', () async {
      platform.cameras = const [_front];
      final camera = PluginNativeCamera();
      await camera.open();
      expect(platform.created.single.$1.name, 'front');
      await camera.close();
    });

    test('a device without cameras says so', () async {
      platform.cameras = const [];
      await expectLater(
        PluginNativeCamera().open(),
        throwsA(
          isA<NativeLiveMediaException>().having(
            (e) => e.message,
            'message',
            'No camera found on this device.',
          ),
        ),
      );
    });

    test('closing while cameras are listed never creates one', () async {
      platform.camerasGate = Completer<void>();
      final camera = PluginNativeCamera();
      final opening = camera.open();
      await pumpEventQueue();
      await camera.close();
      platform.camerasGate!.complete();
      await opening;
      expect(platform.created, isEmpty);
    });

    test('a refused camera permission surfaces as a camera error', () async {
      platform.initializeError = PlatformException(code: 'CameraAccessDenied');
      await expectLater(
        PluginNativeCamera().open(),
        throwsA(
          isA<CameraException>().having(
            (e) => e.code,
            'code',
            'CameraAccessDenied',
          ),
        ),
      );
    });

    test('an initialize failure after close is swallowed', () async {
      platform
        ..initializeGate = Completer<void>()
        ..initializeError = PlatformException(code: 'CameraAccessDenied');
      final camera = PluginNativeCamera();
      final opening = camera.open();
      await pumpEventQueue();
      // CameraController.dispose waits for initialize to settle, so close
      // completes only once the platform answers.
      final closing = camera.close();
      platform.initializeGate!.complete();
      await closing;
      await expectLater(opening, completes);
    });

    test('closing during initialize releases the camera it opened', () async {
      platform.initializeGate = Completer<void>();
      final camera = PluginNativeCamera();
      final opening = camera.open();
      await pumpEventQueue();
      // CameraController.dispose waits for initialize to settle, so close
      // completes only once the platform answers.
      final closing = camera.close();
      platform.initializeGate!.complete();
      await closing;
      await opening;
      expect(platform.disposed, greaterThanOrEqualTo(1));
    });

    test('frames before open are ignored', () async {
      final frames = <NativeCameraFrame>[];
      await PluginNativeCamera().startFrames(frames.add, (_) {});
      expect(frames, isEmpty);
    });

    test('streams readable frames upright, skips unreadable formats and '
        'reports the first camera error once', () async {
      final camera = PluginNativeCamera();
      await camera.open();
      final frames = <NativeCameraFrame>[];
      final errors = <Object>[];
      await camera.startFrames(frames.add, errors.add);

      platform.frames.add(_image(ImageFormatGroup.yuv420));
      platform.frames.add(_image(ImageFormatGroup.jpeg, planes: 1));
      platform.errors.add(const CameraErrorEvent(1, 'sensor overheated'));
      await pumpEventQueue();
      platform.frames.add(_image(ImageFormatGroup.yuv420));
      await pumpEventQueue();

      expect(frames, hasLength(2));
      final frame = frames.first;
      expect(frame.format, NativePixelFormat.yuv420);
      expect((frame.width, frame.height), (4, 2));
      expect(frame.planes, hasLength(3));
      expect(frame.planes[1].bytes, List.filled(8, 1));
      expect(frame.planes[1].bytesPerRow, 4);
      expect(frame.planes[1].bytesPerPixel, 1);
      expect(frame.rotationDegrees, 90, reason: 'back sensor, portrait');
      expect(errors, ['sensor overheated']);

      await camera.close();
      platform.frames.add(_image(ImageFormatGroup.yuv420));
      await pumpEventQueue();
      expect(frames, hasLength(2), reason: 'no frames after close');
      expect(platform.frames.hasListener, isFalse, reason: 'stream stopped');
      expect(platform.disposed, 1);
    });

    test(
      'closing right after starting frames still releases the camera',
      () async {
        final camera = PluginNativeCamera();
        await camera.open();
        final starting = camera.startFrames((_) {}, (_) {});
        await camera.close();
        await starting;
        expect(platform.frames.hasListener, isFalse);
        expect(platform.disposed, 1);
      },
    );

    test('a failing platform dispose does not break close', () async {
      platform.disposeError = PlatformException(code: 'gone');
      final camera = PluginNativeCamera();
      await camera.open();
      await camera.startFrames((_) {}, (_) {});
      await expectLater(camera.close(), completes);
      await expectLater(camera.close(), completes);
    });
  });

  group('nativeFrameFrom', () {
    NativeCameraFrame? convert(ImageFormatGroup group, {int planes = 1}) =>
        nativeFrameFrom(
          CameraImage.fromPlatformInterface(_image(group, planes: planes)),
          sensorOrientation: 90,
          lensDirection: CameraLensDirection.back,
          deviceOrientation: DeviceOrientation.portraitUp,
          platform: TargetPlatform.iOS,
        );

    test('maps every format the encoder reads', () {
      expect(convert(ImageFormatGroup.nv21)!.format, NativePixelFormat.nv21);
      final bgra = convert(ImageFormatGroup.bgra8888)!;
      expect(bgra.format, NativePixelFormat.bgra8888);
      expect(bgra.rotationDegrees, 0, reason: 'iOS frames are upright');
      expect(
        convert(ImageFormatGroup.yuv420, planes: 3)!.format,
        NativePixelFormat.yuv420,
      );
    });

    test('formats the encoder cannot read are dropped', () {
      expect(convert(ImageFormatGroup.jpeg), isNull);
      expect(convert(ImageFormatGroup.unknown), isNull);
    });
  });

  group('PluginNativeMicrophone', () {
    late _FakeRecordPlatform platform;
    setUp(() => RecordPlatform.instance = platform = _FakeRecordPlatform());

    test('asks the platform for microphone permission', () async {
      final mic = PluginNativeMicrophone();
      expect(await mic.requestPermission(), isTrue);
      platform.permission = false;
      expect(await mic.requestPermission(), isFalse);
      expect(platform.calls.where((c) => c == 'permission'), hasLength(2));
    });

    test(
      'starts one PCM16 stream with the Live config and forwards audio',
      () async {
        final mic = PluginNativeMicrophone();
        final first = mic.start();
        final second = mic.start();
        expect(identical(first, second), isTrue);
        final stream = await first;
        final chunks = <Uint8List>[];
        final sub = stream.listen(chunks.add);
        platform.pcm.add(Uint8List.fromList([1, 2]));
        await pumpEventQueue();

        expect(platform.calls.where((c) => c == 'startStream'), hasLength(1));
        expect(platform.config, same(kNativeMicrophoneConfig));
        expect(chunks.single, [1, 2]);
        await sub.cancel();
        await mic.close();
      },
    );

    test('after close nothing is requested or started', () async {
      final mic = PluginNativeMicrophone();
      await mic.close();
      expect(await mic.requestPermission(), isFalse);
      expect(await (await mic.start()).isEmpty, isTrue);
      expect(platform.calls, isNot(contains('permission')));
      expect(platform.calls, isNot(contains('startStream')));
    });

    test(
      'close lets an in-flight start finish, then stops and disposes',
      () async {
        platform.startGate = Completer<void>();
        final mic = PluginNativeMicrophone();
        unawaited(mic.start());
        await pumpEventQueue();
        final closing = mic.close();
        await pumpEventQueue();
        expect(platform.calls, isNot(contains('stop')));

        platform.startGate!.complete();
        await closing;
        final tail = platform.calls.skipWhile((c) => c != 'startStream');
        expect(tail.toList(), containsAllInOrder(['startStream', 'stop']));
        expect(platform.calls.last, 'dispose');

        await mic.close();
        expect(platform.calls.where((c) => c == 'dispose'), hasLength(1));
      },
    );

    test('a failed start, stop or dispose never escapes close', () async {
      platform
        ..startError = PlatformException(code: 'record')
        ..stopError = PlatformException(code: 'record')
        ..disposeError = PlatformException(code: 'record');
      final mic = PluginNativeMicrophone();
      await expectLater(mic.start(), throwsA(isA<PlatformException>()));
      await expectLater(mic.close(), completes);
    });
  });

  test('a PCM player that issues no token refuses to open', () async {
    const channel = MethodChannel('test/pcm_player_no_token');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final player = MethodChannelPcmPlayer(channel: channel);
    await expectLater(
      player.open(sampleRate: 24000),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'pcm_player'),
      ),
    );
    // Without a token nothing else is sent, not even on close.
    player.feed(Uint8List.fromList([1, 2]));
    player.interrupt();
    await player.close();
    await pumpEventQueue();
    expect(calls, ['open']);
  });
}
