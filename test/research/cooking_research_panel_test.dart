import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/main_research_demo.dart';
import 'package:soussight/research/cooking_research_panel.dart';

class _TestResearchClient implements CookingResearchClient {
  _TestResearchClient(this.handler);

  final Future<CookingResearchResult> Function(CookingResearchQuery query)
  handler;
  final List<CookingResearchQuery> calls = <CookingResearchQuery>[];

  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) {
    calls.add(query);
    return handler(query);
  }
}

void main() {
  const initialQuery = CookingResearchQuery(
    question: "I don't have lemon—can I use vinegar?",
    currentStep: 'Step 2: Whisk lemon-tahini dressing',
    confirmedIngredients: <String>['1 can chickpeas', '2 tbsp tahini'],
  );

  Future<void> configureViewport(
    WidgetTester tester, {
    Size size = const Size(960, 1200),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget wrapWidget(Widget child) {
    return MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );
  }

  testWidgets(
    'shows loading then clarification, and submitting clarification preserves original question and confirmed facts',
    (WidgetTester tester) async {
      await configureViewport(tester);

      final firstCompleter = Completer<CookingResearchResult>();
      final secondCompleter = Completer<CookingResearchResult>();

      final client = _TestResearchClient((query) {
        if (query.confirmedIngredients.length == 2) {
          return firstCompleter.future;
        }
        return secondCompleter.future;
      });

      final confirmedFacts = <String>[];

      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: initialQuery,
            onCookConfirmed: confirmedFacts.add,
          ),
        ),
      );

      // 1. Loading state and original question are visible immediately.
      expect(
        find.byKey(const Key('research_loading_indicator')),
        findsOneWidget,
      );
      expect(
        find.text("I don't have lemon—can I use vinegar?"),
        findsOneWidget,
      );

      // 2. Complete with a clarifying question.
      firstCompleter.complete(
        const CookingResearchResult(
          answer:
              'Vinegar can substitute for lemon juice depending on the variety.',
          clarifyingQuestion: 'Which vinegar do you have on hand?',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('research_clarification_card')),
        findsOneWidget,
      );
      expect(find.text('Which vinegar do you have on hand?'), findsOneWidget);

      // 3. Submit cook's clarification answer.
      final clarificationInput = find.byKey(
        const Key('research_clarification_input'),
      );
      final clarificationSubmit = find.byKey(
        const Key('research_clarification_submit_button'),
      );
      await tester.ensureVisible(clarificationInput);
      await tester.enterText(clarificationInput, 'Apple cider vinegar');
      await tester.ensureVisible(clarificationSubmit);
      await tester.tap(clarificationSubmit);
      await tester.pump();

      expect(client.calls, hasLength(2));
      expect(
        client.calls.last.question,
        "I don't have lemon—can I use vinegar?",
      );
      expect(client.calls.last.currentStep, initialQuery.currentStep);
      expect(client.calls.last.confirmedIngredients, <String>[
        '1 can chickpeas',
        '2 tbsp tahini',
        'Apple cider vinegar',
      ]);

      // Clarifying does not automatically fire onCookConfirmed for a substitution.
      expect(confirmedFacts, isEmpty);

      // Previous clarification/answer is cleared while the follow-up loads.
      expect(find.byKey(const Key('research_answer_text')), findsNothing);

      // 4. Complete the follow-up research call with a cited answer.
      secondCompleter.complete(
        CookingResearchResult(
          answer: 'Use 1 tbsp apple cider vinegar for 1 tbsp lemon juice.',
          citations: <CookingCitation>[
            CookingCitation(
              title: 'Clemson Extension Acid Swaps',
              uri: Uri.parse('https://hgic.clemson.edu/factsheet/substitutions'),
            ),
          ],
          searchSuggestionsHtml: '<div>Google Search suggestions</div>',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Use 1 tbsp apple cider vinegar for 1 tbsp lemon juice.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('research_badge_source_backed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('research_search_suggestions')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'rejects stale late response when a newer question is provided',
    (WidgetTester tester) async {
      await configureViewport(tester);

      final oldCompleter = Completer<CookingResearchResult>();
      final newCompleter = Completer<CookingResearchResult>();

      final client = _TestResearchClient((query) {
        if (query.question.contains('lemon')) {
          return oldCompleter.future;
        }
        return newCompleter.future;
      });

      const newerQuery = CookingResearchQuery(
        question: 'How much ground cumin replaces whole cumin seeds?',
        currentStep: 'Step 3: Toast spices',
        confirmedIngredients: <String>['Ground cumin'],
      );

      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: initialQuery,
            onCookConfirmed: (_) {},
          ),
        ),
      );

      // Update widget with a newer question before the old question completes.
      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: newerQuery,
            onCookConfirmed: (_) {},
          ),
        ),
      );

      // Complete the newer question first.
      newCompleter.complete(
        const CookingResearchResult(
          answer: 'Use 1/2 teaspoon ground cumin per 1 teaspoon whole seeds.',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('How much ground cumin replaces whole cumin seeds?'),
        findsOneWidget,
      );
      expect(
        find.text('Use 1/2 teaspoon ground cumin per 1 teaspoon whole seeds.'),
        findsOneWidget,
      );

      // Now resolve the late response from the old question; it must be ignored.
      oldCompleter.complete(
        const CookingResearchResult(
          answer: 'STALE LEMON ANSWER SHOULD BE IGNORED',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('STALE LEMON ANSWER SHOULD BE IGNORED'), findsNothing);
      expect(
        find.text('Use 1/2 teaspoon ground cumin per 1 teaspoon whole seeds.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'clears completed question A answer, citations, and clarification when switching to pending or failed question B',
    (WidgetTester tester) async {
      await configureViewport(tester);

      final questionBCompleter = Completer<CookingResearchResult>();
      final client = _TestResearchClient((query) async {
        if (query.question == initialQuery.question) {
          return CookingResearchResult(
            answer: 'Completed answer for Question A.',
            clarifyingQuestion: 'Clarification from Question A?',
            citations: <CookingCitation>[
              CookingCitation(
                title: 'Question A Citation',
                uri: Uri.parse('https://extension.example.edu/question-a'),
              ),
            ],
          );
        }
        return questionBCompleter.future;
      });

      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: initialQuery,
            onCookConfirmed: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Completed answer for Question A.'), findsOneWidget);
      expect(find.text('Clarification from Question A?'), findsOneWidget);
      expect(find.text('Question A Citation'), findsOneWidget);

      const questionB = CookingResearchQuery(
        question: 'Question B: Can I toast the wrap in a dry skillet?',
        currentStep: 'Step 4: Warm wraps',
        confirmedIngredients: <String>['Whole wheat tortillas'],
      );

      // Switch to Question B while B is pending.
      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: questionB,
            onCookConfirmed: (_) {},
          ),
        ),
      );
      await tester.pump();

      // Question B is shown in loading state; Question A's answer, citations,
      // clarification, and confirmation controls must be cleared immediately.
      expect(
        find.text('Question B: Can I toast the wrap in a dry skillet?'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('research_loading_indicator')),
        findsOneWidget,
      );
      expect(find.text('Completed answer for Question A.'), findsNothing);
      expect(find.text('Clarification from Question A?'), findsNothing);
      expect(find.text('Question A Citation'), findsNothing);
      expect(
        find.byKey(const Key('research_clarification_card')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('research_confirmation_section')),
        findsNothing,
      );

      // Fail Question B; Question A's stale content must remain cleared.
      questionBCompleter.completeError(
        TimeoutException('Question B timed out'),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('research_error_container')), findsOneWidget);
      expect(find.text('Completed answer for Question A.'), findsNothing);
      expect(find.text('Clarification from Question A?'), findsNothing);
      expect(find.text('Question A Citation'), findsNothing);
      expect(
        find.byKey(const Key('research_clarification_card')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'validates citations to allow only valid HTTPS links and distinguishes uncited answers',
    (WidgetTester tester) async {
      await configureViewport(tester);

      final openedCitations = <CookingCitation>[];

      final client = _TestResearchClient((_) async {
        return CookingResearchResult(
          answer: 'Grounded answer with mixed citations.',
          citations: <CookingCitation>[
            CookingCitation(
              title: 'Valid HTTPS Extension Guide',
              uri: Uri.parse('https://extension.umn.edu/substitutions'),
            ),
            CookingCitation(
              title: 'Duplicate HTTPS Guide',
              uri: Uri.parse('https://extension.umn.edu/substitutions'),
            ),
            CookingCitation(
              title: 'Insecure HTTP Link',
              uri: Uri.parse('http://insecure.example.com/swap'),
            ),
            CookingCitation(
              title: 'JavaScript URI',
              uri: Uri.parse('javascript:alert(1)'),
            ),
            CookingCitation(
              title: 'Credentials in URI',
              uri: Uri.parse('https://user:secret@example.com/swap'),
            ),
          ],
        );
      });

      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: initialQuery,
            onCookConfirmed: (_) {},
            onOpenSource: openedCitations.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Valid HTTPS Extension Guide'), findsOneWidget);
      expect(find.text('Duplicate HTTPS Guide'), findsNothing);
      expect(find.text('Insecure HTTP Link'), findsNothing);
      expect(find.text('JavaScript URI'), findsNothing);
      expect(find.text('Credentials in URI'), findsNothing);

      final citationButton = find.byKey(
        const Key('research_citation_button_0'),
      );
      await tester.ensureVisible(citationButton);
      await tester.tap(citationButton);
      await tester.pump();

      expect(openedCitations, hasLength(1));
      expect(
        openedCitations.single.uri.toString(),
        'https://extension.umn.edu/substitutions',
      );
    },
  );

  testWidgets(
    'distinguishes uncited answers without fabricating sources',
    (WidgetTester tester) async {
      await configureViewport(tester);

      final client = _TestResearchClient((_) async {
        return const CookingResearchResult(
          answer: 'Uncited answer text.',
          citations: <CookingCitation>[],
        );
      });

      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: initialQuery,
            onCookConfirmed: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('research_badge_uncited')), findsOneWidget);
      expect(
        find.byKey(const Key('research_no_citations_notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('research_citation_button_0')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'retry preserves the original question and confirmed facts after failure',
    (WidgetTester tester) async {
      await configureViewport(tester);

      var attempts = 0;
      final client = _TestResearchClient((query) async {
        attempts++;
        if (attempts == 1) {
          throw TimeoutException('Search timed out');
        }
        return const CookingResearchResult(
          answer: 'Recovered answer on retry.',
        );
      });

      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: initialQuery,
            onCookConfirmed: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('research_error_container')), findsOneWidget);
      expect(
        find.text("I don't have lemon—can I use vinegar?"),
        findsOneWidget,
      );

      final retryButton = find.byKey(const Key('research_retry_button'));
      await tester.ensureVisible(retryButton);
      await tester.tap(retryButton);
      await tester.pumpAndSettle();

      expect(client.calls, hasLength(2));
      expect(client.calls[1].question, initialQuery.question);
      expect(
        client.calls[1].confirmedIngredients,
        initialQuery.confirmedIngredients,
      );
      expect(find.text('Recovered answer on retry.'), findsOneWidget);
    },
  );

  testWidgets(
    'leaves confirmation input empty on reverse or declined substitution answers and fires onCookConfirmed only after explicit entry',
    (WidgetTester tester) async {
      await configureViewport(tester);

      final confirmed = <String>[];
      const reverseQuery = CookingResearchQuery(
        question: 'Can I use lemon instead of vinegar?',
        currentStep: 'Step 2: Whisk dressing',
        confirmedIngredients: <String>['1 can chickpeas'],
      );

      final client = _TestResearchClient((_) async {
        return const CookingResearchResult(
          answer:
              'Do not substitute vinegar here; keep the recipe as written or skip the acid.',
        );
      });

      await tester.pumpWidget(
        wrapWidget(
          CookingResearchPanel(
            client: client,
            query: reverseQuery,
            onCookConfirmed: confirmed.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Never pre-populates an invented substitution draft from question keywords.
      final confirmationField = tester.widget<TextField>(
        find.byKey(const Key('research_confirmation_input')),
      );
      expect(confirmationField.controller?.text, isEmpty);
      expect(confirmed, isEmpty);

      // Tapping Confirm while empty shows a validation prompt and does not fire callback.
      final confirmButton = find.byKey(
        const Key('research_confirm_fact_button'),
      );
      await tester.ensureVisible(confirmButton);
      await tester.tap(confirmButton);
      await tester.pump();
      expect(confirmed, isEmpty);

      // Cook explicitly types and reviews the exact fact before confirming.
      final confirmationInput = find.byKey(
        const Key('research_confirmation_input'),
      );
      await tester.ensureVisible(confirmationInput);
      await tester.enterText(
        confirmationInput,
        'Using 1 tbsp fresh lemon juice instead of white wine vinegar',
      );
      await tester.ensureVisible(confirmButton);
      await tester.tap(confirmButton);
      await tester.pump();

      expect(confirmed, <String>[
        'Using 1 tbsp fresh lemon juice instead of white wine vinegar',
      ]);
      expect(
        find.byKey(const Key('research_confirmed_feedback_text')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'renders cleanly at both narrow phone and desktop widths in the isolated demo',
    (WidgetTester tester) async {
      // Narrow phone viewport (375x812)
      await tester.binding.setSurfaceSize(const Size(375, 812));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(const ResearchDemoApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('demo_rehearsal_banner')), findsOneWidget);
      expect(find.byKey(const Key('cooking_research_panel')), findsOneWidget);

      // Desktop viewport (1280x900)
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cooking_research_panel')), findsOneWidget);
    },
  );
}
