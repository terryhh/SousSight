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
  Future<String> signInInstructor(String email, String password) async {
    final cred =
        await _auth.signInWithEmailAndPassword(email: email, password: password);
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

  @override
  Future<void> addReviewedSubstitution(
      String recipeId, ReviewedSubstitution s) async {
    await _doc(recipeId).update({
      'reviewedSubstitutions': FieldValue.arrayUnion([s.toMap()]),
    });
  }
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
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      final d = existing.docs.first;
      return CookingSession.fromMap(d.id, d.data());
    }
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
  Future<void> saveCheckpoint(CheckpointRecord record) => _checkpoints(record.sessionId)
      .doc(record.id)
      .set(encodeDoc(record.toMap()));

  @override
  Stream<List<CheckpointRecord>> watchCheckpoints(String sessionId) =>
      _checkpoints(sessionId).orderBy('capturedAt').snapshots().map((q) => [
            for (final d in q.docs) CheckpointRecord.fromMap(d.id, d.data()),
          ]);

  @override
  Future<void> deleteSession(String sessionId) async {
    final cps = await _checkpoints(sessionId).get();
    final batch = _db.batch();
    for (final d in cps.docs) {
      batch.delete(d.reference);
    }
    batch.delete(_sessions.doc(sessionId));
    await batch.commit();
  }
}

class FirestoreRequestRepository implements RequestRepository {
  FirestoreRequestRepository(this._db);
  final FirebaseFirestore _db;
  final _submitted = <String>{};

  CollectionReference<Map<String, dynamic>> get _requests =>
      _db.collection('requests');

  HelpRequest _from(DocumentSnapshot<Map<String, dynamic>> d) =>
      HelpRequest.fromMap(d.id, d.data()!);

  @override
  Future<void> submit(HelpRequest request) async {
    // Plain set so it queues offline. The id is created when the help sheet
    // opens, and this guard stops a double tap from writing twice; rules also
    // reject any update that moves a request back to 'submitted'.
    if (!_submitted.add(request.id)) return;
    await _requests.doc(request.id).set(encodeDoc(request.toMap()));
  }

  @override
  Stream<HelpRequest?> watch(String requestId) => _requests
      .doc(requestId)
      .snapshots()
      .map((s) => s.exists ? _from(s) : null);

  @override
  Stream<List<HelpRequest>> watchAll() => _requests
      .orderBy('createdAt')
      .snapshots()
      .map((q) => [for (final d in q.docs) _from(d)]);

  @override
  Stream<List<HelpRequest>> watchForLearner(String learnerId) => _requests
      .where('learnerId', isEqualTo: learnerId)
      .snapshots()
      .map((q) => [for (final d in q.docs) _from(d)]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt)));

  @override
  Future<HelpRequest> transact(
      String requestId, HelpRequest Function(HelpRequest current) mutate) {
    final ref = _requests.doc(requestId);
    return _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final next = mutate(_from(snap));
      // update (not set) so Functions-owned `notify` is never overwritten.
      tx.update(ref, encodeDoc(next.toMap()));
      return next;
    });
  }

  @override
  Future<void> resetDemo() async {
    final batch = _db.batch();
    for (final d in (await _requests.get()).docs) {
      batch.delete(d.reference);
    }
    final sessions = await _db.collection('sessions').get();
    for (final s in sessions.docs) {
      for (final c in (await s.reference.collection('checkpoints').get()).docs) {
        batch.delete(c.reference);
      }
      batch.delete(s.reference);
    }
    await batch.commit();
  }
}

class FirestoreInstructorRepository implements InstructorRepository {
  FirestoreInstructorRepository(this._db);
  final FirebaseFirestore _db;

  @override
  Stream<List<Instructor>> watchRoster() =>
      _db.collection('instructors').snapshots().map((q) => [
            for (final d in q.docs) Instructor.fromMap(d.id, d.data()),
          ]);

  @override
  Future<void> setAvailable(String instructorId, bool available) => _db
      .collection('instructors')
      .doc(instructorId)
      .update({'available': available});
}
