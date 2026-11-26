import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Longest side of a frame sent to the coach or the local watch. Matches the
/// browser capture in web/soussight_live.js.
const kNativeFrameMaxSide = 768;

/// JPEG quality, matching the browser's `toBlob(..., 0.76)`.
const kNativeFrameJpegQuality = 76;

/// Pixel layouts the camera plugins deliver on Android and iOS.
enum NativePixelFormat {
  /// Three planes (Y, U, V) or two planes (Y, interleaved UV), as Android
  /// `YUV_420_888` and iOS `420YpCbCr8BiPlanar` arrive.
  yuv420,

  /// Y followed by interleaved VU (Android NV21), in one or two planes.
  nv21,

  /// One plane, four bytes per pixel in B, G, R, A order (iOS default).
  bgra8888,
}

class NativePlane {
  const NativePlane({
    required this.bytes,
    required this.bytesPerRow,
    this.bytesPerPixel,
  });

  final Uint8List bytes;
  final int bytesPerRow;

  /// Distance between neighbouring samples in a row; null means 1.
  final int? bytesPerPixel;
}

/// A raw camera image as the platform delivered it, plus the clockwise
/// rotation that makes it upright for the cook's current device orientation.
class NativeCameraFrame {
  const NativeCameraFrame({
    required this.format,
    required this.width,
    required this.height,
    required this.planes,
    this.rotationDegrees = 0,
  });

  final NativePixelFormat format;
  final int width;
  final int height;
  final List<NativePlane> planes;

  /// 0, 90, 180 or 270. Android image streams arrive in sensor orientation;
  /// iOS rotates the video connection itself, so iOS frames use 0.
  final int rotationDegrees;
}

/// Converts [frame] to an upright JPEG whose longest side is at most
/// [maxSide]. Pure Dart so it can run in a background isolate and in tests.
///
/// Throws [ArgumentError] or [UnsupportedError] on a malformed frame; the
/// caller drops that frame rather than sending a corrupt image.
Uint8List encodeNativeFrameJpeg(
  NativeCameraFrame frame, {
  int maxSide = kNativeFrameMaxSide,
  int quality = kNativeFrameJpegQuality,
}) {
  final rgb = _NativeRgbReader.of(frame);
  final rotation = ((frame.rotationDegrees % 360) + 360) % 360;
  if (rotation % 90 != 0) {
    throw ArgumentError.value(frame.rotationDegrees, 'rotationDegrees');
  }
  final quarterTurn = rotation == 90 || rotation == 270;
  final uprightWidth = quarterTurn ? frame.height : frame.width;
  final uprightHeight = quarterTurn ? frame.width : frame.height;
  final scale = math.min(1.0, maxSide / math.max(uprightWidth, uprightHeight));
  final outWidth = math.max(1, (uprightWidth * scale).round());
  final outHeight = math.max(1, (uprightHeight * scale).round());

  final out = Uint8List(outWidth * outHeight * 3);
  final pixel = Uint8List(3);
  var offset = 0;
  for (var oy = 0; oy < outHeight; oy++) {
    // Nearest sample in the upright (rotated, unscaled) image.
    final uy = math.min(uprightHeight - 1, (oy / scale).floor());
    for (var ox = 0; ox < outWidth; ox++) {
      final ux = math.min(uprightWidth - 1, (ox / scale).floor());
      // Map the upright coordinate back to the sensor image.
      final int sx;
      final int sy;
      switch (rotation) {
        case 90:
          sx = uy;
          sy = frame.height - 1 - ux;
        case 180:
          sx = frame.width - 1 - ux;
          sy = frame.height - 1 - uy;
        case 270:
          sx = frame.width - 1 - uy;
          sy = ux;
        default:
          sx = ux;
          sy = uy;
      }
      rgb.read(sx, sy, pixel);
      out[offset++] = pixel[0];
      out[offset++] = pixel[1];
      out[offset++] = pixel[2];
    }
  }
  final image = img.Image.fromBytes(
    width: outWidth,
    height: outHeight,
    bytes: out.buffer,
    numChannels: 3,
  );
  return img.encodeJpg(image, quality: quality);
}

