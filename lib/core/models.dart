// Shared domain models. This file is the contract between the cook app, the
// data layer, and Cloud Functions.
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
