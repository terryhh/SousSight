import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'new cook preserves previous facts, ingredients, completion and timer',
    () async {
      final recipe = await loadBundledRecipe();
      final repository = FakeSessionRepository();
      final previous = await repository.createOrResume('cook', recipe);
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      await repository.update(
        previous.id,
        (s) => s.copyWith(
          currentStepId: recipe.steps.last.id,
          completedStepIds: recipe.steps.map((s) => s.id).toList(),
          confirmedFacts: ['No jam this time.'],
          ingredients: {'bread': IngredientStatus.have},
          timerId: 'old-timer',
          timerLabel: 'My reminder',
          timerDeadline: deadline,
          revision: 4,
        ),
      );
      final fresh = await repository.createNew('cook', recipe);
      expect(fresh.id, isNot(previous.id));
      expect(fresh.currentStepId, recipe.steps.first.id);
      expect(fresh.completedStepIds, isEmpty);
      expect(fresh.confirmedFacts, isEmpty);
      expect(fresh.ingredients, isEmpty);
      expect(fresh.substitutions, isEmpty);
      expect(fresh.timerDeadline, isNull);
      expect(fresh.timerId, isNull);
      expect(fresh.revision, 0);
      expect((await repository.createOrResume('cook', recipe)).id, fresh.id);
      final preserved = await repository.watch(previous.id).first;
      expect(preserved.confirmedFacts, ['No jam this time.']);
      expect(preserved.completedStepIds, hasLength(recipe.steps.length));
      expect(preserved.ingredients['bread'], IngredientStatus.have);
      expect(preserved.timerDeadline, deadline);
      expect(preserved.revision, 4);
    },
  );

  test(
    'resume orders by creation, not updates, and isolates learner and recipe',
    () async {
      final recipe = await loadBundledRecipe();
      final otherRecipe = await loadBundledRecipe('chickpea_wrap_v1');
      final repository = FakeSessionRepository();
      final oldest = await repository.createNew('cook', recipe);
      final newest = await repository.createNew('cook', recipe);
      final otherCook = await repository.createNew('someone-else', recipe);
      final otherMeal = await repository.createNew('cook', otherRecipe);
      await repository.update(
        oldest.id,
        (s) => s.copyWith(
          updatedAt: DateTime.now().add(const Duration(days: 1)),
          confirmedFacts: ['Late update to previous cook.'],
        ),
      );
      expect((await repository.createOrResume('cook', recipe)).id, newest.id);
      expect(
        (await repository.createOrResume('someone-else', recipe)).id,
        otherCook.id,
      );
      expect(
        (await repository.createOrResume('cook', otherRecipe)).id,
        otherMeal.id,
      );
    },
  );
  test(
    'equal creation times use descending document ID consistently',
    () async {
      final recipe = await loadBundledRecipe();
      final repository = FakeSessionRepository();
      final first = await repository.createNew('cook', recipe);
      final second = await repository.createNew('cook', recipe);
      // Fixture-only timestamp normalization exercises the Firestore ID tie-break.
      await repository.update(
        second.id,
        (s) => CookingSession.fromMap(s.id, {
          ...s.toMap(),
          'createdAt': first.createdAt,
        }),
      );
      final expectedId = [first.id, second.id]..sort();
      expect(
        (await repository.createOrResume('cook', recipe)).id,
        expectedId.last,
      );
    },
  );
}
