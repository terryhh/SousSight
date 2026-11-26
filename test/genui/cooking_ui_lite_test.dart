import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/genui/cooking_ui.dart';

Map<String, dynamic> lite(List<Map<String, dynamic>> leaves) => {
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': [for (final c in leaves) c['id']],
    },
    ...leaves,
  ],
};

void main() {
  test('accepts display components with next_step and ask_cook', () {
    final payload = lite([
      {
        'id': 'tip',
        'component': 'stepCue',
        'title': 'Keep stirring',
        'body': 'Stir every minute so the bottom does not catch.',
        'action': 'next_step',
        'actionLabel': 'Next step',
      },
      {
        'id': 'ask',
        'component': 'stepCue',
        'title': 'Quick question',
        'body': 'Is your pan non-stick?',
        'action': 'ask_cook',
      },
      {
        'id': 'compare',
        'component': 'comparison',
        'title': 'Texture',
        'observed': 'You said it is still runny.',
        'target': 'Thick enough to coat a spoon.',
        'cue': 'Draw a line on the spoon; it should hold.',
      },
    ]);
    expect(validateLiteCookingUi(payload), hasLength(4));
  });

  test('rejects components and actions outside the lite allowlist', () {
    final rejected = [
      {
        'id': 'w',
        'component': 'watchStatus',
        'title': 'W',
        'body': 'B',
        'status': 'watching',
      },
      {'id': 't', 'component': 'cookingTimer', 'timerId': 't1', 'label': 'L'},
      {'id': 'd', 'component': 'dinnerReady', 'title': 'D', 'message': 'M'},
      {
        'id': 'i',
        'component': 'ingredientChecklist',
        'title': 'I',
        'items': [
          {'id': 'a', 'label': 'A'},
        ],
      },
      {
        'id': 'q',
        'component': 'cookQuestion',
        'title': 'Q',
        'question': 'Q?',
        'options': [
          {'id': 'a', 'label': 'A'},
          {'id': 'b', 'label': 'B'},
        ],
      },
      {
        'id': 's',
        'component': 'stepCue',
        'title': 'S',
        'body': 'B',
        'action': 'start_watch',
      },
      {
        'id': 's',
        'component': 'stepCue',
        'title': 'S',
        'body': 'B',
        'action': 'check_now',
      },
    ];
    for (final component in rejected) {
      final payload = lite([component]);
      // Each is valid for the full catalog, so only the lite list rejects it.
      expect(() => validateCookingUi(payload), returnsNormally);
      expect(
        () => validateLiteCookingUi(payload),
        throwsFormatException,
        reason: '$component',
      );
    }
  });

  test('still enforces the full catalog rules after the allowlist', () {
    expect(
      () => validateLiteCookingUi({
        'components': [
          {'id': 'tip', 'component': 'stepCue', 'title': 'T', 'body': 'B'},
        ],
      }),
      throwsFormatException, // no CookingColumn root
    );
    expect(
      () => validateLiteCookingUi(
        lite([
          {
            'id': 'tip',
            'component': 'stepCue',
            'title': 'T',
            'body': 'B',
            'extra': 1,
          },
        ]),
      ),
      throwsFormatException,
    );
    expect(
      () => validateLiteCookingUi({'components': 'nope'}),
      throwsFormatException,
    );
    expect(
      () => validateLiteCookingUi(
        lite([
          for (var i = 0; i < liteMaxComponents; i++)
            {'id': 'c$i', 'component': 'stepCue', 'title': 'T', 'body': 'B'},
        ]),
      ),
      throwsFormatException,
    );
  });

  test('the full validator keeps accepting the whole catalog', () {
    expect(
      validateCookingUi(
        lite([
          {
            'id': 'w',
            'component': 'watchStatus',
            'title': 'W',
            'body': 'B',
            'status': 'check_now',
          },
        ]),
      ),
      hasLength(2),
    );
  });
}
