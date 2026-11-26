// Codex review of #221 at 09f2a47: privacy P1s (Nearby route at both entry
// points, voice disclosure, research follow-up privacy) and the P2/P3s in
// lines this PR changed. Fakes only.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_controls.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/label/label_check.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/meal_complete.dart';
import 'package:soussight/nearby/guarded_nearby_client.dart';
import 'package:soussight/nearby/nearby_client.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/pantry_ui.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/pantry/recipe_draft.dart';
import 'package:soussight/pantry/recipe_draft_client.dart';

class _CountingNearby implements NearbyClient {
  int calls = 0;
  @override
  Future<NearbyResult> find(NearbyQuery query) async {
    calls++;
    throw const NearbyException(NearbyFailure.noResults, 'none');
  }
}

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

class _Research implements CookingResearchClient {
  int calls = 0;
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async {
    calls++;
    return const CookingResearchResult(answer: 'An answer.');
  }
}

/// Fails every scan with no legs, like a bridge error.
class _Failing implements PantryClient {
  @override
  Future<PantryResult> identify(PantryInput input, List<Recipe> recipes) =>
      Future.error(
        const PantryException(
          'Ingredient matching is unavailable right now. Pick a recipe below.',
          legs: [
            InferenceLeg(
              requestId: 'scan-1',
              feature: kPantryScanFeature,
              mode: HybridMode.preferOnDevice,
              kinds: {DataKind.text},
              transferPermitted: true,
              provenance: Provenance.unknown,
              error: HybridErrorCode.network,
            ),
          ],
        ),
      );
}