abstract class _NativeRgbReader {
  static _NativeRgbReader of(NativeCameraFrame frame) {
    if (frame.width <= 0 || frame.height <= 0) {
      throw ArgumentError('Camera frame has no pixels.');
    }
    if (frame.planes.isEmpty) {
      throw ArgumentError('Camera frame has no planes.');
    }
    switch (frame.format) {
      case NativePixelFormat.bgra8888:
        final plane = frame.planes.first;
        _requireLength(plane, frame.height, frame.width * 4);
        return _BgraReader(plane);
      case NativePixelFormat.yuv420:
        final y = frame.planes[0];
        _requireLength(y, frame.height, frame.width);
        if (frame.planes.length >= 3) {
          return _YuvReader(
            y: y,
            u: frame.planes[1],
            v: frame.planes[2],
            uOffset: 0,
            vOffset: 0,
          );
        }
        if (frame.planes.length == 2) {
          // Bi-planar: Cb then Cr interleaved in the second plane.
          final uv = frame.planes[1];
          return _YuvReader(
            y: y,
            u: uv,
            v: uv,
            uOffset: 0,
            vOffset: 1,
            step: 2,
          );
        }
        throw ArgumentError('YUV420 frame needs two or three planes.');
      case NativePixelFormat.nv21:
        final y = frame.planes[0];
        if (frame.planes.length >= 2) {
          final vu = frame.planes[1];
          return _YuvReader(
            y: y,
            u: vu,
            v: vu,
            uOffset: 1,
            vOffset: 0,
            step: 2,
          );
        }
        // Single buffer: Y rows, then interleaved VU rows.
        final rowBytes = y.bytesPerRow;
        final chromaStart = rowBytes * frame.height;
        if (y.bytes.length < chromaStart + rowBytes * (frame.height ~/ 2)) {
          throw ArgumentError('NV21 frame is shorter than its size.');
        }
        final chroma = NativePlane(
          bytes: Uint8List.sublistView(y.bytes, chromaStart),
          bytesPerRow: rowBytes,
        );
        return _YuvReader(
          y: y,
          u: chroma,
          v: chroma,
          uOffset: 1,
          vOffset: 0,
          step: 2,
        );
    }
  }

  static void _requireLength(NativePlane plane, int rows, int rowBytes) {
    if (plane.bytesPerRow < rowBytes ||
        plane.bytes.length < plane.bytesPerRow * (rows - 1) + rowBytes) {
      throw ArgumentError('Camera plane is shorter than the frame size.');
    }
  }

  void read(int x, int y, Uint8List rgb);
}

class _BgraReader extends _NativeRgbReader {
  _BgraReader(this.plane);
  final NativePlane plane;

  @override
  void read(int x, int y, Uint8List rgb) {
    final i = y * plane.bytesPerRow + x * 4;
    rgb[0] = plane.bytes[i + 2];
    rgb[1] = plane.bytes[i + 1];
    rgb[2] = plane.bytes[i];
  }
}

class _YuvReader extends _NativeRgbReader {
  _YuvReader({
    required this.y,
    required this.u,
    required this.v,
    required this.uOffset,
    required this.vOffset,
    int? step,
  }) : uStep = step ?? u.bytesPerPixel ?? 1,
       vStep = step ?? v.bytesPerPixel ?? 1;

  final NativePlane y;
  final NativePlane u;
  final NativePlane v;
  final int uOffset;
  final int vOffset;
  final int uStep;
  final int vStep;

  @override
  void read(int x, int py, Uint8List rgb) {
    final luma = _at(y, py * y.bytesPerRow + x * (y.bytesPerPixel ?? 1));
    final cx = x >> 1;
    final cy = py >> 1;
    final cb = _at(u, cy * u.bytesPerRow + cx * uStep + uOffset) - 128;
    final cr = _at(v, cy * v.bytesPerRow + cx * vStep + vOffset) - 128;
    rgb[0] = _clamp(luma + 1.402 * cr);
    rgb[1] = _clamp(luma - 0.344136 * cb - 0.714136 * cr);
    rgb[2] = _clamp(luma + 1.772 * cb);
  }

  // Some Android devices end the last chroma row early; treat the missing
  // tail as neutral grey rather than failing the whole frame.
  static int _at(NativePlane plane, int index) =>
      index < plane.bytes.length ? plane.bytes[index] : 128;

  static int _clamp(double value) => value < 0
      ? 0
      : value > 255
      ? 255
      : value.round();
}
