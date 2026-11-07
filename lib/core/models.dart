// Shared domain models. This file is the contract between the learner app,
// the instructor board, the AI clients, the data layer, and Cloud Functions.
// Firestore field names are the `toMap()` keys below; functions/ reads them too.
//
// Models stay free of Firebase imports. The data layer converts at the
// boundary: DateTime <-> Timestamp, Uint8List <-> Blob. `fromMap` accepts
// either form so fakes and Firestore can share it.

import 'dart:typed_data';

DateTime readTime(Object? v) {
  if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
  if (v is DateTime) return v;
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  // Firestore Timestamp (duck-typed to keep this file Firebase-free).
  return (v as dynamic).toDate() as DateTime;
}

DateTime? readTimeOrNull(Object? v) => v == null ? null : readTime(v);

Uint8List readBytes(Object? v) {
  if (v is Uint8List) return v;
  if (v is List<int>) return Uint8List.fromList(v);
  // Firestore Blob.
  return (v as dynamic).bytes as Uint8List;
}

T readEnum<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

List<String> readStrings(Object? v) =>
    v == null ? const [] : List<String>.from(v as List);

const _unset = Object();

// ---------------------------------------------------------------- recipe

class Ingredient {
  const Ingredient({
    required this.id,
    required this.name,
    required this.qty,
    this.optional = false,
    this.allergens = const [],
  });

  final String id;
  final String name;
  final String qty;
  final bool optional;
  final List<String> allergens;

  factory Ingredient.fromMap(Map<String, dynamic> m) => Ingredient(
    id: m['id'] as String,
    name: m['name'] as String,
    qty: m['qty'] as String? ?? '',
    optional: m['optional'] as bool? ?? false,
    allergens: readStrings(m['allergens']),
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'qty': qty,
    'optional': optional,
    'allergens': allergens,
  };
}

class RecipeStep {
  const RecipeStep({
    required this.id,
    required this.title,
    required this.instruction,
    required this.cue,
    this.checkpointId,
    this.timerSeconds,
  });

  final String id;
  final String title;
  final String instruction;

  /// The visible cue the learner should learn to judge for themselves.
  final String cue;
  final String? checkpointId;
  final int? timerSeconds;

  factory RecipeStep.fromMap(Map<String, dynamic> m) => RecipeStep(
    id: m['id'] as String,
    title: m['title'] as String,
    instruction: m['instruction'] as String,
    cue: m['cue'] as String? ?? '',
    checkpointId: m['checkpointId'] as String?,
    timerSeconds: m['timerSeconds'] as int?,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'instruction': instruction,
    'cue': cue,
    'checkpointId': checkpointId,
    'timerSeconds': timerSeconds,
  };
}

class CheckpointDef {
  const CheckpointDef({
    required this.id,
    required this.stepId,
    required this.target,
    required this.cues,
    required this.targetImageAsset,
    required this.allowedAdjustments,
  });

  final String id;
  final String stepId;

  /// Plain-language description of the reviewed target state.
  final String target;
  final List<String> cues;
  final String targetImageAsset;

  /// Adjustment ids the model may suggest (keys of Recipe.adjustmentLabels).
  final List<String> allowedAdjustments;

  factory CheckpointDef.fromMap(Map<String, dynamic> m) => CheckpointDef(
    id: m['id'] as String,
    stepId: m['stepId'] as String,
    target: m['target'] as String,
    cues: readStrings(m['cues']),
    targetImageAsset: m['targetImageAsset'] as String,
    allowedAdjustments: readStrings(m['allowedAdjustments']),
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'stepId': stepId,
    'target': target,
    'cues': cues,
    'targetImageAsset': targetImageAsset,
    'allowedAdjustments': allowedAdjustments,
  };
}

class ReviewedSubstitution {
  const ReviewedSubstitution({
    required this.ingredientId,
    required this.substitute,
    required this.note,
    required this.approvedBy,
    this.sourceRequestId,
  });

  final String ingredientId;
  final String substitute;
  final String note;

