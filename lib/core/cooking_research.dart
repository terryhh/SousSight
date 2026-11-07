/// Provider-independent contract for grounded cooking answers. The cook supplies
/// missing facts; the service does not route questions to an external person.
class CookingResearchQuery {
  const CookingResearchQuery({
    required this.question,
    required this.currentStep,
    this.confirmedIngredients = const [],
  });
  final String question;
  final String currentStep;
  final List<String> confirmedIngredients;
}

class CookingCitation {
  const CookingCitation({required this.title, required this.uri});
  final String title;
  final Uri uri;
}

class CookingResearchResult {
  const CookingResearchResult({
    required this.answer,
    this.citations = const [],
    this.clarifyingQuestion,
    this.searchSuggestionsHtml,
  });
  final String answer;
  final List<CookingCitation> citations;
  final String? clarifyingQuestion;

  /// Unmodified provider attribution, rendered in an isolated browser surface.
  final String? searchSuggestionsHtml;
}

abstract class CookingResearchClient {
  Future<CookingResearchResult> research(CookingResearchQuery query);
}
