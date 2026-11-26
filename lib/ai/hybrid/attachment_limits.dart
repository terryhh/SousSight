// The attachment limits every route enforces (DESIGN §4): checked in Dart
// before any send, so a payload the bridge rejects can never reach the Dart
// cloud adapter instead.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:image/image.dart' as img;

/// Why [task]'s images break the shared limits in [caps], or null when they
/// fit. An image whose header cannot be read is not judged here (see
/// [imagesReadable]).
String? attachmentProblem(HybridTask task, HybridCapabilities caps) {
  final images = _images(task);
  if (images.length > caps.maxImages) {
    return 'At most ${caps.maxImages} image per request';
  }
  for (final image in images) {
    if (image.bytes.length > caps.maxImageBytes) {
      return 'Image is ${image.bytes.length} bytes; '
          'the limit is ${caps.maxImageBytes}';
    }
    final size = _size(image);
    if (size != null &&
        (size.$1 > caps.maxImageDimension ||
            size.$2 > caps.maxImageDimension)) {
      return 'Image is ${size.$1}x${size.$2}; '
          'the limit is ${caps.maxImageDimension} px';
    }
  }
  return null;
}

/// True when every image's header can be read: an image the bridge could
/// not carry, not an invalid one.
bool imagesReadable(HybridTask task) =>
    _images(task).every((image) => _size(image) != null);

List<HybridInlineData> _images(HybridTask task) => [
  for (final p in task.parts)
    if (p is HybridInlineData && p.mimeType.startsWith('image/')) p,
];

(int, int)? _size(HybridInlineData image) {
  try {
    final info = img.findDecoderForData(image.bytes)?.startDecode(image.bytes);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return (info.width, info.height);
  } catch (_) {
    return null;
  }
}