  /// Display name of the reviewer, shown to learners as credit.
  final String approvedBy;
  final String? sourceRequestId;

  factory ReviewedSubstitution.fromMap(Map<String, dynamic> m) =>
      ReviewedSubstitution(
        ingredientId: m['ingredientId'] as String,
        substitute: m['substitute'] as String,
        note: m['note'] as String? ?? '',
        approvedBy: m['approvedBy'] as String? ?? '',
        sourceRequestId: m['sourceRequestId'] as String?,
      );

  Map<String, dynamic> toMap() => {
    'ingredientId': ingredientId,
    'substitute': substitute,
    'note': note,
    'approvedBy': approvedBy,
    'sourceRequestId': sourceRequestId,
  };
}

class Recipe {
  const Recipe({
    required this.id,
    required this.version,
    required this.title,
    required this.summary,
    required this.ingredients,
    required this.equipment,
    required this.steps,
    required this.checkpoints,
    required this.reviewedSubstitutions,
    required this.adjustmentLabels,
  });

  final String id;
  final int version;
  final String title;
  final String summary;
  final List<Ingredient> ingredients;
  final List<String> equipment;
  final List<RecipeStep> steps;
  final List<CheckpointDef> checkpoints;
  final List<ReviewedSubstitution> reviewedSubstitutions;
  final Map<String, String> adjustmentLabels;

  RecipeStep step(String id) => steps.firstWhere((s) => s.id == id);
  CheckpointDef? checkpointForStep(String stepId) {
    for (final c in checkpoints) {
      if (c.stepId == stepId) return c;
    }
    return null;
  }

  Ingredient ingredient(String id) => ingredients.firstWhere((i) => i.id == id);

  Recipe copyWith({List<ReviewedSubstitution>? reviewedSubstitutions}) =>
      Recipe(
        id: id,
        version: version,
        title: title,
        summary: summary,
        ingredients: ingredients,
        equipment: equipment,
        steps: steps,
        checkpoints: checkpoints,
        reviewedSubstitutions:
            reviewedSubstitutions ?? this.reviewedSubstitutions,
        adjustmentLabels: adjustmentLabels,
      );

  factory Recipe.fromMap(Map<String, dynamic> m) => Recipe(
    id: m['id'] as String,
    version: m['version'] as int,
    title: m['title'] as String,
    summary: m['summary'] as String? ?? '',
    ingredients: [
      for (final i in m['ingredients'] as List)
        Ingredient.fromMap(Map<String, dynamic>.from(i as Map)),
    ],
    equipment: readStrings(m['equipment']),
    steps: [
      for (final s in m['steps'] as List)
        RecipeStep.fromMap(Map<String, dynamic>.from(s as Map)),
    ],
    checkpoints: [
      for (final c in m['checkpoints'] as List)
        CheckpointDef.fromMap(Map<String, dynamic>.from(c as Map)),
    ],
    reviewedSubstitutions: [
      for (final r in (m['reviewedSubstitutions'] as List? ?? const []))
        ReviewedSubstitution.fromMap(Map<String, dynamic>.from(r as Map)),
    ],
    adjustmentLabels: Map<String, String>.from(
      m['adjustmentLabels'] as Map? ?? {},
    ),
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'version': version,
    'title': title,
    'summary': summary,
    'ingredients': [for (final i in ingredients) i.toMap()],
    'equipment': equipment,
    'steps': [for (final s in steps) s.toMap()],
    'checkpoints': [for (final c in checkpoints) c.toMap()],
    'reviewedSubstitutions': [for (final r in reviewedSubstitutions) r.toMap()],
    'adjustmentLabels': adjustmentLabels,
  };
}

// ---------------------------------------------------------------- session

enum IngredientStatus { have, missing, substituted }

class SessionSubstitution {
  const SessionSubstitution({
    required this.ingredientId,
    required this.substitute,
    required this.source,
    this.requestId,
  });

  final String ingredientId;
  final String substitute;

  /// 'reviewed' (from the recipe) or 'instructor' (from an answered request).
  final String source;
  final String? requestId;