class _DeniedMedia extends DemoLiveMedia {
  @override
  Future<void> start() async => throw StateError('NotAllowedError');
}

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('P1: the Nearby route is checked before location and at send', () {
    test('a denied route never reaches the sender', () async {
      final inner = _CountingNearby();
      final client = GuardedNearbyClient(inner: inner, allowed: () => false);
      await expectLater(
        client.find(const NearbyQuery(kind: NearbyKind.foodHelp, area: 'x')),
        throwsA(
          isA<NearbyException>().having(
            (e) => e.message,
            'message',
            kNearbyOffMessage,
          ),
        ),
      );
      expect(inner.calls, 0);
      expect(nearbyAllowed(client), isFalse);
      expect(nearbyAllowed(inner), isTrue);
    });

    test('an allowed route is re-read at send and passes through', () async {
      final inner = _CountingNearby();
      var allowed = true;
      final client = GuardedNearbyClient(inner: inner, allowed: () => allowed);
      await expectLater(
        client.find(const NearbyQuery(kind: NearbyKind.foodHelp, area: 'x')),
        throwsA(isA<NearbyException>()),
      );
      expect(inner.calls, 1);
      allowed = false; // the route changed after the sheet opened
      await expectLater(
        client.find(const NearbyQuery(kind: NearbyKind.foodHelp, area: 'x')),
        throwsA(isA<NearbyException>()),
      );
      expect(inner.calls, 1);
    });

    test('an approved route sends through the ledger-backed client', () async {
      final hybrid = HybridRuntime.create(
        inference: FakeHybridInference(),
        cloudRoutes: CloudRoutes.parse('nearby'),
        cloudFallback: _NoCloud(),
      );
      final client = hybridNearbyClient(hybrid);
      expect(client.allowed(), isTrue);
      final inner = client.inner as GeminiNearbyClient;
      expect(identical(inner.recorder, hybrid.cloudSends), isTrue);
      final off = hybridNearbyClient(
        HybridRuntime.create(
          inference: FakeHybridInference(),
          cloudRoutes: const CloudRoutes({}),
          cloudFallback: _NoCloud(),
        ),
      );
      expect(off.allowed(), isFalse);
    });

    testWidgets('pantry: a denied route asks for no location', (tester) async {
      await _phone(tester);
      final recipes = (await tester.runAsync(loadRecipeCatalog))!;
      final inner = _CountingNearby();
      var located = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: PantryScreen(
            recipes: recipes,
            client: const FakePantryClient(delay: Duration.zero),
            onChooseRecipe: (_, _) {},
            nearbyClient: GuardedNearbyClient(
              inner: inner,
              allowed: () => false,
            ),
            locate: () async {
              located++;
              return NearbyCoordinates(1, 1);
            },
          ),
        ),
      );
      final help = find.byKey(const ValueKey('nearby-food-help'));
      await tester.ensureVisible(help);
      await tester.pumpAndSettle();
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.text(kNearbyOffMessage), findsOneWidget);
      expect(find.text('Find food help nearby'), findsOneWidget); // card only
      expect(located, 0);
      expect(inner.calls, 0);
    });

    testWidgets('meal complete: the same guard, before any location', (
      tester,
    ) async {
      await _phone(tester);
      final services = (await tester.runAsync(fakeServices))!;
      final cook = CookingCoordinator(
        services: services,
        research: const FakeCookingResearchClient(),
        transportFactory: null,
        media: DemoLiveMedia(),
      );
      await tester.runAsync(cook.initialize);
      final inner = _CountingNearby();
      var located = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MealCompletePanel(
                cook: cook,
                isDemo: false,
                onTextHousehold: () {},
                onCookSomethingElse: null,
                nearbyClient: GuardedNearbyClient(
                  inner: inner,
                  allowed: () => false,
                ),
                locate: () async {
                  located++;
                  return NearbyCoordinates(1, 1);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('meal-complete-nearby'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(kNearbyOffMessage), findsOneWidget);
      expect(located, 0);
      expect(inner.calls, 0);
      cook.dispose();
    });
  });

  testWidgets('P1: Record says voice clips go online (real builds only)', (
    tester,
  ) async {
    await _phone(tester);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    for (final demo in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: PantryScreen(
            key: ValueKey(demo),
            recipes: recipes,
            client: const FakePantryClient(delay: Duration.zero),
            onChooseRecipe: (_, _) {},
            isDemo: demo,
            mediaFactory: demo ? null : DemoLiveMedia.new,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('mode-say')));
      await tester.pumpAndSettle();
      expect(
        find.text(pantryVoiceDisclosure),
        demo ? findsNothing : findsOneWidget,
      );
    }
  });

  test('P1: a research follow-up re-checks the origin\'s privacy', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final services = await fakeServices();
    final research = _Research();
    final cook = CookingCoordinator(
      services: services,
      research: research,
      transportFactory: null,
      media: DemoLiveMedia(),
    );
    await cook.initialize();
    var allowed = true;
    await cook.researchQuestionNow(
      'Can I swap the bread?',
      requestWorkspace: false,
      stillAllowed: () => allowed,
    );
    expect(research.calls, 1);
    final panel = cook.researchPanel!;
    final followUp = CookingResearchQuery(
      question: panel.query.question,
      currentStep: panel.query.currentStep,
    );
    allowed = false; // the cook turned on "keep typed questions here"
    expect(await panel.client.followUp(followUp), isNull);
    expect(research.calls, 1, reason: 'nothing was sent');
    expect(cook.error, contains('keep typed questions on this device'));
    allowed = true;
    expect(await panel.client.followUp(followUp), isNotNull);
    expect(research.calls, 2);
    cook.dispose();
  });

  group('P2/P3 in lines this PR changed', () {
    test('#6: "macaroni and cheese" never ticks a loose "cheese"', () {
      expect(pantryTypedEntries('a box of macaroni and cheese, rice'), [
        'box of macaroni and cheese',
        'rice',
      ]);
      expect(
        pantrySameItem('box of macaroni and cheese', 'macaroni and cheese'),
        isTrue,
      );
      expect(pantrySameItem('box of macaroni and cheese', 'cheese'), isFalse);
    });

    test(
      '#7: a model "watch" column is never replaced by the app panel',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final services = await fakeServices();
        final cook = CookingCoordinator(
          services: services,
          research: const FakeCookingResearchClient(),
          transportFactory: null,
          media: DemoLiveMedia(),
        );
        await cook.initialize();
        cook.ui.applyToolPayload({
          'components': [
            {
              'id': 'root',
              'component': 'CookingColumn',
              'children': ['watch'],
            },
            {
              'id': 'watch',
              'component': 'CookingColumn',
              'children': ['tip'],
            },
            {
              'id': 'tip',
              'component': 'stepCue',
              'title': 'Tip',
              'body': 'Stir.',
            },
          ],
        });
        cook.stopWatch(); // upserts the app's watch panel
        final ids = cook.ui.components.map((c) => c['id']).toSet();
        expect(
          ids,
          containsAll(['watch', 'tip', CookingCoordinator.watchPanelId]),
        );
        cook.dispose();
      },
    );

    test('#8: a rehearsal draft writes its leg to the ledger once', () async {
      final hybrid = RehearsalHybridRuntime.create(
        inference: RehearsalHybridInference(answerDelay: Duration.zero),
      );
      final result = await RehearsalDraftClient(
        hybrid,
        const FakeRecipeDraftClient(delay: Duration.zero),
      ).draft(const RecipeDraftRequest(confirmedItems: ['rice']));
      expect(result.legs, isNotEmpty);
      expect(hybrid.ledger.legs, hasLength(result.legs.length));
      expect(
        hybrid.ledger.legs.map((l) => l.requestId),
        result.legs.map((l) => l.requestId),
      );
      expect(
        hybrid.ledger.legs.every((l) => l.provenance == Provenance.simulated),
        isTrue,
      );
    });

    test('#10: no choice made, nothing attributed to the cook', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final services = await fakeServices();
      final cook = CookingCoordinator(
        services: services,
        research: const FakeCookingResearchClient(),
        transportFactory: null,
        media: DemoLiveMedia(),
      );
      await cook.initialize();
      await cook.checkNow();
      expect(cook.alert, isNot(contains('You said')));
      await cook.checkNow('Ready');
      expect(cook.alert, startsWith('You said: Ready.'));
      cook.dispose();
    });

    test('#12: the user-facing rehearsal keeps no request copies', () async {
      final inference = RehearsalHybridInference(answerDelay: Duration.zero);
      await inference.generate(
        HybridRequest(
          requestId: 'r',
          mode: HybridMode.onlyOnDevice,
          task: HybridTask(
            feature: kLabelCheckFeature,
            parts: [HybridText(buildTypedPrompt('milk'))],
            maxOutputTokens: 50,
            timeout: const Duration(seconds: 5),
          ),
        ),
      );
      expect(inference.requests, isEmpty);
    });

    test('#13: "and" needs every part; "or" accepts either', () {
      expect(
        practiceIngredientMatch(['salt'], 'Salt and black pepper'),
        isNull,
      );
      expect(
        practiceIngredientMatch([
          'salt',
          'black pepper',
        ], 'Salt and black pepper'),
        ['salt', 'black pepper'],
      );
      expect(
        practiceIngredientMatch([
          'tortillas',
        ], 'Tortilla chips or tortillas, for serving'),
        ['tortillas'],
      );
    });

    test('#14: allergens match whole names and plurals only', () {
      String found(String label) =>
          parseLabelReading(practiceLabelAnswer(buildTypedPrompt(label)))
              .allergensMentioned
              .join(',');
      expect(found('Ingredients: eggplant'), '');
      expect(found('Contains: eggs, peanuts'), contains('egg'));
      expect(found('Contains: eggs, peanuts'), contains('peanut'));
    });

    testWidgets('#16: a camera error never shows a previous match\'s badges', (
      tester,
    ) async {
      await _phone(tester);
      final recipes = (await tester.runAsync(loadRecipeCatalog))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: PantryScreen(
            recipes: recipes,
            client: _Failing(),
            onChooseRecipe: (_, _) {},
            mediaFactory: _DeniedMedia.new,
          ),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'rice');
      final find0 = find.byKey(const ValueKey('find-meal'));
      await tester.ensureVisible(find0);
      await tester.pumpAndSettle();
      await tester.tap(find0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pantry-legs')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('mode-scan')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mode-scan')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Camera or microphone is blocked'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('pantry-legs')), findsNothing);
      expect(
        find.byKey(const ValueKey('pantry-no-answer-source')),
        findsNothing,
      );
    });
  });
}
