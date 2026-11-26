import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:soussight/core/image_utils.dart';

void main() {
  test('downscales the long side and keeps aspect ratio', () {
    final src = Uint8List.fromList(img.encodeJpg(img.Image(width: 2000, height: 1000)));
    final out = img.decodeJpg(downscaleJpeg(src))!;
    expect(out.width, 768);
    expect(out.height, 384);
    expect(img.decodeJpg(thumbnailJpeg(src))!.width, 512);
  });
}
