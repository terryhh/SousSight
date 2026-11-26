// Errors that reach the cook are often shown with '$error'. Their text must be
// the safe, cook-facing message and nothing else (no class names, provider
// detail or request content).

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/pantry/recipe_draft.dart';

void main() {
  test('a recipe draft failure prints only its cook-facing message', () {
    const error = RecipeDraftException('Could not draft a recipe. Try again.');
    expect('$error', 'Could not draft a recipe. Try again.');
  });

  test('a research failure prints only its cook-facing message', () {
    const error = CookingResearchException(
      CookingResearchFailure.timeout,
      'The cooking search took too long. Please try again.',
    );
    expect('$error', 'The cooking search took too long. Please try again.');
    expect(error.reason, CookingResearchFailure.timeout);
  });
}
