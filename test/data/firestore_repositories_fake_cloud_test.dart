// Firestore repositories against an in-memory Firestore (fake_cloud_firestore).
// No emulator, project or network: this proves the queries, transactions and
// encoding the code issues, not Firestore's server behaviour or rules.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/core/services.dart';
import 'package:soussight/data/firestore_repositories.dart';

class _FakeUser implements User {
  _FakeUser(this.uid, {this.email});
  @override
  final String uid;
  @override
  final String? email;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCredential implements UserCredential {
  _FakeCredential(this.user);
  @override
  final User? user;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuth implements FirebaseAuth {
  _FakeAuth([this.currentUser]);
  @override
  User? currentUser;
  int anonymousSignIns = 0;
  int signOuts = 0;

  @override
  Future<UserCredential> signInAnonymously() async {
    anonymousSignIns++;
    return _FakeCredential(currentUser = _FakeUser('anon-$anonymousSignIns'));
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    currentUser = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _sessionDoc({
  required String learnerId,
  required String recipeId,
  required DateTime createdAt,
  String step = 'step-1',
}) => {
  'learnerId': learnerId,
  'recipeId': recipeId,
  'recipeVersion': 1,
  'ingredients': <String, Object?>{},
  'substitutions': <Object?>[],
  'currentStepId': step,
  'completedStepIds': <Object?>[],
  'revision': 0,
  'createdAt': Timestamp.fromDate(createdAt),
  'updatedAt': Timestamp.fromDate(createdAt),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Recipe recipe;
  late FakeFirebaseFirestore db;

  setUpAll(() async => recipe = await loadBundledRecipe());
  setUp(() => db = FakeFirebaseFirestore());

  group('FirebaseAuthService', () {
    test('signs in anonymously once and reuses the signed-in cook', () async {
      final auth = _FakeAuth();
      final service = FirebaseAuthService(auth);
      expect(service.uid, isNull);

      final first = await service.signInLearner();
      final again = await service.signInLearner();

      expect(first, 'anon-1');
      expect(again, first);
      expect(auth.anonymousSignIns, 1);
      expect(service.uid, first);
    });

    test('an existing account is used as is, with its email', () async {
      final auth = _FakeAuth(_FakeUser('cook-7', email: 'cook@example.test'));
      final service = FirebaseAuthService(auth);

      expect(await service.signInLearner(), 'cook-7');
      expect(service.email, 'cook@example.test');
      expect(auth.anonymousSignIns, 0);
    });

    test('sign out clears the uid', () async {
      final auth = _FakeAuth(_FakeUser('cook-7'));
      final service = FirebaseAuthService(auth);
      await service.signOut();
      expect(auth.signOuts, 1);
      expect(service.uid, isNull);
      expect(service.email, isNull);
    });
  });

  group('FirestoreRecipeRepository', () {
    test('an unseeded project falls back to the bundled recipe', () async {
      final repo = FirestoreRecipeRepository(db, recipe);
      final watched = await repo.watch(recipe.id).first;
      expect(watched.id, recipe.id);
      expect(watched.title, recipe.title);
    });

    test(
      'an unseeded different recipe is never swapped for the bundled one',
      () async {
        final repo = FirestoreRecipeRepository(db, recipe);
        final seen = <Recipe>[];
        final sub = repo.watch('other_recipe_v1').listen(seen.add);
        await pumpEventQueue();
        expect(seen, isEmpty);

        await db.collection('recipes').doc('other_recipe_v1').set({
          ...recipe.toMap(),
          'title': 'Other recipe',
        });
        await pumpEventQueue();
        await sub.cancel();

        expect(seen.single.id, 'other_recipe_v1');
        expect(seen.single.title, 'Other recipe');
      },
    );

    test(
      'a seeded recipe takes its id from the document and streams edits',
      () async {
        final doc = db.collection('recipes').doc(recipe.id);
        await doc.set({...recipe.toMap(), 'id': 'stale-id', 'title': 'Seeded'});
        final repo = FirestoreRecipeRepository(db, recipe);
        final updates = StreamIterator(repo.watch(recipe.id));

        expect(await updates.moveNext(), isTrue);
        expect(updates.current.id, recipe.id);
        expect(updates.current.title, 'Seeded');

        await doc.update({'title': 'Seeded v2'});
        expect(await updates.moveNext(), isTrue);
        expect(updates.current.title, 'Seeded v2');
        await updates.cancel();
      },
    );
  });

  group('FirestoreSessionRepository', () {
    test('createNew stores a fresh session at the first step', () async {
      final repo = FirestoreSessionRepository(db);
      final before = DateTime.now();
      final session = await repo.createNew('cook-1', recipe);

      final stored = await db.collection('sessions').doc(session.id).get();
      expect(stored.exists, isTrue);
      final data = stored.data()!;
      expect(data['learnerId'], 'cook-1');
      expect(data['recipeId'], recipe.id);
      expect(data['recipeVersion'], recipe.version);
      expect(data['currentStepId'], recipe.steps.first.id);
      expect(data['revision'], 0);
      expect(session.createdAt.isBefore(before), isFalse);
      expect(session.timerDeadline, isNull);
      expect(session.confirmedFacts, isEmpty);
    });

    test('createOrResume returns the newest session for this cook and recipe '
        'only', () async {
      final sessions = db.collection('sessions');
      final t0 = DateTime(2026, 11, 20, 18);
      await sessions
          .doc('old')
          .set(
            _sessionDoc(
              learnerId: 'cook-1',
              recipeId: recipe.id,
              createdAt: t0,
            ),
          );
      await sessions
          .doc('newest')
          .set(
            _sessionDoc(
              learnerId: 'cook-1',
              recipeId: recipe.id,
              createdAt: t0.add(const Duration(hours: 2)),
              step: 'step-3',
            ),
          );
      await sessions
          .doc('other-cook')
          .set(
            _sessionDoc(
              learnerId: 'cook-2',
              recipeId: recipe.id,
              createdAt: t0.add(const Duration(days: 1)),
            ),
          );
      await sessions
          .doc('other-recipe')
          .set(
            _sessionDoc(
              learnerId: 'cook-1',
              recipeId: 'other_recipe_v1',
              createdAt: t0.add(const Duration(days: 1)),
            ),
          );
      final repo = FirestoreSessionRepository(db);

      final resumed = await repo.createOrResume('cook-1', recipe);
      expect(resumed.id, 'newest');
      expect(resumed.currentStepId, 'step-3');
      // Timestamps read back as DateTime.
      expect(resumed.createdAt, t0.add(const Duration(hours: 2)));
    });

    test('createOrResume creates a session when none exists', () async {
      final repo = FirestoreSessionRepository(db);
      final created = await repo.createOrResume('cook-9', recipe);
      expect(created.learnerId, 'cook-9');
      expect((await repo.createOrResume('cook-9', recipe)).id, created.id);
      expect((await db.collection('sessions').get()).docs, hasLength(1));
    });

    test('watch waits for the document, then streams its updates', () async {
      final repo = FirestoreSessionRepository(db);
      final seen = <CookingSession>[];
      final sub = repo.watch('later').listen(seen.add);
      await pumpEventQueue();
      expect(seen, isEmpty, reason: 'a missing document emits nothing');

      await db
          .collection('sessions')
          .doc('later')
          .set(
            _sessionDoc(
              learnerId: 'cook-1',
              recipeId: recipe.id,
              createdAt: DateTime(2026, 11, 21),
            ),
          );
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.single.id, 'later');
      expect(seen.single.learnerId, 'cook-1');
    });

    test('update applies the mutation in a transaction, stamps updatedAt and '
        'round-trips session fields', () async {
      final repo = FirestoreSessionRepository(db);
      final created = await repo.createNew('cook-1', recipe);
      final deadline = DateTime(2026, 11, 25, 19, 30);
      final stepId = recipe.steps.last.id;

      final next = await repo.update(
        created.id,
        (s) => s.copyWith(
          currentStepId: stepId,
          completedStepIds: [recipe.steps.first.id],
          ingredients: {
            'bread': IngredientStatus.have,
            'jam': IngredientStatus.missing,
            'butter': IngredientStatus.substituted,
          },
          substitutions: const [
            SessionSubstitution(
              ingredientId: 'butter',
              substitute: 'olive oil',
              source: 'reviewed',
            ),
          ],
          confirmedFacts: ['No nuts in this kitchen.'],
          timerId: 't1',
          timerLabel: 'Toast',
          timerDeadline: deadline,
          revision: s.revision + 1,
        ),
      );
      expect(next.updatedAt.isBefore(created.updatedAt), isFalse);

      // Read back with get(): fake_cloud_firestore 4.5 does not push
      // transaction writes to snapshots() listeners (real Firestore does).
      final doc = await db.collection('sessions').doc(created.id).get();
      final reread = CookingSession.fromMap(doc.id, doc.data()!);
      expect(reread.currentStepId, stepId);
      expect(reread.completedStepIds, [recipe.steps.first.id]);
      expect(reread.ingredients, {
        'bread': IngredientStatus.have,
        'jam': IngredientStatus.missing,
        'butter': IngredientStatus.substituted,
      });
      final sub = reread.substitutions.single;
      expect(
        (sub.ingredientId, sub.substitute, sub.source, sub.requestId),
        ('butter', 'olive oil', 'reviewed', null),
      );
      expect(reread.confirmedFacts, ['No nuts in this kitchen.']);
      expect(reread.timerDeadline, deadline);
      expect(reread.timerLabel, 'Toast');
      expect(reread.revision, 1);
      expect(reread.createdAt, created.createdAt);
    });

    test('an unknown ingredient status from storage reads as "have"', () async {
      await db.collection('sessions').doc('legacy').set({
        ..._sessionDoc(
          learnerId: 'cook-1',
          recipeId: recipe.id,
          createdAt: DateTime(2026, 11, 1),
        ),
        'ingredients': {'bread': 'borrowed-from-neighbour'},
        'substitutions': [
          {'ingredientId': 'jam', 'substitute': 'honey'},
        ],
      });
      final session = await FirestoreSessionRepository(db)
          .watch('legacy')
          .first;
      expect(session.ingredients, {'bread': IngredientStatus.have});
      expect(session.substitutions.single.source, 'reviewed');
    });

    test(
      'deleteSession removes the session and its legacy checkpoints only',
      () async {
        final repo = FirestoreSessionRepository(db);
        final doomed = await repo.createNew('cook-1', recipe);
        final kept = await repo.createNew('cook-1', recipe);
        final sessions = db.collection('sessions');
        await sessions.doc(doomed.id).collection('checkpoints').doc('a').set({
          'photo': 'legacy',
        });
        await sessions.doc(doomed.id).collection('checkpoints').doc('b').set({
          'photo': 'legacy',
        });
        await sessions.doc(kept.id).collection('checkpoints').doc('c').set({
          'photo': 'keep',
        });

        await repo.deleteSession(doomed.id);

        expect((await sessions.doc(doomed.id).get()).exists, isFalse);
        expect(
          (await sessions.doc(doomed.id).collection('checkpoints').get()).docs,
          isEmpty,
        );
        expect((await sessions.doc(kept.id).get()).exists, isTrue);
        expect(
          (await sessions.doc(kept.id).collection('checkpoints').get()).docs,
          hasLength(1),
        );
      },
    );

    test('deleting a session without checkpoints succeeds', () async {
      final repo = FirestoreSessionRepository(db);
      final session = await repo.createNew('cook-1', recipe);
      await repo.deleteSession(session.id);
      expect((await db.collection('sessions').get()).docs, isEmpty);
    });
  });

  // The in-memory fakes stand in for Firestore across the app's widget tests,
  // so they must behave the same way for the flows the app relies on.
  group('fake and Firestore session repositories agree', () {
    final makers = <String, SessionRepository Function()>{
      'fake': FakeSessionRepository.new,
      'firestore': () => FirestoreSessionRepository(FakeFirebaseFirestore()),
    };
    for (final entry in makers.entries) {
      test('${entry.key}: resume, update, new cook and delete', () async {
        final repo = entry.value();
        final first = await repo.createOrResume('cook-1', recipe);
        expect((await repo.createOrResume('cook-1', recipe)).id, first.id);

        final updated = await repo.update(
          first.id,
          (s) => s.copyWith(revision: 3),
        );
        expect(updated.revision, 3);
        expect((await repo.createOrResume('cook-1', recipe)).revision, 3);

        await Future<void>.delayed(const Duration(milliseconds: 2));
        final fresh = await repo.createNew('cook-1', recipe);
        expect(fresh.revision, 0);
        expect((await repo.createOrResume('cook-1', recipe)).id, fresh.id);

        await repo.deleteSession(fresh.id);
        expect((await repo.createOrResume('cook-1', recipe)).id, first.id);
      });
    }

    test('fake auth signs in and out like the Firebase one', () async {
      final AuthService fake = FakeAuthService(learnerUid: 'cook-3');
      expect(fake.uid, isNull);
      expect(await fake.signInLearner(), 'cook-3');
      expect(fake.uid, 'cook-3');
      await fake.signOut();
      expect(fake.uid, isNull);
    });
  });
}
