# Grounded Cooking Research & Substitution Workspace (`SS-005`)

Owner: AGY (`agy/cooking-research` branch)

## Overview

`CookingResearchPanel` (`lib/research/cooking_research_panel.dart`) provides the grounded cooking answer and substitution experience for SousSight.

- **The cook is the human in the loop.** There is no external instructor board, help queue, or expert handoff.
- **Clarification preserves context:** When `CookingResearchResult.clarifyingQuestion` is returned, the cook answers in a short editable field, and `CookingResearchPanel` dispatches a new `CookingResearchQuery` preserving the original question, current recipe step, and all previously confirmed kitchen facts.
- **Strict HTTPS citation validation:** Only valid `https://` citations with a host and no embedded user credentials are rendered as clickable source buttons. Answers without returned citations are explicitly labeled as unverified without fabricating sources.
- **Provider search suggestions attribution:** `SearchSuggestions` (`lib/research/search_suggestions.dart`) preserves unmodified `searchSuggestionsHtml` in a sandboxed iframe (`allow-popups allow-popups-to-escape-sandbox`, no `allow-scripts` or `allow-same-origin`) on Flutter web.
- **Explicit cook confirmation:** Substitutions and kitchen facts are never applied silently. The cook reviews and edits the exact fact in an editable field before `onCookConfirmed` fires.
- **Stale async protection:** Monotonic request generation tokens ensure late responses or superseded retries never overwrite a newer question.

## Public API

```dart
CookingResearchPanel(
  client: researchClient,
  query: CookingResearchQuery(
    question: "I don't have lemon—can I use vinegar?",
    currentStep: 'Step 2: Whisk lemon-tahini dressing',
    confirmedIngredients: ['1 can chickpeas', '2 tbsp tahini'],
  ),
  onCookConfirmed: (String fact) {
    // Persist the cook-reviewed substitution/fact into the session
  },
  onOpenSource: (CookingCitation citation) {
    // Launch validated HTTPS source URL
  },
)
```

## Isolated Demo Entrypoint

Run or build the camera-free, scripted fake-client demo using `lib/main_research_demo.dart`:

```sh
flutter analyze
flutter test test/research/cooking_research_panel_test.dart
flutter build web -t lib/main_research_demo.dart
```

The demo explicitly discloses that all responses are scripted and covers:
1. Missing lemon → clarification → cited answer → explicit cook confirmation
2. Answer with no returned citations
3. Timeout → retry preserving the original question
4. Late response to an old question rejected after a newer question is asked
