import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/pantry/pantry_handoff.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/app/services_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every bundled recipe loads with consistent references', () async {
    final recipes = await loadRecipeCatalog();
    expect(recipes.map((r) => r.id), kBundledRecipeIds);
    for (final recipe in recipes) {
      final stepIds = recipe.steps.map((s) => s.id).toSet();
      expect(stepIds.length, recipe.steps.length, reason: recipe.id);
      for (final checkpoint in recipe.checkpoints) {
        expect(stepIds, contains(checkpoint.stepId), reason: checkpoint.id);
        expect(
          recipe.step(checkpoint.stepId).checkpointId,
          checkpoint.id,
          reason: checkpoint.id,
        );
        for (final adjustment in checkpoint.allowedAdjustments) {
          expect(recipe.adjustmentLabels, contains(adjustment));
        }
      }
    }
  });

  test(
    'black bean salsa has a real visible cue and a real meld timer',
    () async {
      final salsa = (await loadRecipeCatalog()).firstWhere(
        (r) => r.id == 'black_bean_corn_salsa_v1',
      );
      final dice = salsa.checkpoints.single;
      expect(dice.targetImageAsset, isEmpty);
      expect(dice.cues, contains('pieces about the size of a corn kernel'));
      expect(salsa.step('dice').cue, contains('no large chunks'));
      expect(salsa.step('meld').timerSeconds, 300);
      expect(salsa.steps.where((s) => s.timerSeconds != null), hasLength(1));
      expect(salsa.reviewedSubstitutions, isEmpty);
      expect(salsa.ingredient('cilantro').optional, isTrue);
      expect(salsa.ingredient('tortillas').allergens, ['wheat']);
      expect(
        salsa.ingredients
            .where((i) => i.id != 'tortillas')
            .expand((i) => i.allergens),
        isEmpty,
      );
    },
  );

  test('deep link accepts only bundled recipe IDs', () {
    expect(
      deepLinkRecipeId(
        url: Uri.parse('https://x.test/?recipe=chickpea_wrap_v1'),
      ),
      'chickpea_wrap_v1',
    );
    expect(
      deepLinkRecipeId(url: Uri.parse('https://x.test/?recipe=../etc')),
      isNull,
    );
    expect(deepLinkRecipeId(url: Uri.parse('https://x.test/')), isNull);
  });

  test('pantry items map to recipe ingredient IDs by name', () async {
    final recipes = await loadRecipeCatalog();
    final salsa = recipes.last;
    final sandwich = recipes.first;
    expect(matchIngredientId('canned black beans', salsa), 'black_beans');
    expect(matchIngredientId('Corn', salsa), 'corn');
    expect(matchIngredientId('2 tomatoes', salsa), 'tomato');
    expect(matchIngredientId('limes', salsa), 'lime');
    expect(matchIngredientId('rice', salsa), isNull);
    expect(matchIngredientId('bread', sandwich), 'bread');
    expect(
      matchIngredientId('creamy peanut butter', sandwich),
      'peanut_butter',
    );
    expect(matchIngredientId('butter', sandwich), isNull);
  });

  test('pantry handoff seeds the same learner+recipe session', () async {
    final recipes = await loadRecipeCatalog();
    final salsa = recipes.last;
    // Avoid constructing AppServices directly so legacy fields can change.
    final services = await fakeServices();
    final sessions = services.sessions;
    await applyPantryHandoff(
      services,
      salsa,
      const PantryHandoff(
        confirmedItems: ['canned black beans', 'canned corn', 'rice'],
        answer: (question: 'Chips?', answer: 'Yes, tortilla chips'),
      ),
    );
    final uid = await services.auth.signInLearner();
    final session = await sessions.createOrResume(uid, salsa);
    expect(session.recipeId, salsa.id);
    expect(session.ingredients, {
      'black_beans': IngredientStatus.have,
      'corn': IngredientStatus.have,
    });
    expect(session.confirmedFacts, [
      'Pantry has (confirmed by the cook): canned black beans, canned corn, rice.',
      'Chips? Answer from cook: Yes, tortilla chips',
    ]);
    // The sandwich session is untouched.
    final sandwich = await sessions.createOrResume(uid, recipes.first);
    expect(sandwich.ingredients, isEmpty);
  });
}
