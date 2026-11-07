// Converts model maps to Firestore-ready values: Uint8List becomes Blob at
// any depth. DateTime is accepted by cloud_firestore as-is. Reads need no
// conversion; models' fromMap accepts Timestamp and Blob.

import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

Object? toFirestore(Object? value) {
  if (value is Uint8List) return Blob(value);
  if (value is Map) {
    return {for (final e in value.entries) e.key as String: toFirestore(e.value)};
  }
  if (value is List) return [for (final v in value) toFirestore(v)];
  return value;
}

Map<String, dynamic> encodeDoc(Map<String, dynamic> map) =>
    toFirestore(map)! as Map<String, dynamic>;
