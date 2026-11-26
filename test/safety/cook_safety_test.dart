// The shared, conservative cook-facing safety gate (SS-131). Pure Dart.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/coach_lite/tts.dart';
import 'package:soussight/safety/cook_safety.dart';

/// Codex's probes from #240 and #244, and other claims: all blocked.
const _blocked = [
  'The camera shows 165F at the center',
  'The photo shows the chicken is 165F inside',
  'No peanuts in this dish',
  'Made without peanuts',
  'Serve the chicken as soon as the center is white. Zero peanuts.',
  'Sesame-free',
  "It's safe to eat.",
  'The chicken is done when the juices run clear.',
  'The milk is fresh.',
  'The chicken is cooked through.',
  'It reached 74 C.',
  'Bake at 350°F.',
  'The thermometer reads 165.',
  'Cook until it is no longer pink.',
  'The inside is opaque.',
  'This is free of allergens.',
  'It contains no gluten.',
  'You can eat it now.',
  'Throw out spoiled leftovers.',
  // Codex's probes on #277.
  'The camera shows the chicken is 165 Fahrenheit inside',
  'There are no almonds in this dish',
  'This dish is vegan',
  "It doesn't contain soy.",
  'Keep it at 74 Celsius.',
  'Kosher and halal.',
];

/// Visual-only coaching stays allowed.
const _allowed = [
  'Stir until golden.',
  'Spread it in a thin, even layer.',
  'Look for bubbling at the edges and crisp edges.',
  'Fold from the bottom up until evenly mixed.',
  'Add 2 cups of rice.',
  'Check the thickest part with a thermometer.',
];

/// Harmless sentences blocked on purpose: over-blocking is the accepted
/// cost.
const _overBlocked = [
  'No liquid pools in the can.',
  'Stir until it is done.',
  'Have your peanut butter ready.',
  "The camera can't measure temperature.",
  'Use dairy-free milk if you need to.',
];

void main() {
  group('blocked', () {
    for (final t in _blocked) {
      test(t, () {
        expect(touchesFoodSafety(t), isTrue);
        expect(coachLiteCertifies(t), isTrue);
      });
    }
  });

  group('visual-only coaching passes', () {
    for (final t in _allowed) {
      test(t, () => expect(touchesFoodSafety(t), isFalse));
    }
  });

  group('over-blocked on purpose', () {
    for (final t in _overBlocked) {
      test(t, () => expect(touchesFoodSafety(t), isTrue));
    }
  });

  test('payload helpers read cook-facing strings only', () {
    final payload = {
      'components': [
        {
          'id': 'safe_to_eat',
          'component': 'stepCue',
          'children': ['is done'],
          'title': 'Tip',
          'body': 'Stir gently.',
        },
      ],
      'timerSuggestion': {'label': 'Simmer', 'seconds': 60},
    };
    expect(cookFacingStrings(payload), ['Tip', 'Stir gently.', 'Simmer']);
    expect(payloadTouchesFoodSafety(payload), isFalse);
    expect(
      payloadTouchesFoodSafety({
        'timerSuggestion': {'label': 'Chicken is safe to eat'},
      }),
      isTrue,
    );
  });

  test("the recipe's own reviewed text may be quoted verbatim", () {
    final panel = {'body': 'Have your peanut butter ready.'};
    expect(payloadTouchesFoodSafety(panel), isTrue);
    expect(
      payloadTouchesFoodSafety(
        panel,
        reviewed: {'Have your peanut butter ready.'},
      ),
      isFalse,
    );
    expect(
      payloadTouchesFoodSafety(
        {'body': 'Have your peanut butter ready. It is safe.'},
        reviewed: {'Have your peanut butter ready.'},
      ),
      isTrue,
    );
  });

  group('Coach Lite answers', () {
    String answer(String body, {Object? timer}) => jsonEncode({
      'components': [
        {
          'id': 'root',
          'component': 'CookingColumn',
          'children': ['tip'],
        },
        {'id': 'tip', 'component': 'stepCue', 'title': 'Tip', 'body': body},
      ],
      'timerSuggestion': ?timer,
    });

    test('each probe is rejected by the answer parser', () {
      for (final t in _blocked) {
        expect(validateCoachLiteResponse(answer(t)), isNotNull, reason: t);
      }
    });

    test('a gated timer label rejects the answer', () {
      expect(
        validateCoachLiteResponse(
          answer('Stir.', timer: {'label': 'Until safe to eat', 'seconds': 90}),
        ),
        isNotNull,
      );
      expect(
        parseCoachLiteResponse(
          answer('Stir.', timer: {'label': 'Simmer', 'seconds': 90}),
        ).timer?.label,
        'Simmer',
      );
    });

    test('an answer with no content card is malformed', () {
      final columnsOnly = jsonEncode({
        'components': [
          {
            'id': 'root',
            'component': 'CookingColumn',
            'children': ['col'],
          },
          {'id': 'col', 'component': 'CookingColumn', 'children': <String>[]},
        ],
      });
      expect(validateCoachLiteResponse(columnsOnly), isNotNull);
      final nested = jsonEncode({
        'components': [
          {
            'id': 'root',
            'component': 'CookingColumn',
            'children': ['col'],
          },
          {
            'id': 'col',
            'component': 'CookingColumn',
            'children': ['tip'],
          },
          {'id': 'tip', 'component': 'stepCue', 'title': 'T', 'body': 'Stir.'},
        ],
      });
      expect(validateCoachLiteResponse(nested), isNull);
    });

    test('read-aloud gates model text in any card; app notices are read', () {
      final spoken = coachLiteSpokenTextFor([
        {
          'id': 'root',
          'component': 'CookingColumn',
          'children': ['app_step', 'app_safety'],
        },
        {
          'id': 'app_step',
          'component': 'stepCue',
          'title': 'Sear',
          'body': 'The chicken is safe to eat. Flip it once.',
        },
        {
          'id': 'app_safety',
          'component': 'stepCue',
          'title': 'Check',
          'body': coachLiteSafetyNotice,
        },
      ]);
      expect(spoken, isNot(contains('safe to eat')));
      expect(spoken, contains('Flip it once.'));
      expect(spoken, contains(coachLiteSafetyNotice));
    });

    test('a fragment of an app notice cannot cut away its negation', () {
      final spoken = coachLiteSpokenTextFor([
        {
          'id': 'root',
          'component': 'CookingColumn',
          'children': ['tip'],
        },
        {
          'id': 'tip',
          'component': 'stepCue',
          'title': 'This dish',
          'body': 'free of an allergen.',
        },
      ]);
      expect(spoken, isNot(contains('free of')));
    });
  });
}

String coachLiteSpokenTextFor(List<Map<String, dynamic>> components) =>
    coachLiteSpokenText(
      CoachLiteAnswer(
        stamp: const CoachLiteStamp(
          sessionId: 's',
          epoch: 0,
          stepId: 'x',
          sequence: 1,
        ),
        status: CoachLiteStatus.invalid,
        kind: CoachLiteQuestionKind.stepHelp,
        components: components,
      ),
    );
