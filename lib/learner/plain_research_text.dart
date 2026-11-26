// Research answers are shown as plain text by the research panel, so
// Markdown from the model (`**General Guidance**`, `- item`) would appear raw
// (G2c finding, SS-089). This strips it to readable plain text.

import '../ai/cooking_research_client.dart'
    show CookingResearchException, CookingResearchFailure;
import '../core/cooking_research.dart';

final _bold = RegExp(r'(\*\*|__)(.+?)\1');
final _italic = RegExp(r'(?<![\w*])([*_])(?!\s)(.+?)(?<!\s)\1(?![\w*])');
final _code = RegExp(r'`([^`]*)`');
final _link = RegExp(r'\[([^\]]+)\]\((?:[^)]+)\)');
final _heading = RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true);
final _bullet = RegExp(r'^(\s*)[-*+]\s+', multiLine: true);
final _rule = RegExp(r'^\s*([-*_])\s*(\1\s*){2,}$', multiLine: true);
final _blankRuns = RegExp(r'\n{3,}');

/// [text] with basic Markdown removed: bold, italics, inline code, links
/// (their text is kept), headings and horizontal rules. List markers become
/// "• " so lists still read as lists.
String plainResearchText(String text) {
  var out = text.replaceAll('\r\n', '\n');
  out = out.replaceAll(_rule, '');
  out = out.replaceAll(_heading, '');
  out = out.replaceAllMapped(_bullet, (m) => '${m[1]}• ');
  out = out.replaceAllMapped(_link, (m) => m[1]!);
  out = out.replaceAllMapped(_code, (m) => m[1]!);
  out = out.replaceAllMapped(_bold, (m) => m[2]!);
  out = out.replaceAllMapped(_italic, (m) => m[2]!);
  return out.replaceAll(_blankRuns, '\n\n').trim();
}

/// Wraps a research client so its answers and clarifying questions arrive as
/// plain text. Citations and the provider attribution are passed through
/// untouched.
class PlainTextResearchClient implements CookingResearchClient {
  const PlainTextResearchClient(this.inner);
  final CookingResearchClient inner;

  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async {
    final result = await inner.research(query);
    final answer = plainResearchText(result.answer);
    // Nothing left once the Markdown and list markers are gone is no answer
    // (Codex #221).
    if (answer.replaceAll(RegExp(r'[\s•*_\-#>`]+'), '').isEmpty) {
      throw const CookingResearchException(
        CookingResearchFailure.empty,
        'The search did not return a usable answer. Try a more specific '
        'question.',
      );
    }
    return CookingResearchResult(
      answer: answer,
      citations: result.citations,
      clarifyingQuestion: switch (result.clarifyingQuestion) {
        final q? => plainResearchText(q),
        null => null,
      },
      searchSuggestionsHtml: result.searchSuggestionsHtml,
    );
  }
}