  factory SessionSubstitution.fromMap(Map<String, dynamic> m) =>
      SessionSubstitution(
        ingredientId: m['ingredientId'] as String,
        substitute: m['substitute'] as String,
        source: m['source'] as String? ?? 'reviewed',
        requestId: m['requestId'] as String?,
      );

  Map<String, dynamic> toMap() => {
    'ingredientId': ingredientId,
    'substitute': substitute,
    'source': source,
    'requestId': requestId,
  };
}

class CookingSession {
  const CookingSession({
    required this.id,
    required this.learnerId,
    required this.recipeId,
    required this.recipeVersion,
    required this.ingredients,
    required this.substitutions,
    required this.currentStepId,
    required this.completedStepIds,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.language = 'en',
    this.timerDeadline,
    this.timerLabel,
    this.timerId,
    this.confirmedFacts = const [],
  });

  final String id;
  final String learnerId;
  final String recipeId;
  final int recipeVersion;
  final Map<String, IngredientStatus> ingredients;
  final List<SessionSubstitution> substitutions;
  final String currentStepId;
  final List<String> completedStepIds;

  /// Incremented on every learner-confirmed change. Async results carry the
  /// revision they were requested at; see core/staleness.dart.
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String language;

  /// Timers store a deadline, never a countdown, so navigation can't reset them.
  final DateTime? timerDeadline;
  final String? timerLabel;
  final String? timerId;
  final List<String> confirmedFacts;

  CookingSession copyWith({
    Map<String, IngredientStatus>? ingredients,
    List<SessionSubstitution>? substitutions,
    String? currentStepId,
    List<String>? completedStepIds,
    int? revision,
    DateTime? updatedAt,
    String? language,
    Object? timerDeadline = _unset,
    Object? timerLabel = _unset,
    Object? timerId = _unset,
    List<String>? confirmedFacts,
  }) => CookingSession(
    id: id,
    learnerId: learnerId,
    recipeId: recipeId,
    recipeVersion: recipeVersion,
    ingredients: ingredients ?? this.ingredients,
    substitutions: substitutions ?? this.substitutions,
    currentStepId: currentStepId ?? this.currentStepId,
    completedStepIds: completedStepIds ?? this.completedStepIds,
    revision: revision ?? this.revision,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    language: language ?? this.language,
    timerDeadline: identical(timerDeadline, _unset)
        ? this.timerDeadline
        : timerDeadline as DateTime?,
    timerLabel: identical(timerLabel, _unset)
        ? this.timerLabel
        : timerLabel as String?,
    timerId: identical(timerId, _unset) ? this.timerId : timerId as String?,
    confirmedFacts: confirmedFacts ?? this.confirmedFacts,
  );

  factory CookingSession.fromMap(String id, Map<String, dynamic> m) =>
      CookingSession(
        id: id,
        learnerId: m['learnerId'] as String,
        recipeId: m['recipeId'] as String,
        recipeVersion: m['recipeVersion'] as int,
        ingredients: {
          for (final e in Map<String, dynamic>.from(
            m['ingredients'] as Map? ?? {},
          ).entries)
            e.key: readEnum(
              IngredientStatus.values,
              e.value,
              IngredientStatus.have,
            ),
        },
        substitutions: [
          for (final s in (m['substitutions'] as List? ?? const []))
            SessionSubstitution.fromMap(Map<String, dynamic>.from(s as Map)),
        ],
        currentStepId: m['currentStepId'] as String,
        completedStepIds: readStrings(m['completedStepIds']),
        revision: m['revision'] as int? ?? 0,
        createdAt: readTime(m['createdAt']),
        updatedAt: readTime(m['updatedAt']),
        language: m['language'] as String? ?? 'en',
        timerDeadline: readTimeOrNull(m['timerDeadline']),
        timerLabel: m['timerLabel'] as String?,
        timerId: m['timerId'] as String?,
        confirmedFacts: readStrings(m['confirmedFacts']),
      );

