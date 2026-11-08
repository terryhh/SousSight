// Service interfaces. UIs depend only on these; lib/data/ provides the
// Firestore implementations and lib/core/fakes.dart in-memory ones for tests
// and offline UI work.

import 'models.dart';

abstract class AuthService {
  String? get uid;

  /// Anonymous sign-in for the cook. Returns the uid.
  Future<String> signInLearner();
  Future<void> signOut();
}

abstract class RecipeRepository {
  /// Recipe with the live list of reviewed substitutions merged in.
  Stream<Recipe> watch(String recipeId);
}

abstract class SessionRepository {
  /// Resumes the cook's open session for [recipe], or creates one.
  Future<CookingSession> createOrResume(String learnerId, Recipe recipe);
  Stream<CookingSession> watch(String sessionId);

  /// Read-modify-write in a transaction. The mutation should bump `revision`
  /// for cook-confirmed changes.
  Future<CookingSession> update(
      String sessionId, CookingSession Function(CookingSession current) mutate);
  Future<void> deleteSession(String sessionId);
}
