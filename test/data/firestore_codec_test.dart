import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/data/firestore_codec.dart';

void main() {
  test('bytes become Blobs at any depth and read back through fromMap', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final encoded = encodeDoc({
      'photo': bytes,
      'thumbnails': [bytes, bytes],
      'nested': {'x': bytes},
      'n': 1,
    });
    expect(encoded['photo'], isA<Blob>());
    expect((encoded['thumbnails'] as List).first, isA<Blob>());
    expect((encoded['nested'] as Map)['x'], isA<Blob>());
    expect(encoded['n'], 1);
    expect(readBytes(encoded['photo']), bytes);
  });
}
