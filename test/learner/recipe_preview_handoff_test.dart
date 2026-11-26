// SS-099: the pantry hand-off persists the same ingredient identity the
// recipe preview shows, and a completed check (even an empty one) starts a
// fresh session. In-memory services only.

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/recipe_preview_data.dart';
import 'package:soussight/pantry/pantry_handoff.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Recipe> byId;
  late AppServices services;
  late String uid;

  setUp(() async {
    byId = {for (final r in await loadRecipeCatalog()) r.id: r};
    services = await fakeServices();
    uid = await services.auth.signInLearner();
  });

  Future<Map<String, IngredientStatus>> saved(Recipe recipe) async =>
      (await services.sessions.createOrResume(uid, recipe)).ingredients;

  test('"corn starch" never persists corn; the saved session matches the '
      'preview exactly', () async {
    final salsa = byId['black_bean_corn_salsa_v1']!;
    const items = ['corn starch', 'canned black beans', 'limes'];
    await applyPantryHandoff(
      services,
      salsa,
      const PantryHandoff(confirmedItems: items),
    );
    final preview = previewIngredients(salsa, items, pantryChecked: true);
    expect(await saved(salsa), {
      for (final i in preview.have) i.id: IngredientStatus.have,
    });
    expect((await saved(salsa)).keys, unorderedEquals(['black_beans', 'lime']));
  });

  test('"Mayonnaise" persists the mayo ingredient', () async {
    final wrap = byId['chickpea_wrap_v1']!;
    await applyPantryHandoff(
      services,
      wrap,
      const PantryHandoff(confirmedItems: ['Mayonnaise']),
    );
    expect(await saved(wrap), {'mayo': IngredientStatus.have});
  });

  test('a completed check with nothing confirmed clears earlier have marks; '
      'only a skip keeps the earlier session', () async {
    final sandwich = byId['peanut_butter_sandwich_v1']!;
    await applyPantryHandoff(
      services,
      sandwich,
      const PantryHandoff(confirmedItems: ['bread']),
    );
    final first = await services.sessions.createOrResume(uid, sandwich);
    expect(first.ingredients, {'bread': IngredientStatus.have});

    await applyPantryHandoff(services, sandwich, const PantryHandoff.skipped());
    final afterSkip = await services.sessions.createOrResume(uid, sandwich);
    expect(afterSkip.id, first.id);
    expect(afterSkip.ingredients, {'bread': IngredientStatus.have});

    await applyPantryHandoff(services, sandwich, const PantryHandoff());
    final afterEmpty = await services.sessions.createOrResume(uid, sandwich);
    expect(afterEmpty.id, isNot(first.id));
    expect(afterEmpty.ingredients, isEmpty);
    expect(afterEmpty.confirmedFacts, isEmpty);
  });

  test('a skip carries no draft legs or items', () {
    const skip = PantryHandoff.skipped();
    expect(skip.skipped, isTrue);
    expect(skip.confirmedItems, isEmpty);
    expect(skip.draftLegs, isEmpty);
    expect(const PantryHandoff().skipped, isFalse);
  });
}
