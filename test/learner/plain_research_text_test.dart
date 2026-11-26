// Research answers arrive as plain text (G2c finding, SS-089).

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/learner/plain_research_text.dart';

class _Markdown implements CookingResearchClient {
  const _Markdown();
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async =>
      const CookingResearchResult(
        answer: '## Tip\n**General Guidance**: use *low* heat.',
        citations: [],
        clarifyingQuestion: 'Is it __fresh__ or `canned`?',
        searchSuggestionsHtml: '<b>keep</b>',
      );
}

void main() {
  test('bold, italics, code, links, headings and rules are removed', () {
    expect(
      plainResearchText(
        '# Heading\n**General Guidance**\n\n\n\nUse _gentle_ heat and '
        '`stir`. See [USDA](https://example.org/a).\n---\nDone.',
      ),
      'Heading\nGeneral Guidance\n\nUse gentle heat and stir. See USDA.\n\n'
      'Done.',
    );
  });

  test(
    'list markers become bullets; words with underscores and maths stay',
    () {
      expect(
        plainResearchText('- one\n* two\n  + three\nsnake_case_name 2 * 3'),
        '• one\n• two\n  • three\nsnake_case_name 2 * 3',
      );
    },
  );

  test('the wrapper cleans the answer and question, keeps the rest', () async {
    final result = await const PlainTextResearchClient(_Markdown())
        .research(const CookingResearchQuery(question: 'q', currentStep: 's'));
    expect(result.answer, 'Tip\nGeneral Guidance: use low heat.');
    expect(result.clarifyingQuestion, 'Is it fresh or canned?');
    expect(result.searchSuggestionsHtml, '<b>keep</b>');
  });
}
