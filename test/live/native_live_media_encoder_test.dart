import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:soussight/live/native_live_media_encoder.dart';

NativeCameraFrame bgra(int width, int height, List<int> bgra) {
  final bytes = Uint8List(width * height * 4);
  for (var i = 0; i < bytes.length; i += 4) {
    bytes.setRange(i, i + 4, bgra);
  }
  return NativeCameraFrame(
    format: NativePixelFormat.bgra8888,
    width: width,
    height: height,
    planes: [NativePlane(bytes: bytes, bytesPerRow: width * 4)],
  );
}

/// YUV420 with three planes; luma is bright in the left half only.
NativeCameraFrame yuvLeftBright(int width, int height, {int rotation = 0}) {
  final y = Uint8List(width * height);
  for (var row = 0; row < height; row++) {
    for (var col = 0; col < width; col++) {
      y[row * width + col] = col < width ~/ 2 ? 235 : 16;
    }
  }
  // Android-style interleaved chroma: pixel stride 2 into a shared buffer.
  final chromaRow = width;
  final uv = Uint8List(chromaRow * (height ~/ 2))
    ..fillRange(0, chromaRow * (height ~/ 2), 128);
  return NativeCameraFrame(
    format: NativePixelFormat.yuv420,
    width: width,
    height: height,
    rotationDegrees: rotation,
    planes: [
      NativePlane(bytes: y, bytesPerRow: width, bytesPerPixel: 1),
      NativePlane(bytes: uv, bytesPerRow: chromaRow, bytesPerPixel: 2),
      NativePlane(
        bytes: Uint8List.sublistView(uv, 1),
        bytesPerRow: chromaRow,
        bytesPerPixel: 2,
      ),
    ],
  );
}

img.Image decode(Uint8List jpeg) => img.decodeJpg(jpeg)!;

void main() {
  test('output is a JPEG no larger than 768 px on its longest side', () {
    final jpeg = encodeNativeFrameJpeg(bgra(1280, 720, [0, 0, 255, 255]));
    final image = decode(jpeg);

    expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
    expect(image.width, 768);
    expect(image.height, 432);
  });

  test('small frames are not upscaled', () {
    final image = decode(encodeNativeFrameJpeg(bgra(640, 480, [0, 0, 0, 255])));
    expect([image.width, image.height], [640, 480]);
  });

  test('BGRA channel order is read as red, green, blue', () {
    final image = decode(
      encodeNativeFrameJpeg(bgra(16, 16, [20, 40, 220, 255])),
    );
    final pixel = image.getPixel(8, 8);

    expect(pixel.r, closeTo(220, 12));
    expect(pixel.g, closeTo(40, 12));
    expect(pixel.b, closeTo(20, 12));
  });

  test('YUV420 converts with neutral chroma to grey levels', () {
    final image = decode(encodeNativeFrameJpeg(yuvLeftBright(64, 32)));

    expect(image.getPixel(4, 16).r, greaterThan(200));
    expect(image.getPixel(60, 16).r, lessThan(40));
  });

  test('Android sensor rotation turns the frame upright', () {
    // Bright left half, rotated 90 degrees clockwise: bright top half.
    final image = decode(
      encodeNativeFrameJpeg(yuvLeftBright(64, 32, rotation: 90)),
    );

    expect([image.width, image.height], [32, 64]);
    expect(image.getPixel(16, 4).r, greaterThan(200));
    expect(image.getPixel(16, 60).r, lessThan(40));
  });

  test('a frame whose plane is too short is rejected, not encoded', () {
    final frame = NativeCameraFrame(
      format: NativePixelFormat.bgra8888,
      width: 10,
      height: 10,
      planes: [NativePlane(bytes: Uint8List(12), bytesPerRow: 40)],
    );
    expect(() => encodeNativeFrameJpeg(frame), throwsArgumentError);
  });

  test('NV21 in one buffer is accepted', () {
    const width = 8;
    const height = 4;
    final bytes = Uint8List(width * height * 3 ~/ 2)
      ..fillRange(0, width * height, 200)
      ..fillRange(width * height, width * height * 3 ~/ 2, 128);
    final image = decode(
      encodeNativeFrameJpeg(
        NativeCameraFrame(
          format: NativePixelFormat.nv21,
          width: width,
          height: height,
          planes: [NativePlane(bytes: bytes, bytesPerRow: width)],
        ),
      ),
    );
    expect(image.getPixel(4, 2).r, closeTo(200, 12));
  });
}
