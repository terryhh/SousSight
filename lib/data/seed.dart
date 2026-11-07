// Coordinator-only demo seeding and switches (rules enforce the role).

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/fakes.dart';
import '../core/models.dart';
import 'firestore_codec.dart';

Future<void> seedDemoData(FirebaseFirestore db, Recipe recipe) async {
  final batch = db.batch();
  batch.set(db.collection('recipes').doc(recipe.id), encodeDoc(recipe.toMap()));
  for (final i in demoRoster()) {
    batch.set(db.collection('instructors').doc(i.id), encodeDoc(i.toMap()));
  }
  batch.set(
    db.collection('config').doc('demo'),
    {'notifyEnabled': false, 'forceNotifyFailure': false, 'channel': 'whatsapp'},
    SetOptions(merge: true),
  );
  await batch.commit();
}

Stream<Map<String, dynamic>> watchDemoConfig(FirebaseFirestore db) => db
    .collection('config')
    .doc('demo')
    .snapshots()
    .map((s) => s.data() ?? const {});

Future<void> setDemoConfig(FirebaseFirestore db, String key, Object value) =>
    db.collection('config').doc('demo').set({key: value}, SetOptions(merge: true));