  Map<String, dynamic> toMap() => {
    'learnerId': learnerId,
    'recipeId': recipeId,
    'recipeVersion': recipeVersion,
    'ingredients': {for (final e in ingredients.entries) e.key: e.value.name},
    'substitutions': [for (final s in substitutions) s.toMap()],
    'currentStepId': currentStepId,
    'completedStepIds': completedStepIds,
    'revision': revision,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'language': language,
    'timerDeadline': timerDeadline,
    'timerLabel': timerLabel,
    'timerId': timerId,
    'confirmedFacts': confirmedFacts,
  };
}

// ---------------------------------------------------------------- checkpoints

enum SelfRating { ready, notYet, notSure }

enum AssessmentOutcome { matchesTarget, adjust, uncertain, needBetterView }

enum Confidence { low, medium, high }

class Assessment {
  const Assessment({
    required this.outcome,
    required this.observations,
    required this.cue,
    required this.suggestedAction,
    required this.confidence,
    this.adjustmentId,
    this.outOfScope = false,
    this.outOfScopeReason,
  });

  final AssessmentOutcome outcome;

  /// Visible facts only, each tied to what is in the photo.
  final List<String> observations;

  /// The visual cue the learner should learn to look for.
  final String cue;
  final String suggestedAction;
  final Confidence confidence;

  /// One of CheckpointDef.allowedAdjustments, or null.
  final String? adjustmentId;
  final bool outOfScope;
  final String? outOfScopeReason;

  Assessment copyWith({
    AssessmentOutcome? outcome,
    Object? adjustmentId = _unset,
  }) => Assessment(
    outcome: outcome ?? this.outcome,
    observations: observations,
    cue: cue,
    suggestedAction: suggestedAction,
    confidence: confidence,
    adjustmentId: identical(adjustmentId, _unset)
        ? this.adjustmentId
        : adjustmentId as String?,
    outOfScope: outOfScope,
    outOfScopeReason: outOfScopeReason,
  );

  factory Assessment.fromMap(Map<String, dynamic> m) => Assessment(
    outcome: readEnum(
      AssessmentOutcome.values,
      m['outcome'],
      AssessmentOutcome.uncertain,
    ),
    observations: readStrings(m['observations']),
    cue: m['cue'] as String? ?? '',
    suggestedAction: m['suggestedAction'] as String? ?? '',
    confidence: readEnum(Confidence.values, m['confidence'], Confidence.low),
    adjustmentId: m['adjustmentId'] as String?,
    outOfScope: m['outOfScope'] as bool? ?? false,
    outOfScopeReason: m['outOfScopeReason'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'outcome': outcome.name,
    'observations': observations,
    'cue': cue,
    'suggestedAction': suggestedAction,
    'confidence': confidence.name,
    'adjustmentId': adjustmentId,
    'outOfScope': outOfScope,
    'outOfScopeReason': outOfScopeReason,
  };
}

class CheckpointRecord {
  const CheckpointRecord({
    required this.id,
    required this.sessionId,
    required this.stepId,
    required this.checkpointDefId,
    required this.photoJpeg,
    required this.capturedAt,
    required this.selfRating,
    required this.sessionRevision,
    this.assessment,
    this.learnerConfirmed = false,
  });

  final String id;
  final String sessionId;
  final String stepId;
  final String checkpointDefId;

  /// <=768px JPEG, ~60-150 KB. Stored as a Firestore Blob (no Cloud Storage).
  final Uint8List photoJpeg;
  final DateTime capturedAt;

  /// Predict-then-check: the learner's own call, made before the model's.
  final SelfRating selfRating;
  final int sessionRevision;
  final Assessment? assessment;
  final bool learnerConfirmed;

  bool? get selfRatingAgreed {
    final a = assessment;
    if (a == null || selfRating == SelfRating.notSure) return null;
    if (a.outcome == AssessmentOutcome.matchesTarget) {
      return selfRating == SelfRating.ready;
    }
    if (a.outcome == AssessmentOutcome.adjust) {
      return selfRating == SelfRating.notYet;
    }
    return null;
  }

