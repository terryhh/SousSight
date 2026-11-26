// FirestoreSessionRepository, FirestoreRecipeRepository and
// FirebaseAuthService against a tiny in-memory stand-in for the Firestore and
// Auth SDK surfaces they call (noSuchMethod fakes). This checks the
// repositories' own logic, including the SS-072 step-operation transaction; it
// says nothing about Firestore's real transaction or offline behaviour, and
// no emulator or network is involved.
//
// The SDK marks these types @sealed so apps do not subclass them in
// production; a test double is the intended exception.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/data/firestore_repositories.dart';
import 'package:soussight/data/offline_ops.dart';

typedef _Data = Map<String, dynamic>;

class _Db implements FirebaseFirestore {
  final Map<String, _Data> docs = {};
  final _changes = StreamController<String>.broadcast();
  int transactions = 0;
  int writes = 0;

  void write(String path, _Data? data) {
    writes++;
    if (data == null) {
      docs.remove(path);
    } else {
      docs[path] = Map.of(data);
    }
    _changes.add(path);
  }

  @override
  dynamic noSuchMethod(Invocation i) {
    switch (i.memberName) {
      case #collection:
        return _Col(this, i.positionalArguments.single as String);
      case #runTransaction:
        transactions++;
        final handler = i.positionalArguments.single as Function;
        return Function.apply(handler, [_Tx(this)]);
      case #batch:
        return _Batch(this);
    }
    return super.noSuchMethod(i);
  }
}

class _Snap implements DocumentSnapshot<_Data> {
  _Snap(this._db, this._path, this._data);
  final _Db _db;
  final String _path;
  final _Data? _data;

  @override
  dynamic noSuchMethod(Invocation i) => switch (i.memberName) {
    #id => _path.split('/').last,
    #exists => _data != null,
    #data => _data == null ? null : Map<String, dynamic>.of(_data),
    #reference => _Doc(_db, _path),
    _ => super.noSuchMethod(i),
  };
}

class _QuerySnap extends _Snap implements QueryDocumentSnapshot<_Data> {
  _QuerySnap(super._db, super._path, super._data);
}

class _Doc implements DocumentReference<_Data> {
  _Doc(this._db, this.path);
  final _Db _db;
  @override
  final String path;

  _Snap _snap() => _Snap(_db, path, _db.docs[path]);

  @override
  dynamic noSuchMethod(Invocation i) {
    switch (i.memberName) {
      case #id:
        return path.split('/').last;
      case #set:
        _db.write(path, i.positionalArguments.first as _Data);
        return Future<void>.value();
      case #collection:
        return _Col(_db, '$path/${i.positionalArguments.single}');
      case #snapshots:
        late final StreamController<DocumentSnapshot<_Data>> out;
        StreamSubscription<String>? sub;
        out = StreamController<DocumentSnapshot<_Data>>(
          onListen: () {
            out.add(_snap());
            sub = _db._changes.stream
                .where((p) => p == path)
                .listen((_) => out.add(_snap()));
          },
          onCancel: () => sub?.cancel(),
        );
        return out.stream;
    }
    return super.noSuchMethod(i);
  }
}

class _Col implements CollectionReference<_Data> {
  _Col(this._db, this._path, [this._filters = const {}, this._limit]);
  final _Db _db;
  final String _path;
  final Map<String, Object?> _filters;
  final int? _limit;

