// Web: share the PNG through the system share sheet when the browser can take
// a file (Android Chrome), else download it. Both stay on the device until
// the cook chooses where it goes; SousSight uploads nothing.

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'privacy_receipt_save.dart';

Future<ReceiptSaveResult> saveReceiptImage(
  Uint8List png,
  String fileName,
) async {
  final parts = <web.BlobPart>[png.toJS].toJS;
  final file = web.File(
    parts,
    fileName,
    web.FilePropertyBag(type: 'image/png'),
  );
  final data = web.ShareData(files: [file].toJS);
  final navigator = web.window.navigator;
  var canShare = false;
  try {
    canShare = navigator.canShare(data);
  } catch (_) {
    canShare = false; // No Web Share API (Firefox, older desktop browsers).
  }
  if (canShare) {
    try {
      await navigator.share(data).toDart;
      return ReceiptSaveResult.shared;
    } catch (error) {
      // The cook closed the sheet: respect that, no surprise download.
      if ('$error'.contains('AbortError')) return ReceiptSaveResult.cancelled;
      // Any other share failure falls through to a download.
    }
  }
  final url = web.URL.createObjectURL(file);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
    const Duration(seconds: 30),
    () => web.URL.revokeObjectURL(url),
  );
  return ReceiptSaveResult.downloaded;
}