  CheckpointRecord copyWith({Assessment? assessment, bool? learnerConfirmed}) =>
      CheckpointRecord(
        id: id,
        sessionId: sessionId,
        stepId: stepId,
        checkpointDefId: checkpointDefId,
        photoJpeg: photoJpeg,
        capturedAt: capturedAt,
        selfRating: selfRating,
        sessionRevision: sessionRevision,
        assessment: assessment ?? this.assessment,
        learnerConfirmed: learnerConfirmed ?? this.learnerConfirmed,
      );

  factory CheckpointRecord.fromMap(String id, Map<String, dynamic> m) =>
      CheckpointRecord(
        id: id,
        sessionId: m['sessionId'] as String,
        stepId: m['stepId'] as String,
        checkpointDefId: m['checkpointDefId'] as String,
        photoJpeg: readBytes(m['photoJpeg']),
        capturedAt: readTime(m['capturedAt']),
        selfRating: readEnum(
          SelfRating.values,
          m['selfRating'],
          SelfRating.notSure,
        ),
        sessionRevision: m['sessionRevision'] as int? ?? 0,
        assessment: m['assessment'] == null
            ? null
            : Assessment.fromMap(
                Map<String, dynamic>.from(m['assessment'] as Map),
              ),
        learnerConfirmed: m['learnerConfirmed'] as bool? ?? false,
      );

  Map<String, dynamic> toMap() => {
    'sessionId': sessionId,
    'stepId': stepId,
    'checkpointDefId': checkpointDefId,
    'photoJpeg': photoJpeg,
    'capturedAt': capturedAt,
    'selfRating': selfRating.name,
    'sessionRevision': sessionRevision,
    'assessment': assessment?.toMap(),
    'learnerConfirmed': learnerConfirmed,
  };
}

// ---------------------------------------------------------------- help requests

/// Lifecycle: see core/request_machine.dart for the allowed transitions.
enum RequestStatus {
  /// Written by the learner (works offline); triage + routing not done yet.
  submitted,

  /// No available instructor covers the needed skill. Stays visible.
  needsOwner,

  /// Rules picked an instructor; a person must accept (human review).
  suggested,
  accepted,
  answered,
  resolved,
  cancelled,
}

extension RequestStatusX on RequestStatus {
  bool get isTerminal =>
      this == RequestStatus.resolved || this == RequestStatus.cancelled;

  /// Board lane for this status.
  String get lane => switch (this) {
    RequestStatus.submitted || RequestStatus.needsOwner => 'Needs owner',
    RequestStatus.suggested || RequestStatus.accepted => 'With instructor',
    RequestStatus.answered => 'Answered',
    RequestStatus.resolved || RequestStatus.cancelled => 'Resolved',
  };
}

enum RequestCategory {
  technique,
  substitution,
  safetyAllergen,
  equipment,
  other,
}

extension RequestCategoryX on RequestCategory {
  /// Instructor skill that can own this category.
  String get neededSkill => switch (this) {
    RequestCategory.technique || RequestCategory.other => Skills.technique,
    RequestCategory.substitution => Skills.substitutions,
    RequestCategory.safetyAllergen => Skills.allergens,
    RequestCategory.equipment => Skills.equipment,
  };
}

abstract final class Skills {
  static const technique = 'technique';
  static const substitutions = 'substitutions';
  static const allergens = 'allergens';
  static const equipment = 'equipment';
  static const all = [technique, substitutions, allergens, equipment];
}

enum HandoffTrigger { substitution, uncertainTwice, safety, manual }

enum Urgency { low, normal, high }

enum NotifyState { pending, sent, failed, skipped }

class NotifyRecord {
  const NotifyRecord({required this.state, this.at, this.error, this.channel});

  final NotifyState state;
  final DateTime? at;
  final String? error;
  final String? channel;

