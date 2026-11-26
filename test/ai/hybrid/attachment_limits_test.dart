import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:soussight/ai/hybrid/attachment_limits.dart';

HybridInlineData _png(int w, int h) => HybridInlineData(
  Uint8List.fromList(img.encodePng(img.Image(width: w, height: h))),
  'image/png',
);

HybridTask _task(List<HybridPart> parts) => HybridTask(
  feature: 'f',
  parts: parts,
  maxOutputTokens: 8,
  timeout: const Duration(seconds: 1),
);

void main() {
  const caps = HybridCapabilities.none(); // 1 image, 1 MiB, 768 px

  test('within the limits', () {
    expect(attachmentProblem(_task([_png(768, 768)]), caps), isNull);
    expect(attachmentProblem(_task([const HybridText('hi')]), caps), isNull);
  });

  test('count, bytes and pixel size', () {
    expect(
      attachmentProblem(_task([_png(1, 1), _png(1, 1)]), caps),
      contains('At most 1'),
    );
    expect(attachmentProblem(_task([_png(769, 1)]), caps), contains('769x1'));
    expect(attachmentProblem(_task([_png(1, 769)]), caps), contains('1x769'));
    final big = HybridInlineData(Uint8List(1024 * 1024 + 1), 'image/jpeg');
    expect(attachmentProblem(_task([big]), caps), contains('bytes'));
  });

  test('audio is not an image; an unreadable image is left to readability', () {
    final audio = HybridInlineData(Uint8List(2 * 1024 * 1024), 'audio/wav');
    expect(attachmentProblem(_task([audio]), caps), isNull);
    final junk = HybridInlineData(Uint8List.fromList([1, 2, 3]), 'image/jpeg');
    expect(attachmentProblem(_task([junk]), caps), isNull);
    expect(imagesReadable(_task([junk])), isFalse);
    expect(imagesReadable(_task([_png(2, 2)])), isTrue);
    expect(imagesReadable(_task([const HybridText('no images')])), isTrue);
  });
}
