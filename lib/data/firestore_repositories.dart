// Firestore + Auth implementations of lib/core/services.dart.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/services.dart';
import 'firestore_codec.dart';

class FirebaseAuthService implements AuthService {
  FirebaseAuthService(this._auth);
  final FirebaseAuth _auth;

  @override
  String? get uid => _auth.currentUser?.uid;

  String? get email => _auth.currentUser?.email;

  @override
  Future<String> signInLearner() async {
    final existing = _auth.currentUser;
    if (existing != null) return existing.uid;
    final cred = await _auth.signInAnonymously();
    return cred.user!.uid;
  }

  @override
  Future<void> signOut() => _auth.signOut();
}

class FirestoreRecipeRepository implements RecipeRepository {
  FirestoreRecipeRepository(this._db, this._bundled);
  final FirebaseFirestore _db;
  final Recipe _bundled;

  DocumentReference<Map<String, dynamic>> _doc(String id) =>
      _db.collection('recipes').doc(id);

  @override
  Stream<Recipe> watch(String recipeId) => _doc(recipeId).snapshots().map((s) {
        final data = s.data();
        // Unseeded project: fall back to the bundled recipe.
        if (data == null) return _bundled;
        return Recipe.fromMap({...data, 'id': recipeId});
      });
}

class FirestoreSessionRepository implements SessionRepository {
  FirestoreSessionRepository(this._db);
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _sessions =>
      _db.collection('sessions');
  CollectionReference<Map<String, dynamic>> _checkpoints(String sessionId) =>
      _sessions.doc(sessionId).collection('checkpoints');

  @override
  Future<CookingSession> createOrResume(String learnerId, Recipe recipe) async {
    final existing = await _sessions
        .where('learnerId', isEqualTo: learnerId)
        .where('recipeId', isEqualTo: recipe.id)
        .orderBy('createdAt', descending: true)
        .orderBy(FieldPath.documentId, descending: true)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      final d = existing.docs.first;
      return CookingSession.fromMap(d.id, d.data());
    }
    return createNew(learnerId, recipe);
  }

  @override
  Future<CookingSession> createNew(String learnerId, Recipe recipe) async {
    final now = DateTime.now();
    final session = CookingSession(
      id: const Uuid().v4(),
      learnerId: learnerId,
      recipeId: recipe.id,
      recipeVersion: recipe.version,
      ingredients: const {},
      substitutions: const [],
      currentStepId: recipe.steps.first.id,
      completedStepIds: const [],
      revision: 0,
      createdAt: now,
      updatedAt: now,
    );
    await _sessions.doc(session.id).set(encodeDoc(session.toMap()));
    return session;
  }

  @override
  Stream<CookingSession> watch(String sessionId) => _sessions
      .doc(sessionId)
      .snapshots()
      .where((s) => s.exists)
      .map((s) => CookingSession.fromMap(s.id, s.data()!));

  @override
  Future<CookingSession> update(String sessionId,
      CookingSession Function(CookingSession current) mutate) {
    final ref = _sessions.doc(sessionId);
    return _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final next = mutate(CookingSession.fromMap(snap.id, snap.data()!))
          .copyWith(updatedAt: DateTime.now());
      tx.set(ref, encodeDoc(next.toMap()));
      return next;
    });
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    // Also clears legacy checkpoint photos stored under the session.
    final cps = await _checkpoints(sessionId).get();
    final batch = _db.batch();
    for (final d in cps.docs) {
      batch.delete(d.reference);
    }
    batch.delete(_sessions.doc(sessionId));
    await batch.commit();
  }
}
