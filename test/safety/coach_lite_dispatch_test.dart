// SS-131: the safety fallback is reached through the production
// dispatcher's rejection path. Fakes only.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/safety/cook_safety.dart';

class _Privacy implements PrivacySettings {
  @override
  bool localOnly(String feature) => false;
}

class _Consent implements ConsentGate {
  @override
  Future<ConsentGrant?> request(ConsentAsk ask) async => ConsentGrant(ask);
}

String _answer(String body) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['tip'],
    },
    {'id': 'tip', 'component': 'stepCue', 'title': 'Tip', 'body': body},
  ],
});

const _step = RecipeStep(
  id: 'sear',
  title: 'Sear',
  instruction: 'Sear the chicken.',
  cue: 'Golden on both sides.',
);

void main() {
  Future<CoachLiteAnswer> ask(List<String> answers) {
    final inference = FakeHybridInference();
    for (final a in answers) {
      inference.enqueueText(a);
    }
    final dispatcher = DefaultHybridDispatcher(
      inference: inference,
      privacy: _Privacy(),
      cloudRoutes: CloudRoutes.parse('hybridFallback'),
      consent: _Consent(),
      ledger: InferenceLedger(sessionId: 's'),
    );
    return CoachLite(
      dispatcher: dispatcher,
      privacy: _Privacy(),
      cloudRoutes: const CloudRoutes({}),
      isOnline: () => true,
    ).ask(
      question: 'How do I flip it?',
      step: _step,
      recipe: const Recipe(
        id: 'r',
        version: 1,
        title: 'Chicken',
        summary: '',
        ingredients: [],
        equipment: [],
        steps: [_step],
        checkpoints: [],
        reviewedSubstitutions: [],
        adjustmentLabels: {},
      ),
      sessionId: 's',
      epoch: 1,
    );
  }

  test(
    'a gated answer shows the safety fallback, not a generic failure',
    () async {
      final answer = await ask([
        _answer('The chicken is done.'),
        _answer('The chicken is done.'),
      ]);
      final shown = jsonEncode(answer.components);
      expect(shown, contains(cookSafetyFallbackNote));
      expect(shown, contains('Golden on both sides.'));
      expect(shown, isNot(contains('The chicken is done.')));
      expect(answer.legs, isNotEmpty);
    },
  );

  test('a plain answer still comes through', () async {
    final answer = await ask([_answer('Use tongs and flip it once.')]);
    expect(answer.status, CoachLiteStatus.answered);
  });
}
