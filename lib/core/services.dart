// Service interfaces. UIs depend only on these; lib/data/ provides the
// Firestore implementations, lib/ai/ the Gemini implementations, and
// lib/core/fakes.dart in-memory ones for tests and offline UI work.

import 'dart:typed_data';

import 'models.dart';
import 'request_machine.dart';

abstract class AuthService {
  String? get uid;

  /// Anonymous sign-in for learners. Returns the uid.
  Future<String> signInLearner();

  /// Email/password sign-in for instructors on the board.
  Future<String> signInInstructor(String email, String password);
  Future<void> signOut();
}

abstract class RecipeRepository {
  /// Recipe with the live list of reviewed substitutions merged in.
  Stream<Recipe> watch(String recipeId);

  /// Knowledge loop: append a reviewed substitution (instructors only).
  Future<void> addReviewedSubstitution(String recipeId, ReviewedSubstitution s);
}

abstract class SessionRepository {
  /// Resumes the learner's most recently created session for [recipe], or creates one.
  Future<CookingSession> createOrResume(String learnerId, Recipe recipe);

  /// Creates a fresh cook without changing any earlier session or recipe progress.
  Future<CookingSession> createNew(String learnerId, Recipe recipe);
  Stream<CookingSession> watch(String sessionId);

  /// Read-modify-write in a transaction. The mutation should bump `revision`
  /// for learner-confirmed changes.
  Future<CookingSession> update(
      String sessionId, CookingSession Function(CookingSession current) mutate);
  Future<void> saveCheckpoint(CheckpointRecord record);
  Stream<List<CheckpointRecord>> watchCheckpoints(String sessionId);
  Future<void> deleteSession(String sessionId);
}

abstract class RequestRepository {
  /// Idempotent: writing the same id twice leaves one document. Must work
  /// offline (plain set, no transaction).
  Future<void> submit(HelpRequest request);
  Stream<HelpRequest?> watch(String requestId);
  Stream<List<HelpRequest>> watchAll();
  Stream<List<HelpRequest>> watchForLearner(String learnerId);

  /// Runs [mutate] inside a transaction against the latest server copy.
  /// Throws TransitionError from the state machine unchanged.
  Future<HelpRequest> transact(
      String requestId, HelpRequest Function(HelpRequest current) mutate);

  /// Coordinator only: delete all requests and sessions for a clean demo.
  Future<void> resetDemo();
}

abstract class InstructorRepository {
  Stream<List<Instructor>> watchRoster();
  Future<void> setAvailable(String instructorId, bool available);
}

class AssessmentInput {
  const AssessmentInput({
    required this.recipe,
    required this.step,
    required this.checkpoint,
    required this.targetJpeg,
    required this.currentJpeg,
    this.previousJpeg,
    this.confirmedFacts = const [],
  });

  final Recipe recipe;
  final RecipeStep step;
  final CheckpointDef checkpoint;
  final Uint8List targetJpeg;
  final Uint8List currentJpeg;
  final Uint8List? previousJpeg;

  /// Learner-confirmed facts ("chickpeas drained", "using Greek yogurt").
  final List<String> confirmedFacts;
}

abstract class AssessmentClient {
  /// Structured visual check of one checkpoint. The caller validates the
  /// result with validateAssessment() before showing it.
  Future<Assessment> assess(AssessmentInput input);
}

class TriageInput {
  const TriageInput({
    required this.question,
    required this.recipe,
    required this.step,
    required this.trigger,
    this.recentObservations = const [],
    this.missingIngredients = const [],
    this.language = 'en',
  });

  final String question;
  final Recipe recipe;
  final RecipeStep step;
  final HandoffTrigger trigger;
  final List<String> recentObservations;
  final List<String> missingIngredients;
  final String language;
}

abstract class TriageClient {
  /// Classifies the request and writes the summary for the next owner.
  /// Never chooses the owner (routing.dart does).
  Future<TriageResult> triage(TriageInput input);
}
