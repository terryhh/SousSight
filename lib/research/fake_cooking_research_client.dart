import 'dart:async';

import '../core/cooking_research.dart';

/// Scripted scenario identifiers for the isolated camera-free research demo.
enum ResearchDemoScenario {
  lemonVinegarClarificationFlow,
  noCitationsReturned,
  timeoutThenRetrySuccess,
  lateResponseStaleRejection,
}

/// Camera-free, scripted fake [CookingResearchClient] for the isolated demo and
/// widget tests.
///
/// Clearly discloses that responses are scripted and never claims to have
/// called Google Search or Gemini.
class DemoCookingResearchClient implements CookingResearchClient {
  DemoCookingResearchClient({
    this.scenario = ResearchDemoScenario.lemonVinegarClarificationFlow,
    this.simulatedDelay = const Duration(milliseconds: 250),
  });

  ResearchDemoScenario scenario;
  Duration simulatedDelay;

  int _timeoutScenarioAttempts = 0;
  final List<CookingResearchQuery> recordedQueries = <CookingResearchQuery>[];

  /// Optional manual completer hook used by the "late response to an old
  /// question" scenario so the user or test can see an older request finish
  /// after a newer question has already been submitted.
  Completer<CookingResearchResult>? pendingStaleRequest;

  void resetScenarioState() {
    _timeoutScenarioAttempts = 0;
    pendingStaleRequest = null;
  }

  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async {
    recordedQueries.add(query);

    switch (scenario) {
      case ResearchDemoScenario.lemonVinegarClarificationFlow:
        await Future<void>.delayed(simulatedDelay);
        return _buildLemonVinegarFlow(query);

      case ResearchDemoScenario.noCitationsReturned:
        await Future<void>.delayed(simulatedDelay);
        return const CookingResearchResult(
          answer:
              '[Scripted demo · No live Google call] For mild acidity in a chickpea wrap dressing, a small splash of mild vinegar can stand in for lemon juice, starting with half the amount and tasting as you go.',
          citations: <CookingCitation>[],
        );

      case ResearchDemoScenario.timeoutThenRetrySuccess:
        _timeoutScenarioAttempts++;
        await Future<void>.delayed(simulatedDelay);
        if (_timeoutScenarioAttempts == 1) {
          throw TimeoutException(
            'Scripted demo timeout: The cooking search took too long. Please retry your question.',
          );
        }
        return CookingResearchResult(
          answer:
              '[Scripted demo · Recovered on retry #$_timeoutScenarioAttempts] You can substitute 1 tablespoon of apple cider vinegar or white wine vinegar for 1 tablespoon of fresh lemon juice in savory dressings.',
          citations: <CookingCitation>[
            CookingCitation(
              title: 'University Extension — Pantry Acid Substitutions',
              uri: Uri.parse(
                'https://extension.umn.edu/food-safety/ingredient-substitutions',
              ),
            ),
          ],
          searchSuggestionsHtml:
              '<div class="google-search-suggestions"><span>Scripted demo attribution preview: lemon juice substitution vinegar</span></div>',
        );

      case ResearchDemoScenario.lateResponseStaleRejection:
        final isOldQuestion =
            query.question.toLowerCase().contains('lemon') ||
            recordedQueries.length == 1;
        if (isOldQuestion && pendingStaleRequest != null) {
          return pendingStaleRequest!.future;
        }
        await Future<void>.delayed(simulatedDelay);
        return CookingResearchResult(
          answer:
              '[Scripted demo · Fresh response for "${query.question}"] Use 1/2 teaspoon ground cumin per 1 teaspoon whole cumin seeds, toasted lightly in the pan.',
          citations: <CookingCitation>[
            CookingCitation(
              title: 'USDA Seasonal Produce & Spice Guide',
              uri: Uri.parse('https://snaped.fns.usda.gov/resources/nutrition-education-materials'),
            ),
          ],
        );
    }
  }

  CookingResearchResult _buildLemonVinegarFlow(CookingResearchQuery query) {
    final factsLower = query.confirmedIngredients
        .map((f) => f.toLowerCase())
        .join(' | ');
    final hasVinegarKind =
        factsLower.contains('vinegar') ||
        factsLower.contains('apple cider') ||
        factsLower.contains('white wine') ||
        factsLower.contains('rice') ||
        factsLower.contains('distilled');

    if (!hasVinegarKind) {
      return const CookingResearchResult(
        answer:
            '[Scripted demo · Step 1: Clarification needed] Vinegar works well to replace the brightness of lemon juice in spiced chickpeas, but the ratio depends on which vinegar you have on hand.',
        clarifyingQuestion:
            'Which vinegar do you have in your kitchen (for example, apple cider, white wine, rice, or distilled white vinegar)?',
        citations: <CookingCitation>[],
      );
    }

    return CookingResearchResult(
      answer:
          '[Scripted demo · Step 2: Cited answer using your confirmed facts] With your confirmed pantry ingredients (${query.confirmedIngredients.join(", ")}), use an equal amount (1:1 ratio, such as 1 tbsp vinegar for 1 tbsp lemon juice) if using apple cider or white wine vinegar, or 3/4 tbsp plus 1/4 tbsp water if using sharper distilled white vinegar.',
      citations: <CookingCitation>[
        CookingCitation(
          title: 'Clemson Cooperative Extension — Common Ingredient Substitutions',
          uri: Uri.parse('https://hgic.clemson.edu/factsheet/common-ingredient-substitutions/'),
        ),
        CookingCitation(
          title: 'USDA MyPlate Kitchen — Healthy Seasoning & Acid Swaps',
          uri: Uri.parse('https://www.myplate.gov/myplate-kitchen'),
        ),
        // Intentionally include an insecure HTTP link to demonstrate that
        // CookingResearchPanel filters out non-HTTPS citations automatically.
        CookingCitation(
          title: 'Insecure HTTP Source (Filtered Out)',
          uri: Uri.parse('http://insecure.example.com/recipe'),
        ),
      ],
      searchSuggestionsHtml:
          '<div style="font-family:sans-serif;font-size:13px;padding:8px;background:#f8f9fa;border-radius:8px;"><strong>Google Search suggestions (scripted demo preview):</strong> lemon juice to apple cider vinegar ratio chickpea dressing</div>',
    );
  }
}
