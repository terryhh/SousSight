import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/ingredient_label.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ingredientRowLabel', () {
    test('name first, then the amount', () {
      expect(
        ingredientRowLabel(
          const Ingredient(
            id: 'pb',
            name: 'Peanut butter',
            qty: 'about 2 tbsp',
          ),
        ),
        'Peanut butter · about 2 tbsp',
      );
    });

    test('optional ingredients are marked once', () {
      expect(
        ingredientRowLabel(
          const Ingredient(
            id: 'jam',
            name: 'Jam',
            qty: 'about 1 tbsp',
            optional: true,
          ),
        ),
        'Jam (optional) · about 1 tbsp',
      );
      expect(
        ingredientRowLabel(
          const Ingredient(
            id: 'x',
            name: 'Herbs (optional)',
            qty: '1 tsp',
            optional: true,
          ),
        ),
        'Herbs (optional) · 1 tsp',
      );
    });

    test('a missing amount or name leaves no stray separator', () {
      expect(
        ingredientRowLabel(const Ingredient(id: 's', name: ' Salt ', qty: ' ')),
        'Salt',
      );
      expect(
        ingredientRowLabel(const Ingredient(id: 's', name: '', qty: '1 cup')),
        '1 cup',
      );
    });
  });

  test('the sandwich checklist reads as the cook would say it', () async {
    final services = await fakeServices(recipeId: 'peanut_butter_sandwich_v1');
    final cook = CookingCoordinator(
      services: services,
      research: const FakeCookingResearchClient(),
      transportFactory: DemoLiveTransport.new,
      media: DemoLiveMedia(),
      isDemo: true,
    );
    addTearDown(cook.dispose);
    await cook.initialize();
    cook.showIngredients();
    final checklist = cook.ui.components.firstWhere(
      (c) => c['component'] == 'ingredientChecklist',
    );
    expect(
      [for (final item in checklist['items'] as List) item['label']],
      [
        'Bread · 2 slices',
        'Peanut butter · about 2 tbsp',
        'Jam (optional) · about 1 tbsp',
      ],
    );
    // Before Live connects, a visual check points to the step's own cue and
    // to Start; nothing is judged from the camera, and nothing is attributed
    // to the cook who made no choice (SS-089).
    await cook.checkNow();
    expect(cook.alert, startsWith("Compare your food with this step's cue:"));
    expect(cook.alert, endsWith('To have the coach look, tap Start first.'));
    expect(cook.alert, isNot(contains('You said')));
  });
}