  factory NotifyRecord.fromMap(Map<String, dynamic> m) => NotifyRecord(
    state: readEnum(NotifyState.values, m['state'], NotifyState.pending),
    at: readTimeOrNull(m['at']),
    error: m['error'] as String?,
    channel: m['channel'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'state': state.name,
    'at': at,
    'error': error,
    'channel': channel,
  };
}

class HistoryEntry {
  const HistoryEntry({
    required this.status,
    required this.at,
    required this.by,
    this.note,
  });

  final RequestStatus status;
  final DateTime at;

  /// uid, 'system', or 'rules'.
  final String by;
  final String? note;

  factory HistoryEntry.fromMap(Map<String, dynamic> m) => HistoryEntry(
    status: readEnum(
      RequestStatus.values,
      m['status'],
      RequestStatus.submitted,
    ),
    at: readTime(m['at']),
    by: m['by'] as String? ?? 'system',
    note: m['note'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'status': status.name,
    'at': at,
    'by': by,
    'note': note,
  };
}

class HelpRequest {
  const HelpRequest({
    required this.id,
    required this.learnerId,
    required this.sessionId,
    required this.recipeId,
    required this.stepId,
    required this.question,
    required this.trigger,
    required this.status,
    required this.nextStep,
    required this.history,
    required this.createdAt,
    required this.updatedAt,
    this.learnerName = 'Learner',
    this.language = 'en',
    this.category,
    this.urgency = Urgency.normal,
    this.summaryForInstructor,
    this.aiUncertainty,
    this.englishQuestion,
    this.details = const [],
    this.thumbnails = const [],
    this.checkpointIds = const [],
    this.substitutionIngredientId,
    this.proposedSubstitute,
    this.suggestedOwnerId,
    this.suggestedReason,
    this.ownerId,
    this.declinedBy = const [],
    this.answerText,
    this.answeredBy,
    this.answeredAt,
    this.approvedAsReviewed = false,
    this.notify = const {},
    this.plusOneLearners = const [],
  });

  /// Client-generated UUID, created when the help sheet opens and reused on
  /// retries, so a double tap writes one document.
  final String id;
  final String learnerId;
  final String learnerName;
  final String sessionId;
  final String recipeId;
  final String stepId;
  final String question;
  final String language;
  final HandoffTrigger trigger;
  final RequestStatus status;

  /// What the learner sees as their next step for the current status.
  final String nextStep;
  final List<HistoryEntry> history;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Triage (Gemini) output. Null until triaged.
  final RequestCategory? category;
  final Urgency urgency;
  final String? summaryForInstructor;

  /// What the AI could not judge, shown at the top of the instructor card.
  final String? aiUncertainty;
  final String? englishQuestion;

  /// Extra details the learner added while waiting.
  final List<String> details;

  /// Up to 2 small JPEGs copied from checkpoints at submit time, so
  /// instructors never need read access to the learner's session.
  final List<Uint8List> thumbnails;
  final List<String> checkpointIds;

  /// For substitution requests: which ingredient, and what the learner proposed.
  final String? substitutionIngredientId;
  final String? proposedSubstitute;

  // Routing and ownership.
  final String? suggestedOwnerId;
  final String? suggestedReason;
  final String? ownerId;
  final List<String> declinedBy;

  // Answer and knowledge loop.
  final String? answerText;
  final String? answeredBy;
  final DateTime? answeredAt;
  final bool approvedAsReviewed;

  /// Keyed by notification kind: 'instructorRouted', 'learnerAccepted',
  /// 'learnerAnswered', 'learnerResolved'. Written by Cloud Functions only.
  final Map<String, NotifyRecord> notify;

  /// Duplicate detection: other learners who +1'd this open request.
  final List<String> plusOneLearners;

  String? get neededSkill => category?.neededSkill;

