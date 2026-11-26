// Saving tonight's privacy receipt as an image (SS-105).
//
// The PNG is rendered on this device and handed to the browser: the system
// share sheet when it can take a file (the cook picks where it goes), else a
// download. SousSight uploads nothing.

import 'dart:typed_data';

export 'privacy_receipt_save_stub.dart'
    if (dart.library.js_interop) 'privacy_receipt_save_web.dart'
    show saveReceiptImage;

/// What happened to the image.
enum ReceiptSaveResult {
  /// Handed to the system share sheet.
  shared,

  /// Saved as a download.
  downloaded,

  /// The cook closed the share sheet.
  cancelled,

  /// This platform has no local save path yet.
  unsupported,
}

/// Saves [png] locally as [fileName]. Never uploads.
typedef ReceiptImageSaver = Future<ReceiptSaveResult> Function(
  Uint8List png,
  String fileName,
);
