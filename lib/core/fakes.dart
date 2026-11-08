// In-memory implementations of the service interfaces. Used by unit tests
// and by `--dart-define=FAKE_BACKEND=true` runs, so UI work never blocks on
// Firebase or Gemini.

import 'dart:async';

import 'package:uuid/uuid.dart';

import 'models.dart';
import 'services.dart';

class FakeAuthService implements AuthService {
  FakeAuthService({this.learnerUid = 'learner-1'});
  final String learnerUid;
  String? _uid;

  @override
  String? get uid => _uid;

  @override
  Future<String> signInLearner() async => _uid = learnerUid;

  @override
  Future<void> signOut() async => _uid = null;
}

class _Store<T> {
  final Map<String, T> items = {};
  final _controller = StreamController<Map<String, T>>.broadcast();

  void put(String id, T value) {
    items[id] = value;
    _controller.add(Map.unmodifiable(items));
  }

  void remove(String id) {
    items.remove(id);
    _controller.add(Map.unmodifiable(items));
  }

  Stream<Map<String, T>> watch() async* {
    yield Map.unmodifiable(items);
    yield* _controller.stream;
  }
}

class FakeRecipeRepository implements RecipeRepository {
  FakeRecipeRepository(Recipe recipe) {
    _store.put(recipe.id, recipe);
  }
  final _store = _Store<Recipe>();

  @override
  Stream<Recipe> watch(String recipeId) =>
      _store.watch().map((m) => m[recipeId]).where((r) => r != null).cast();
}

class FakeSessionRepository implements SessionRepository {
  final _sessions = _Store<CookingSession>();

  @override
  Future<CookingSession> createOrResume(String learnerId, Recipe recipe) async {
    final matching =
        _sessions.items.values
            .where((s) => s.learnerId == learnerId && s.recipeId == recipe.id)
            .toList()
          ..sort((a, b) {
            final byCreation = b.createdAt.compareTo(a.createdAt);
            return byCreation != 0 ? byCreation : b.id.compareTo(a.id);
          });
    if (matching.isNotEmpty) return matching.first;
    return createNew(learnerId, recipe);
  }

  @override
  Future<CookingSession> createNew(String learnerId, Recipe recipe) async {
    final now = DateTime.now();
    final s = CookingSession(
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
    _sessions.put(s.id, s);
    return s;
  }

  @override
  Stream<CookingSession> watch(String sessionId) => _sessions
      .watch()
      .map((m) => m[sessionId])
      .where((s) => s != null)
      .cast();

  @override
  Future<CookingSession> update(String sessionId,
      CookingSession Function(CookingSession current) mutate) async {
    final next = mutate(_sessions.items[sessionId]!);
    _sessions.put(sessionId, next);
    return next;
  }

  @override
  Future<void> deleteSession(String sessionId) async =>
      _sessions.remove(sessionId);
}