  HelpRequest copyWith({
    String? question,
    RequestStatus? status,
    String? nextStep,
    List<HistoryEntry>? history,
    DateTime? updatedAt,
    Object? category = _unset,
    Urgency? urgency,
    Object? summaryForInstructor = _unset,
    Object? aiUncertainty = _unset,
    Object? englishQuestion = _unset,
    List<String>? details,
    List<Uint8List>? thumbnails,
    Object? suggestedOwnerId = _unset,
    Object? suggestedReason = _unset,
    Object? ownerId = _unset,
    List<String>? declinedBy,
    Object? answerText = _unset,
    Object? answeredBy = _unset,
    Object? answeredAt = _unset,
    bool? approvedAsReviewed,
    Map<String, NotifyRecord>? notify,
    List<String>? plusOneLearners,
  }) => HelpRequest(
    id: id,
    learnerId: learnerId,
    learnerName: learnerName,
    sessionId: sessionId,
    recipeId: recipeId,
    stepId: stepId,
    question: question ?? this.question,
    language: language,
    trigger: trigger,
    status: status ?? this.status,
    nextStep: nextStep ?? this.nextStep,
    history: history ?? this.history,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    category: identical(category, _unset)
        ? this.category
        : category as RequestCategory?,
    urgency: urgency ?? this.urgency,
    summaryForInstructor: identical(summaryForInstructor, _unset)
        ? this.summaryForInstructor
        : summaryForInstructor as String?,
    aiUncertainty: identical(aiUncertainty, _unset)
        ? this.aiUncertainty
        : aiUncertainty as String?,
    englishQuestion: identical(englishQuestion, _unset)
        ? this.englishQuestion
        : englishQuestion as String?,
    details: details ?? this.details,
    thumbnails: thumbnails ?? this.thumbnails,
    checkpointIds: checkpointIds,
    substitutionIngredientId: substitutionIngredientId,
    proposedSubstitute: proposedSubstitute,
    suggestedOwnerId: identical(suggestedOwnerId, _unset)
        ? this.suggestedOwnerId
        : suggestedOwnerId as String?,
    suggestedReason: identical(suggestedReason, _unset)
        ? this.suggestedReason
        : suggestedReason as String?,
    ownerId: identical(ownerId, _unset) ? this.ownerId : ownerId as String?,
    declinedBy: declinedBy ?? this.declinedBy,
    answerText: identical(answerText, _unset)
        ? this.answerText
        : answerText as String?,
    answeredBy: identical(answeredBy, _unset)
        ? this.answeredBy
        : answeredBy as String?,
    answeredAt: identical(answeredAt, _unset)
        ? this.answeredAt
        : answeredAt as DateTime?,
    approvedAsReviewed: approvedAsReviewed ?? this.approvedAsReviewed,
    notify: notify ?? this.notify,
    plusOneLearners: plusOneLearners ?? this.plusOneLearners,
  );

  factory HelpRequest.fromMap(String id, Map<String, dynamic> m) => HelpRequest(
    id: id,
    learnerId: m['learnerId'] as String,
    learnerName: m['learnerName'] as String? ?? 'Learner',
    sessionId: m['sessionId'] as String,
    recipeId: m['recipeId'] as String,
    stepId: m['stepId'] as String,
    question: m['question'] as String,
    language: m['language'] as String? ?? 'en',
    trigger: readEnum(
      HandoffTrigger.values,
      m['trigger'],
      HandoffTrigger.manual,
    ),
    status: readEnum(
      RequestStatus.values,
      m['status'],
      RequestStatus.submitted,
    ),
    nextStep: m['nextStep'] as String? ?? '',
    history: [
      for (final h in (m['history'] as List? ?? const []))
        HistoryEntry.fromMap(Map<String, dynamic>.from(h as Map)),
    ],
    createdAt: readTime(m['createdAt']),
    updatedAt: readTime(m['updatedAt']),
    category: m['category'] == null
        ? null
        : readEnum(
            RequestCategory.values,
            m['category'],
            RequestCategory.other,
          ),
    urgency: readEnum(Urgency.values, m['urgency'], Urgency.normal),
    summaryForInstructor: m['summaryForInstructor'] as String?,
    aiUncertainty: m['aiUncertainty'] as String?,
    englishQuestion: m['englishQuestion'] as String?,
    details: readStrings(m['details']),
    thumbnails: [
      for (final t in (m['thumbnails'] as List? ?? const [])) readBytes(t),
    ],
    checkpointIds: readStrings(m['checkpointIds']),
    substitutionIngredientId: m['substitutionIngredientId'] as String?,
    proposedSubstitute: m['proposedSubstitute'] as String?,
    suggestedOwnerId: m['suggestedOwnerId'] as String?,
    suggestedReason: m['suggestedReason'] as String?,
    ownerId: m['ownerId'] as String?,
    declinedBy: readStrings(m['declinedBy']),
    answerText: m['answerText'] as String?,
    answeredBy: m['answeredBy'] as String?,
    answeredAt: readTimeOrNull(m['answeredAt']),
    approvedAsReviewed: m['approvedAsReviewed'] as bool? ?? false,
    notify: {
      for (final e in Map<String, dynamic>.from(
        m['notify'] as Map? ?? {},
      ).entries)
        e.key: NotifyRecord.fromMap(Map<String, dynamic>.from(e.value as Map)),
    },
    plusOneLearners: readStrings(m['plusOneLearners']),
  );

