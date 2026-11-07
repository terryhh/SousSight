// In-memory implementations of the service interfaces. Used by unit tests
// and by `--dart-define=FAKE_BACKEND=true` runs, so UI work never blocks on
// Firebase or Gemini.

import 'dart:async';

import 'package:uuid/uuid.dart';

import 'models.dart';
import 'request_machine.dart';
import 'services.dart';

/// Demo roster. Seeded into Firestore by tool/seed.mjs as well.
/// Priya (allergens) starts offline so the no-owner case is real.
List<Instructor> demoRoster() => const [
      Instructor(
        id: 'ana',
        displayName: 'Chef Ana',
        skills: [Skills.technique, Skills.equipment],
        available: true,
      ),
      Instructor(
        id: 'marcus',
        displayName: 'Marcus',
        skills: [Skills.substitutions, Skills.technique],
        available: true,
      ),
      Instructor(
        id: 'priya',
        displayName: 'Priya',
        skills: [Skills.allergens],
        available: false,
      ),
      Instructor(
        id: 'coordinator',
        displayName: 'FreshU-style coordinator',
        skills: [],
        available: true,
        role: InstructorRole.coordinator,
      ),
    ];

class FakeAuthService implements AuthService {
  FakeAuthService({this.learnerUid = 'learner-1'});
  final String learnerUid;
  String? _uid;

  @override
  String? get uid => _uid;

  @override
  Future<String> signInLearner() async => _uid = learnerUid;

  @override
  Future<String> signInInstructor(String email, String password) async =>
      _uid = email.split('@').first;

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

  @override
  Future<void> addReviewedSubstitution(
      String recipeId, ReviewedSubstitution s) async {
    final r = _store.items[recipeId]!;
    _store.put(recipeId,
        r.copyWith(reviewedSubstitutions: [...r.reviewedSubstitutions, s]));
  }
}

class FakeSessionRepository implements SessionRepository {
  final _sessions = _Store<CookingSession>();
  final _checkpoints = _Store<CheckpointRecord>();

  @override
  Future<CookingSession> createOrResume(String learnerId, Recipe recipe) async {
    for (final s in _sessions.items.values) {
      if (s.learnerId == learnerId && s.recipeId == recipe.id) return s;
    }
    final now = DateTime.now();
    final s = CookingSession(
      id: const Uuid().v4(),
      learnerId: learnerId,
      recipeId: recipe.id,
      recipeVersion: recipe.version,
      ingredients: {
        for (final i in recipe.ingredients) i.id: IngredientStatus.have,
      },
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
  Future<void> saveCheckpoint(CheckpointRecord record) async =>
      _checkpoints.put(record.id, record);

  @override
  Stream<List<CheckpointRecord>> watchCheckpoints(String sessionId) =>
      _checkpoints.watch().map((m) => m.values
          .where((c) => c.sessionId == sessionId)
          .toList()
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt)));

  @override
  Future<void> deleteSession(String sessionId) async {
    _sessions.remove(sessionId);
    for (final id in _checkpoints.items.keys.toList()) {
      if (_checkpoints.items[id]!.sessionId == sessionId) _checkpoints.remove(id);
    }
  }
}

class FakeRequestRepository implements RequestRepository {
  final _store = _Store<HelpRequest>();

  @override
  Future<void> submit(HelpRequest request) async {
    // Idempotent: a retry with the same id never creates a second request
    // or rewinds one that has already moved on.
    if (_store.items.containsKey(request.id)) return;
    _store.put(request.id, request);
  }

  @override
  Stream<HelpRequest?> watch(String requestId) =>
      _store.watch().map((m) => m[requestId]);

  @override
  Stream<List<HelpRequest>> watchAll() => _store.watch().map(
      (m) => m.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt)));

  @override
  Stream<List<HelpRequest>> watchForLearner(String learnerId) => watchAll()
      .map((all) => all.where((r) => r.learnerId == learnerId).toList());

  @override
  Future<HelpRequest> transact(
      String requestId, HelpRequest Function(HelpRequest current) mutate) async {
    final next = mutate(_store.items[requestId]!);
    _store.put(requestId, next);
    return next;
  }

  @override
  Future<void> resetDemo() async {
    for (final id in _store.items.keys.toList()) {
      _store.remove(id);
    }
  }
}

class FakeInstructorRepository implements InstructorRepository {
  FakeInstructorRepository([List<Instructor>? roster]) {
    for (final i in roster ?? demoRoster()) {
      _store.put(i.id, i);
    }
  }
  final _store = _Store<Instructor>();

  @override
  Stream<List<Instructor>> watchRoster() =>
      _store.watch().map((m) => m.values.toList());

  @override
  Future<void> setAvailable(String instructorId, bool available) async {
    final i = _store.items[instructorId]!;
    _store.put(instructorId, i.copyWith(available: available));
  }
}

/// Returns canned results in order, then repeats the last one.
class FakeAssessmentClient implements AssessmentClient {
  FakeAssessmentClient([List<Assessment>? script])
      : _script = script ??
            const [
              Assessment(
                outcome: AssessmentOutcome.adjust,
                observations: [
                  'About half the chickpeas are still whole and round.',
                ],
                cue: 'Fewer than about 10 whole chickpeas visible.',
                suggestedAction: 'Mash 15-20 more presses, focusing on the left side.',
                adjustmentId: 'mash_more',
                confidence: Confidence.high,
              ),
              Assessment(
                outcome: AssessmentOutcome.matchesTarget,
                observations: ['Most chickpeas are broken into coarse pieces.'],
                cue: 'Fewer than about 10 whole chickpeas visible.',
                suggestedAction: 'Confirm to move on to mixing.',
                confidence: Confidence.high,
              ),
            ];
  final List<Assessment> _script;
  int _i = 0;

  @override
  Future<Assessment> assess(AssessmentInput input) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final a = _script[_i < _script.length ? _i : _script.length - 1];
    _i++;
    return a;
  }
}

class FakeTriageClient implements TriageClient {
  @override
  Future<TriageResult> triage(TriageInput input) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final category = switch (input.trigger) {
      HandoffTrigger.substitution => RequestCategory.substitution,
      HandoffTrigger.safety => RequestCategory.safetyAllergen,
      _ => RequestCategory.technique,
    };
    return TriageResult(
      category: category,
      urgency: Urgency.normal,
      summaryForInstructor:
          'Learner at "${input.step.title}" asks: ${input.question}',
      aiUncertainty: input.trigger == HandoffTrigger.uncertainTwice
          ? 'Two photos in a row were inconclusive.'
          : null,
    );
  }
}
