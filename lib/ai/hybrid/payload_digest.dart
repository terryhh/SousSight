// Payload identity for consent (DESIGN.md §5): a ConsentGrant is bound to the
// SHA-256 of the exact serialized task.
//
// SHA-256 is implemented here because `package:crypto` is only a transitive
// dependency and the root pubspec is a shared file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import 'hybrid_types.dart';

/// Lowercase hex SHA-256 of [taskBytes]. A [ConsentAsk.payloadDigest] for a
/// task must be this value: features that obtain consent themselves (and pass
/// the grant to `HybridDispatcher.start`) compute it here.
String hybridPayloadDigest(HybridTask task) => sha256Hex(taskBytes(task));

/// The canonical serialization the digest covers: everything that can leave
/// the device (feature, instruction, every part including image bytes,
/// schema, output limit).
Uint8List taskBytes(HybridTask task) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'feature': task.feature,
      'systemInstruction': task.systemInstruction,
      'parts': [
        for (final p in task.parts)
          switch (p) {
            HybridText(:final text) => {'type': 'text', 'text': text},
            HybridInlineData(:final bytes, :final mimeType) => {
              'type': 'inlineData',
              'mimeType': mimeType,
              'bytes': base64Encode(bytes),
            },
          },
      ],
      'jsonSchema': task.jsonSchema,
      'maxOutputTokens': task.maxOutputTokens,
    }),
  ),
);

/// What kinds of data a task carries. Location never travels in a
/// [HybridTask]; senders that send it (nearby) record it themselves.
Set<DataKind> taskDataKinds(HybridTask task) => {
  if ((task.systemInstruction ?? '').isNotEmpty ||
      task.parts.any((p) => p is HybridText))
    DataKind.text,
  if (task.parts.any(isImagePart)) DataKind.image,
  if (task.parts.any(
    (p) =>
        p is HybridInlineData &&
        normalizeMimeType(p.mimeType).startsWith('audio/'),
  ))
    DataKind.audio,
};

/// A MIME type as the dispatcher classifies and sends it: trimmed and lower
/// case (`Image/JPEG ` → `image/jpeg`). Types are case-insensitive.
String normalizeMimeType(String mimeType) => mimeType.trim().toLowerCase();

/// Same test as [HybridTask.hasImage], per part, on the normalized type.
bool isImagePart(HybridPart p) =>
    p is HybridInlineData && normalizeMimeType(p.mimeType).startsWith('image/');

const _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// FIPS 180-4 SHA-256. Uses only 32-bit arithmetic so it is exact on web.
String sha256Hex(List<int> message) {
  final bitLength = message.length * 8;
  final padded = BytesBuilder(copy: false)
    ..add(message)
    ..addByte(0x80);
  final zeros = (56 - (message.length + 1) % 64) % 64;
  padded.add(Uint8List(zeros));
  final len = ByteData(8)
    ..setUint32(0, (bitLength ~/ 0x100000000) & 0xffffffff)
    ..setUint32(4, bitLength & 0xffffffff);
  padded.add(len.buffer.asUint8List());
  final data = ByteData.sublistView(padded.takeBytes());

  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final w = List<int>.filled(64, 0);
  int rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;
  int add(int a, int b) => (a + b) & 0xffffffff;

  for (var chunk = 0; chunk < data.lengthInBytes; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = data.getUint32(chunk + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = add(add(w[i - 16], s0), add(w[i - 7], s1));
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = add(add(add(hh, s1), add(ch, _k[i])), w[i]);
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = add(s0, maj);
      hh = g;
      g = f;
      f = e;
      e = add(d, t1);
      d = c;
      c = b;
      b = a;
      a = add(t1, t2);
    }
    h[0] = add(h[0], a);
    h[1] = add(h[1], b);
    h[2] = add(h[2], c);
    h[3] = add(h[3], d);
    h[4] = add(h[4], e);
    h[5] = add(h[5], f);
    h[6] = add(h[6], g);
    h[7] = add(h[7], hh);
  }
  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}
