import 'package:firebase_ai/firebase_ai.dart';

import '../core/models.dart';

Schema assessmentSchema(CheckpointDef checkpoint) => Schema.object(
  properties: {
    'outcome': Schema.enumString(
      enumValues: AssessmentOutcome.values.map((e) => e.name).toList(),
    ),
    'observations': Schema.array(
      items: Schema.string(description: 'One visible fact, not an inference.'),
      maxItems: 3,
    ),
    'cue': Schema.string(description: 'The visible cue to compare next.'),
    'suggestedAction': Schema.string(
      description:
          'Only the reviewed adjustment selected by adjustmentId, '
          'or a request for a clearer view or instructor help.',
    ),
    'adjustmentId': checkpoint.allowedAdjustments.isEmpty
        ? Schema.string(nullable: true, description: 'Must be null.')
        : Schema.enumString(
            enumValues: checkpoint.allowedAdjustments,
            nullable: true,
          ),
    'confidence': Schema.enumString(
      enumValues: Confidence.values.map((e) => e.name).toList(),
    ),
    'outOfScope': Schema.boolean(),
    'outOfScopeReason': Schema.string(nullable: true),
  },
);

Schema triageSchema() => Schema.object(
  properties: {
    'category': Schema.enumString(
      enumValues: RequestCategory.values.map((e) => e.name).toList(),
    ),
    'urgency': Schema.enumString(
      enumValues: Urgency.values.map((e) => e.name).toList(),
    ),
    'summaryForInstructor': Schema.string(
      description: 'At most 60 words: question, step, attempts, uncertainty.',
    ),
    'aiUncertainty': Schema.string(nullable: true),
    'englishQuestion': Schema.string(nullable: true),
    'clarifyingQuestion': Schema.string(nullable: true),
    'language': Schema.string(description: 'Language code, such as en or es.'),
  },
);
