import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/data/dinner_messages.dart';
import 'package:soussight/data/dinner_status.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/meal_complete.dart';
import 'package:soussight/live/live_types.dart';

class _Transport extends DemoLiveTransport {
  final source = StreamController<LiveEvent>.broadcast();
  final texts = <String>[];
  @override
  Stream<LiveEvent> get events => source.stream;
  @override
  Future<void> sendText(String text) async => texts.add(text);
  @override
  Future<void> close() async {
    await source.close();
    await super.close();
  }
}

class _Media extends DemoLiveMedia {
  int stops = 0;
  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
  }
}

void main() {
  test('pantry items come only from the cook-confirmed pantry fact', () {
    expect(
      pantryItemsFromFacts([
        'Use whole wheat bread.',
        'Pantry has (confirmed by the cook): canned black beans, Rice, rice.',
      ]),
      ['canned black beans', 'Rice'],
    );
    expect(pantryItemsFromFacts(['Pantry is empty.']), isEmpty);
  });

  late _Transport transport;
  late _Media media;
  late CookingCoordinator cook;
  late List<DinnerMessageRequest> submissions;
  late int backCalls;

  Future<void> finishAllSteps(WidgetTester tester, {bool pantry = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = (await tester.runAsync(() async {
      final recipe = await loadBundledRecipe();
      final auth = FakeAuthService();
      final sessions = FakeSessionRepository();
      final session = await sessions.createNew(
        await auth.signInLearner(),
        recipe,
      );
      await sessions.update(
        session.id,
        (s) => s.copyWith(
          ingredients: {recipe.ingredients.first.id: IngredientStatus.have},
          confirmedFacts: [
            'Pantry has (confirmed by the cook): pantry oats, pantry honey.',
          ],
        ),
      );
      return AppServices(
        auth: auth,
        recipes: FakeRecipeRepository(recipe),
        sessions: sessions,
        bundledRecipe: recipe,
      );
    }))!;
    transport = _Transport();
    media = _Media();
    submissions = [];
    backCalls = 0;
    cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: () => transport,
      media: media,
      isDemo: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(
          services: services,
          isDemo: true,
          createCoordinator: () => cook,
          dinnerStatus: FakeDinnerBackend(),
          sendDinner: (request) {
            submissions.add(request);
            return Completer<DinnerMessageResult>().future;
          },
          onBackToPantry: () => backCalls++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await cook.connect();
    await tester.pumpAndSettle();
    expect(cook.live.isActive, isTrue);
    expect(find.byKey(const ValueKey('meal-complete')), findsNothing);
    final total = cook.recipe.steps.length;
    for (var i = 0; i < total; i++) {
      final label = i == total - 1 ? 'Finish cooking' : 'Next step →';
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      if (i == total - 1) transport.texts.clear();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(cook.complete, isTrue);
  }

  testWidgets('finishing the last step celebrates honestly and pauses coach', (
    tester,
  ) async {
    await finishAllSteps(tester);
    final total = cook.recipe.steps.length;
    expect(find.text('You made ${cook.recipe.title}!'), findsOneWidget);
    expect(find.text('Steps completed: $total of $total'), findsOneWidget);
    expect(find.text('pantry oats'), findsOneWidget);
    expect(find.text('pantry honey'), findsOneWidget);
    expect(find.text(cook.recipe.ingredients.first.name), findsWidgets);
    expect(find.text('Rehearsal · simulated coach'), findsOneWidget);
    // The coach stopped without a final Gemini turn.
    expect(cook.live.isActive, isFalse);
    expect(media.stops, greaterThan(0));
    expect(transport.texts, isEmpty);
    expect(find.text(mealCompleteCoachNote), findsWidgets);
    // Nothing was sent automatically.
    expect(submissions, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('primary action opens the reviewed dinner-ready dialog', (
    tester,
  ) async {
    await finishAllSteps(tester);
    final button = find.byKey(const ValueKey('meal-complete-text-household'));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Dinner is ready'),
      ),
      findsOneWidget,
    );
    expect(submissions, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    expect(submissions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('secondary action opens the nearby food help sheet', (
    tester,
  ) async {
    await finishAllSteps(tester);
    final button = find.byKey(const ValueKey('meal-complete-nearby'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Find food help nearby'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cook something else returns to the pantry', (tester) async {
    await finishAllSteps(tester);
    final button = find.byKey(const ValueKey('meal-complete-cook-again'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(backCalls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
