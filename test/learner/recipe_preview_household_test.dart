// SS-099: household allergens survive a reload. Uses shared_preferences'
// in-memory mock; no device storage is touched.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soussight/learner/recipe_preview_household.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a saved choice survives a restart; unknown values are ignored',
    () async {
      SharedPreferences.setMockInitialValues({
        DeviceHouseholdAllergens.storageKey: ['milk', 'glitter'],
      });
      final first = DeviceHouseholdAllergens();
      var notified = 0;
      first.addListener(() => notified++);
      await first.loaded;
      expect(first.allergens, {'milk'});
      expect(notified, 1);

      first
        ..setAllergen('egg', true)
        ..setAllergen('milk', false)
        ..setAllergen('glitter', true) // not a label allergen: ignored
        ..setAllergen('egg', true); // no change: no write, no notify
      await Future<void>.delayed(Duration.zero);
      expect(notified, 3);

      // "Restart": a new instance reads what the first one saved.
      final second = DeviceHouseholdAllergens();
      await second.loaded;
      expect(second.allergens, {'egg'});
      expect(
        (await SharedPreferences.getInstance()).getStringList(
          DeviceHouseholdAllergens.storageKey,
        ),
        ['egg'],
      );
    },
  );

  test('a choice made before the saved list loads wins and is saved', () async {
    SharedPreferences.setMockInitialValues({
      DeviceHouseholdAllergens.storageKey: ['milk'],
    });
    final household = DeviceHouseholdAllergens()..setAllergen('peanut', true);
    await household.loaded;
    await Future<void>.delayed(Duration.zero);
    expect(household.allergens, {'peanut'});
    final again = DeviceHouseholdAllergens();
    await again.loaded;
    expect(again.allergens, {'peanut'});
  });

  test('unavailable storage keeps working in memory', () async {
    final household = DeviceHouseholdAllergens(
      open: () async => throw StateError('storage unavailable'),
    );
    await household.loaded;
    expect(household.allergens, isEmpty);
    household.setAllergen('soy', true);
    await Future<void>.delayed(Duration.zero);
    expect(household.allergens, {'soy'});
  });

  test('disposing before the load finishes does not notify', () async {
    SharedPreferences.setMockInitialValues({
      DeviceHouseholdAllergens.storageKey: ['fish'],
    });
    final household = DeviceHouseholdAllergens();
    household.dispose();
    await household.loaded;
    expect(household.allergens, isEmpty);
  });
}