  @override
  dynamic noSuchMethod(Invocation i) {
    switch (i.memberName) {
      case #doc:
        return _Doc(_db, '$_path/${i.positionalArguments.single}');
      case #where:
        return _Col(_db, _path, {
          ..._filters,
          i.positionalArguments.single as String: i.namedArguments[#isEqualTo],
        }, _limit);
      case #orderBy:
        return this; // Results are sorted newest first below.
      case #limit:
        return _Col(_db, _path, _filters, i.positionalArguments.single as int);
      case #get:
        final prefix = '$_path/';
        final matches =
            [
              for (final e in _db.docs.entries)
                if (e.key.startsWith(prefix) &&
                    !e.key.substring(prefix.length).contains('/') &&
                    _filters.entries.every((f) => e.value[f.key] == f.value))
                  _QuerySnap(_db, e.key, e.value),
            ]..sort((a, b) {
              final byTime = readTime(b._data!['createdAt'])
                  .compareTo(readTime(a._data!['createdAt']));
              return byTime != 0 ? byTime : b._path.compareTo(a._path);
            });
        return Future<QuerySnapshot<_Data>>.value(
          _Query(matches.take(_limit ?? matches.length).toList()),
        );
    }
    return super.noSuchMethod(i);
  }
}

class _Query implements QuerySnapshot<_Data> {
  _Query(this.docs);
  @override
  final List<QueryDocumentSnapshot<_Data>> docs;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Tx implements Transaction {
  _Tx(this._db);
  final _Db _db;
  @override
  dynamic noSuchMethod(Invocation i) {
    final doc = i.positionalArguments.first as _Doc;
    switch (i.memberName) {
      case #get:
        return Future<DocumentSnapshot<_Data>>.value(doc._snap());
      case #set:
        _db.write(doc.path, i.positionalArguments[1] as _Data);
        return this;
    }
    return super.noSuchMethod(i);
  }
}

class _Batch implements WriteBatch {
  _Batch(this._db);
  final _Db _db;
  final _deletes = <String>[];
  @override
  dynamic noSuchMethod(Invocation i) {
    switch (i.memberName) {
      case #delete:
        _deletes.add((i.positionalArguments.single as _Doc).path);
        return null;
      case #commit:
        for (final path in _deletes) {
          _db.write(path, null);
        }
        return Future<void>.value();
    }
    return super.noSuchMethod(i);
  }
}

class _User implements User {
  _User(this.uid);
  @override
  final String uid;
  @override
  String? get email => '$uid@example.com';
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Credential implements UserCredential {
  _Credential(this.user);
  @override
  final User? user;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Auth implements FirebaseAuth {
  User? current;
  int anonymousSignIns = 0;
  int signOuts = 0;
  @override
  User? get currentUser => current;
  @override
  Future<UserCredential> signInAnonymously() async {
    anonymousSignIns++;
    current = _User('anon-$anonymousSignIns');
    return _Credential(current);
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    current = null;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const _recipe = Recipe(
  id: 'wrap',
  version: 2,
  title: 'Wrap',
  summary: 'A wrap.',
  ingredients: [Ingredient(id: 'chickpeas', name: 'Chickpeas', qty: '1 can')],
  equipment: ['bowl'],
  steps: [
    RecipeStep(id: 'prep', title: 'Prep', instruction: 'Drain.', cue: 'Dry.'),
    RecipeStep(id: 'mix', title: 'Mix', instruction: 'Stir.', cue: 'Even.'),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

void main() {
  group('FirebaseAuthService', () {
    test('reuses the signed-in cook, otherwise signs in anonymously', () async {
      final auth = _Auth();
      final service = FirebaseAuthService(auth);
      expect(service.uid, isNull);
      expect(service.email, isNull);
      expect(await service.signInLearner(), 'anon-1');
      expect(await service.signInLearner(), 'anon-1');
      expect(auth.anonymousSignIns, 1);
      expect(service.uid, 'anon-1');
      expect(service.email, 'anon-1@example.com');
      await service.signOut();
      expect(auth.signOuts, 1);
      expect(service.uid, isNull);
    });
  });

  group('FirestoreRecipeRepository', () {
    test('reads a stored recipe, falls back to the bundled one, and never '
        'swaps another recipe for it', () async {
      final db = _Db();
      final repo = FirestoreRecipeRepository(db, _recipe);
      expect((await repo.watch('wrap').first).version, 2);
      db.write('recipes/wrap', {..._recipe.toMap(), 'version': 3});
      expect((await repo.watch('wrap').first).version, 3);
      final other = <Recipe>[];
      final sub = repo.watch('soup').listen(other.add);
      await Future<void>.delayed(Duration.zero);
      expect(other, isEmpty);
      await sub.cancel();
    });
  });

  group('FirestoreSessionRepository', () {
    late _Db db;
    late FirestoreSessionRepository repo;
    setUp(() {
      db = _Db();
      repo = FirestoreSessionRepository(db);
    });

    test('creates, resumes the newest session for the cook and recipe, and '
        'creates fresh on request', () async {
      final first = await repo.createOrResume('cook', _recipe);
      expect(first.currentStepId, 'prep');
      expect(first.revision, 0);
      expect(db.docs['sessions/${first.id}']!['learnerId'], 'cook');
      expect((await repo.createOrResume('cook', _recipe)).id, first.id);
      final other = await repo.createOrResume('someone-else', _recipe);
      expect(other.id, isNot(first.id));
      final fresh = await repo.createNew('cook', _recipe);
      expect(fresh.id, isNot(first.id));
      expect((await repo.createOrResume('cook', _recipe)).id, fresh.id);
    });

    test('watch emits saved sessions only', () async {
      final saved = await repo.createNew('cook', _recipe);
      final seen = <CookingSession>[];
      final sub = repo.watch(saved.id).listen(seen.add);
      final missing = <CookingSession>[];
      final missingSub = repo.watch('nope').listen(missing.add);
      await Future<void>.delayed(Duration.zero);
      expect(seen.single.id, saved.id);
      expect(missing, isEmpty);
      await sub.cancel();
      await missingSub.cancel();
    });

    test('an ordinary update keeps the step-operation ids (SS-072)', () async {
      final saved = await repo.createNew('cook', _recipe);
      await repo.commitStepOp(
        saved.id,
        StepOp(
          opId: 'op-1',
          kind: StepOpKind.advance,
          expectedStepId: 'prep',
          toStepId: 'mix',
        ),
      );
      final next = await repo.update(
        saved.id,
        (s) => s.copyWith(confirmedFacts: ['No dairy'], revision: 2),
      );
      expect(next.confirmedFacts, ['No dairy']);
      final stored = db.docs['sessions/${saved.id}']!;
      expect(stored[appliedOpIdsField], ['op-1']);
      expect(stored['confirmedFacts'], ['No dairy']);
      expect(stored['currentStepId'], 'mix');
    });

    test('an update without saved op ids writes none', () async {
      final saved = await repo.createNew('cook', _recipe);
      await repo.update(saved.id, (s) => s.copyWith(revision: 1));
      expect(
        db.docs['sessions/${saved.id}']!.containsKey(appliedOpIdsField),
        isFalse,
      );
    });

    test('a step operation is saved once in one transaction; a retry or an '
        'outdated one writes nothing', () async {
      final saved = await repo.createNew('cook', _recipe);
      final endsAt = DateTime.utc(2026, 11, 25, 18, 1);
      final op = StepOp(
        opId: 'op-1',
        kind: StepOpKind.advance,
        expectedStepId: 'prep',
        toStepId: 'mix',
        timer: OpTimer(id: 't', label: 'Mix', endsAt: endsAt),
      );
      final writesBefore = db.writes;
      final applied = await repo.commitStepOp(saved.id, op);
      expect(applied.outcome, StepOpOutcome.applied);
      expect(applied.session.currentStepId, 'mix');
      expect(applied.session.timerDeadline, endsAt);
      expect(db.writes, writesBefore + 1);
      expect(db.transactions, 1);

      final retry = await repo.commitStepOp(saved.id, op);
      expect(retry.outcome, StepOpOutcome.duplicate);
      expect(retry.session.currentStepId, 'mix');
      final stale = await repo.commitStepOp(
        saved.id,
        StepOp(
          opId: 'op-2',
          kind: StepOpKind.advance,
          expectedStepId: 'prep',
          toStepId: 'mix',
        ),
      );
      expect(stale.outcome, StepOpOutcome.stale);
      expect(db.writes, writesBefore + 1);
      final stored = db.docs['sessions/${saved.id}']!;
      expect(stored[appliedOpIdsField], ['op-1']);
      expect(stored['revision'], 1);
    });

    test('deleting a session also deletes its checkpoints', () async {
      final saved = await repo.createNew('cook', _recipe);
      db.write('sessions/${saved.id}/checkpoints/a', {'stepId': 'prep'});
      db.write('sessions/other/checkpoints/b', {'stepId': 'prep'});
      await repo.deleteSession(saved.id);
      expect(db.docs.containsKey('sessions/${saved.id}'), isFalse);
      expect(
        db.docs.containsKey('sessions/${saved.id}/checkpoints/a'),
        isFalse,
      );
      expect(db.docs.containsKey('sessions/other/checkpoints/b'), isTrue);
    });
  });
}
