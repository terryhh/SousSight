// TEMPORARY SHIM (SS-073). PR #181 (SS-067, branch hybrid/12-watch) adds this
// exact class to lib/live/live_types.dart together with
// `LiveMedia.timedFrames` and `LiveMedia.startCameraOnly()`. This branch is cut
// from the trunk before #181 landed, so NativeLiveMedia carries those members as
// extra public API and takes the type from here.
//
// When #181 is on the trunk: delete this file, drop its import and the
// `export ... show CapturedFrame` line from native_live_media.dart, and add
// `@override` to NativeLiveMedia.timedFrames and NativeLiveMedia.startCameraOnly
// (both marked TODO(SS-073)). Until then the analyzer reports CapturedFrame as
// ambiguous wherever live_types.dart and native_live_media.dart are imported
// together, which points at exactly these lines.

import 'dart:typed_data';

/// One JPEG camera frame, stamped when the browser or device acquired it, not
/// when Dart received it. Consumers judge freshness from [capturedAt].
class CapturedFrame {
  const CapturedFrame({required this.bytes, required this.capturedAt});
  final Uint8List bytes;
  final DateTime capturedAt;
}
