// Non-web builds: no share plugin is bundled yet, so the receipt says so and
// suggests a screenshot. Nothing is written or sent.

import 'dart:typed_data';

import 'privacy_receipt_save.dart';

Future<ReceiptSaveResult> saveReceiptImage(
  Uint8List png,
  String fileName, {
  required bool Function() isCurrent,
}) async => ReceiptSaveResult.unsupported;
