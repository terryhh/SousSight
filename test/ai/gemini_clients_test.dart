import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/ai_config.dart';
import 'package:soussight/ai/gemini_clients.dart';
import 'package:soussight/ai/json_generation.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/core/services.dart';
import 'package:soussight/core/triggers.dart';

void main() {
  final recipe = Recipe.fromMap(
    jsonDecode(File('assets/recipes/chickpea_wrap_v1.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  AssessmentInput assessmentInput({
    bool previous = false,
    List<String> facts = const [],
  }) => AssessmentInput(
    recipe: recipe,
    step: recipe.step('mash'),
    checkpoint: recipe.checkpoints.first,
    targetJpeg: Uint8List.fromList([1]),
    currentJpeg: Uint8List.fromList([2]),
    previousJpeg: previous ? Uint8List.fromList([3]) : null,
    confirmedFacts: facts,
  );
  Map<String, dynamic> assessmentJson() => {
    'outcome': 'adjust',
    'observations': ['Whole chickpeas remain on the left.'],
    'cue': 'Look for coarse broken pieces with few whole chickpeas.',
    'suggestedAction': 'Mash more.',
    'adjustmentId': 'mash_more',
    'confidence': 'high',
    'outOfScope': false,
    'outOfScopeReason': null,
  };
  TriageInput triageInput({
    String question = 'No lemon: can I use vinegar?',
    HandoffTrigger trigger = HandoffTrigger.substitution,
    String language = 'en',
  }) => TriageInput(
    question: question,
    recipe: recipe,
    step: recipe.step('mash'),
    trigger: trigger,
    language: language,
  );
  Map<String, dynamic> triageJson() => {
    'category': 'substitution',
    'urgency': 'normal',
    'summaryForInstructor': 'At the mashing step, the learner lacks lemon and asks whether vinegar works.',
    'aiUncertainty': 'This swap has not been reviewed.',
    'englishQuestion': null,
    'clarifyingQuestion': 'Which vinegar do you have?',
    'language': 'en',
  };

  group('structured visual assessment', () {
    test(
      'labels image roles and uses the current step allowlist in the schema',
      () async {
        late JsonGenerationRequest sent;
        final client = GeminiAssessmentClient(
          generate: (request) async {
            sent = request;
            return jsonEncode(assessmentJson());
          },
        );
        final result = await client.assess(assessmentInput(previous: true));
        expect(sent.model, AiConfig.assessmentModel);
        expect(sent.config.responseMimeType, 'application/json');
        expect(
          sent.config.responseSchema!.properties!['adjustmentId']!.enumValues,
          ['mash_more', 'mash_side', 'fine_as_is'],
        );
        final parts = sent.contents.single.parts;
        expect((parts[1] as TextPart).text, startsWith('IMAGE 1 TARGET'));
        expect((parts[2] as InlineDataPart).bytes, [1]);
        expect((parts[3] as TextPart).text, startsWith('IMAGE 2 CURRENT'));
        expect((parts[4] as InlineDataPart).bytes, [2]);
        expect((parts[5] as TextPart).text, startsWith('IMAGE 3 PREVIOUS'));
        expect((parts[6] as InlineDataPart).bytes, [3]);
        expect(result.outcome, AssessmentOutcome.adjust);
        expect(result.suggestedAction, recipe.adjustmentLabels['mash_more']);
      },
    );

    test('does not include a previous image unless one is supplied', () async {
      final client = GeminiAssessmentClient(
        generate: (request) async {
          expect(request.contents.single.parts.length, 5);
          return jsonEncode(assessmentJson());
        },
      );
      await client.assess(assessmentInput());
    });

    test(
      'unknown adjustment cannot smuggle an unreviewed action into the UI',
      () async {
        final data = assessmentJson()
          ..['adjustmentId'] = 'add_unknown_ingredient'
          ..['suggestedAction'] = 'Add an ingredient not in the recipe.';
        final result = await GeminiAssessmentClient(
          generate: (_) async => jsonEncode(data),
        ).assess(assessmentInput());
        expect(result.outcome, AssessmentOutcome.uncertain);
        expect(result.adjustmentId, isNull);
        expect(
          result.suggestedAction,
          'Try another view or ask an instructor.',
        );
      },
    );

    test(
      'low-confidence match and match without observations become uncertain',
      () async {
        for (final change in [
          {'confidence': 'low'},
          {'observations': <String>[]},
        ]) {
          final data = assessmentJson()..['outcome'] = 'matchesTarget';
          data.addAll(change);
          final result = await GeminiAssessmentClient(
            generate: (_) async => jsonEncode(data),
          ).assess(assessmentInput());
          expect(result.outcome, AssessmentOutcome.uncertain);
        }
      },
    );

    test(
      'out-of-scope result replaces model assurances with the fixed reply',
      () async {
        final data = assessmentJson()
          ..['outOfScope'] = true
          ..['outcome'] = 'matchesTarget'
          ..['observations'] = ['Safe to eat.']
          ..['suggestedAction'] = 'Serve immediately.';
        final result = await GeminiAssessmentClient(
          generate: (_) async => jsonEncode(data),
        ).assess(assessmentInput());
        expect(result.outcome, AssessmentOutcome.uncertain);
        expect(result.outOfScope, isTrue);
        expect(result.suggestedAction, safetyReply);
        expect(result.observations, isEmpty);
      },
    );

    test('confirmed safety concern bypasses the model', () async {
      var calls = 0;
      final result = await GeminiAssessmentClient(
        generate: (_) async {
          calls++;
          return jsonEncode(assessmentJson());
        },
      ).assess(assessmentInput(facts: ['Roommate has a sesame allergy.']));
      expect(calls, 0);
      expect(result.outOfScope, isTrue);
    });

    test(
      'malformed output, unknown enums and missing fields fail closed',
      () async {
        final invalid = [
          null,
          '```json\n{}\n```',
          '[]',
          jsonEncode(assessmentJson()..['outcome'] = 'looksGood'),
          jsonEncode(assessmentJson()..remove('confidence')),
          jsonEncode(assessmentJson()..['outOfScope'] = 'false'),
          jsonEncode(assessmentJson()..['observations'] = [1]),
          jsonEncode(assessmentJson()..['observations'] = ['a', 'b', 'c', 'd']),
          'a' * 16001,
        ];
        for (final response in invalid) {
          final result = await GeminiAssessmentClient(
            generate: (_) async => response,
          ).assess(assessmentInput());
          expect(result.outcome, AssessmentOutcome.uncertain);
          expect(result.confidence, Confidence.low);
          expect(result.observations, isEmpty);
        }
      },
    );

    test(
      'provider error and timeout leave a retryable uncertain result',
      () async {
        final generators = <JsonGenerator>[
          (_) async => throw StateError('provider failed'),
          (_) => Completer<String?>().future,
        ];
        for (final generate in generators) {
          final result = await GeminiAssessmentClient(
            generate: generate,
            timeout: const Duration(milliseconds: 1),
          ).assess(assessmentInput());
          expect(result.outcome, AssessmentOutcome.uncertain);
          expect(result.suggestedAction, contains('Try again'));
        }
      },
    );
  });

  group('instructor triage', () {
    test(
      'preserves structured context and forces substitution trigger category',
      () async {
        final client = GeminiTriageClient(
          generate: (request) async {
            expect(request.model, AiConfig.triageModel);
            expect(request.config.responseMimeType, 'application/json');
            final payload = jsonDecode(
              (request.contents.single.parts.single as TextPart).text,
            );
            expect(payload['trigger'], 'substitution');
            expect(payload['question'], 'No lemon: can I use vinegar?');
            return jsonEncode(triageJson()..['category'] = 'technique');
          },
        );
        final result = await client.triage(triageInput());
        expect(result.category, RequestCategory.substitution);
        expect(result.clarifyingQuestion, 'Which vinegar do you have?');
      },
    );

    test(
      'keyword and explicit safety triggers bypass model and set high urgency',
      () async {
        var calls = 0;
        final client = GeminiTriageClient(
          generate: (_) async {
            calls++;
            return jsonEncode(triageJson());
          },
        );
        for (final input in [
          triageInput(question: 'My roommate has a sesame allergy.'),
          triageInput(
            question: '¿Puedo comer esto?',
            trigger: HandoffTrigger.safety,
            language: 'es',
          ),
        ]) {
          final result = await client.triage(input);
          expect(result.category, RequestCategory.safetyAllergen);
          expect(result.urgency, Urgency.high);
          expect(result.language, input.language);
        }
        expect(calls, 0);
      },
    );

    test('model-detected safety takes priority over substitution', () async {
      final result = await GeminiTriageClient(
        generate: (_) async => jsonEncode(
          triageJson()
            ..['category'] = 'safetyAllergen'
            ..['urgency'] = 'low',
        ),
      ).triage(triageInput());
      expect(result.category, RequestCategory.safetyAllergen);
      expect(result.urgency, Urgency.high);
    });

    test('enforces summary length and retains translation', () async {
      final data = triageJson()
        ..['summaryForInstructor'] = List.filled(80, 'word').join(' ')
        ..['englishQuestion'] = 'Can I use vinegar?'
        ..['language'] = 'es';
      final result = await GeminiTriageClient(
        generate: (_) async => jsonEncode(data),
      ).triage(triageInput(question: '¿Puedo usar vinagre?', language: 'es'));
      expect(result.summaryForInstructor.split(' ').length, 60);
      expect(result.englishQuestion, 'Can I use vinegar?');
      expect(result.language, 'es');
    });

    test(
      'invalid response and provider failure keep a routable original question',
      () async {
        final generators = <JsonGenerator>[
          (_) async => jsonEncode(triageJson()..['category'] = 'unknown'),
          (_) async => jsonEncode(triageJson()..remove('summaryForInstructor')),
          (_) async => throw StateError('offline'),
          (_) => Completer<String?>().future,
        ];
        for (final generate in generators) {
          final result = await GeminiTriageClient(
            generate: generate,
            timeout: const Duration(milliseconds: 1),
          ).triage(triageInput());
          expect(result.category, RequestCategory.substitution);
          expect(
            result.summaryForInstructor,
            contains('No lemon: can I use vinegar?'),
          );
          expect(result.aiUncertainty, contains('unavailable'));
        }
      },
    );
  });
}