  /// Client-writable fields. `notify` is written by Cloud Functions only.
  Map<String, dynamic> toMap() => {
    'learnerId': learnerId,
    'learnerName': learnerName,
    'sessionId': sessionId,
    'recipeId': recipeId,
    'stepId': stepId,
    'question': question,
    'language': language,
    'trigger': trigger.name,
    'status': status.name,
    'nextStep': nextStep,
    'history': [for (final h in history) h.toMap()],
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'category': category?.name,
    'neededSkill': neededSkill,
    'urgency': urgency.name,
    'summaryForInstructor': summaryForInstructor,
    'aiUncertainty': aiUncertainty,
    'englishQuestion': englishQuestion,
    'details': details,
    'thumbnails': thumbnails,
    'checkpointIds': checkpointIds,
    'substitutionIngredientId': substitutionIngredientId,
    'proposedSubstitute': proposedSubstitute,
    'suggestedOwnerId': suggestedOwnerId,
    'suggestedReason': suggestedReason,
    'ownerId': ownerId,
    'declinedBy': declinedBy,
    'answerText': answerText,
    'answeredBy': answeredBy,
    'answeredAt': answeredAt,
    'approvedAsReviewed': approvedAsReviewed,
    'plusOneLearners': plusOneLearners,
  };
}

// ---------------------------------------------------------------- instructors

enum InstructorRole { instructor, coordinator }

class Instructor {
  const Instructor({
    required this.id,
    required this.displayName,
    required this.skills,
    required this.available,
    this.role = InstructorRole.instructor,
    this.isDemoData = true,
    this.lastAssignedAt,
  });

  /// Firebase Auth uid for instructors who sign in; any id for seeded data.
  final String id;
  final String displayName;
  final List<String> skills;
  final bool available;
  final InstructorRole role;
  final bool isDemoData;
  final DateTime? lastAssignedAt;

  bool covers(String skill) => skills.contains(skill);

  Instructor copyWith({bool? available, DateTime? lastAssignedAt}) =>
      Instructor(
        id: id,
        displayName: displayName,
        skills: skills,
        available: available ?? this.available,
        role: role,
        isDemoData: isDemoData,
        lastAssignedAt: lastAssignedAt ?? this.lastAssignedAt,
      );

  factory Instructor.fromMap(String id, Map<String, dynamic> m) => Instructor(
    id: id,
    displayName: m['displayName'] as String,
    skills: readStrings(m['skills']),
    available: m['available'] as bool? ?? false,
    role: readEnum(InstructorRole.values, m['role'], InstructorRole.instructor),
    isDemoData: m['isDemoData'] as bool? ?? true,
    lastAssignedAt: readTimeOrNull(m['lastAssignedAt']),
  );

  Map<String, dynamic> toMap() => {
    'displayName': displayName,
    'skills': skills,
    'available': available,
    'role': role.name,
    'isDemoData': isDemoData,
    'lastAssignedAt': lastAssignedAt,
  };
}
