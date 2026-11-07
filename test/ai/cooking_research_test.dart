import 'dart:async';

import 'package:firebase_ai/firebase_ai.dart';
// SDK 5.1 exports the getters but not these constructors. This import is only
// for grounding metadata fixtures; production uses the public response API.
// ignore: implementation_imports
import 'package:firebase_ai/src/api.dart'
    show GroundingMetadata, SearchEntryPoint;
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/core/cooking_research.dart';

const _query = CookingResearchQuery(
  question: 'What can add acidity when I have no lemon?',
  currentStep: 'Mix the chickpea filling',
  confirmedIngredients: ['chickpeas', 'yogurt'],
);

GenerateContentResponse _response({
  String answer =
      'Add a small amount of a suitable acidic ingredient and taste.',
  List<WebGroundingChunk> sources = const [],
  String? suggestions,
}) => GenerateContentResponse([
  Candidate(
    Content.text(answer),
    null,
    null,
    FinishReason.stop,
    null,
    groundingMetadata: GroundingMetadata(
      groundingChunks: [
        for (final source in sources) GroundingChunk(web: source),
      ],
      groundingSupports: [],
      webSearchQueries: ['ingredient acidity cooking'],
      searchEntryPoint: suggestions == null
          ? null
          : SearchEntryPoint(renderedContent: suggestions),
    ),
  ),
], null);

void main() {
  test('returns only HTTPS citations from provider metadata, preserving suggestions', () async {
    const suggestions = '<div>Google Search suggestions</div>';
    CookingResearchQuery? received;
    final client = GeminiCookingResearchClient(
      generate: (query) async {
        received = query;
        return _response(
          answer: 'Do not infer a citation from this prose: https://invented.example/recipe.',
          suggestions: suggestions,
          sources: [
            WebGroundingChunk(
              title: 'University extension',
              uri: 'https://extension.example.edu/cooking',
            ),
            WebGroundingChunk(
              title: 'Repeated source',
              uri: 'https://extension.example.edu/cooking',
            ),
            WebGroundingChunk(uri: 'https://www.example.gov/food'),
            WebGroundingChunk(
              title: 'Not HTTPS',
              uri: 'http://insecure.example/recipe',
            ),
            WebGroundingChunk(title: 'Script', uri: 'javascript:alert(1)'),
            WebGroundingChunk(title: 'Relative', uri: '/recipe'),
            WebGroundingChunk(
              title: 'Credentials',
              uri: 'https://user:pass@example.com/recipe',
            ),
            WebGroundingChunk(title: 'No URL'),
          ],
        );
      },
    );
    final result = await client.research(_query);
    expect(identical(received, _query), isTrue);
    expect(result.citations.map((source) => source.uri.toString()), [
      'https://extension.example.edu/cooking',
      'https://www.example.gov/food',
    ]);
    expect(result.citations.map((source) => source.title), [
      'University extension',
      'www.example.gov',
    ]);
    expect(result.searchSuggestionsHtml, suggestions);
    expect(() => result.citations.clear(), throwsUnsupportedError);
  });

  test('empty or blocked responses become friendly typed failures', () async {
    for (final response in [
      GenerateContentResponse([], null),
      _response(answer: '   '),
      GenerateContentResponse([
        Candidate(
          Content.text(''),
          null,
          null,
          FinishReason.safety,
          'provider internal details',
        ),
      ], null),
    ]) {
      final client = GeminiCookingResearchClient(
        generate: (_) async => response,
      );
      await expectLater(
        client.research(_query),
        throwsA(isA<CookingResearchException>()),
      );
    }
  });

  test(
    'does not call an unsupported answer grounded when no sources return',
    () async {
      final client = GeminiCookingResearchClient(
        generate: (_) async => _response(),
      );
      await expectLater(
        client.research(_query),
        throwsA(
          isA<CookingResearchException>().having(
            (error) => error.reason,
            'reason',
            CookingResearchFailure.noSources,
          ),
        ),
      );
    },
  );

  test(
    'maps network errors and timeouts without exposing provider text',
    () async {
      final failure = GeminiCookingResearchClient(
        generate: (_) async => throw StateError('secret provider detail'),
      );
      await expectLater(
        failure.research(_query),
        throwsA(
          isA<CookingResearchException>()
              .having(
                (error) => error.reason,
                'reason',
                CookingResearchFailure.unavailable,
              )
              .having(
                (error) => error.message.contains('secret'),
                'reveals provider detail',
                isFalse,
              ),
        ),
      );
      final slow = GeminiCookingResearchClient(
        generate: (_) => Completer<GenerateContentResponse>().future,
        timeout: const Duration(milliseconds: 1),
      );
      await expectLater(
        slow.research(_query),
        throwsA(
          isA<CookingResearchException>().having(
            (error) => error.reason,
            'reason',
            CookingResearchFailure.timeout,
          ),
        ),
      );
    },
  );

  test('validates input before making a request', () async {
    var called = false;
    final client = GeminiCookingResearchClient(
      generate: (_) async {
        called = true;
        return _response();
      },
    );
    await expectLater(
      client.research(
        const CookingResearchQuery(question: ' ', currentStep: 'Mix'),
      ),
      throwsA(
        isA<CookingResearchException>().having(
          (error) => error.reason,
          'reason',
          CookingResearchFailure.invalidQuestion,
        ),
      ),
    );
    expect(called, isFalse);
  });

  test(
    'fake research is labelled rehearsal and contains no invented citations',
    () async {
      final result = await const FakeCookingResearchClient().research(_query);
      expect(result.answer, contains('Rehearsal mode'));
      expect(result.answer, contains('no web search'));
      expect(result.citations, isEmpty);
      expect(result.searchSuggestionsHtml, isNull);
      expect(result.clarifyingQuestion, isNotEmpty);
    },
  );
}
