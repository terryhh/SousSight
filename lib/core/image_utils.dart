// JPEG downscaling for checkpoint photos (768px) and request thumbnails
// (512px). Keeps Firestore documents well under the 1 MiB limit.

import 'dart:typed_data';

import 'package:image/image.dart' as img;

const kPhotoMaxSide = 768;
const kThumbMaxSide = 512;

/// Decodes any supported image, bakes in EXIF orientation, scales the long
/// side down to [maxSide] (never up), and re-encodes as JPEG.
Uint8List downscaleJpeg(Uint8List bytes, {int maxSide = kPhotoMaxSide, int quality = 75}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Unsupported image');
  var image = img.bakeOrientation(decoded);
  final longSide = image.width > image.height ? image.width : image.height;
  if (longSide > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide)
        : img.copyResize(image, height: maxSide);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

Uint8List thumbnailJpeg(Uint8List bytes) =>
    downscaleJpeg(bytes, maxSide: kThumbMaxSide, quality: 70);
