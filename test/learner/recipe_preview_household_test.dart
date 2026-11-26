// SS-099: household allergens survive a reload. Uses shared_preferences'
// in-memory mock; no device storage is touched.

import 'dart:io';

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

  test('choices made before the saved list loads merge into it', () async {
    SharedPreferences.setMockInitialValues({
      DeviceHouseholdAllergens.storageKey: ['milk', 'egg'],
    });
    final household = DeviceHouseholdAllergens()
      ..setAllergen('peanut', true)
      ..setAllergen('egg', false);
    await household.loaded;
    await Future<void>.delayed(Duration.zero);
    expect(household.allergens, {'milk', 'peanut'});
    final again = DeviceHouseholdAllergens();
    await again.loaded;
    expect(again.allergens, {'milk', 'peanut'});
  });

  test('Android excludes app preferences from cloud backup and transfer', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    const exclude =
        '<exclude domain="sharedpref" path="FlutterSharedPreferences.xml"/>';
    expect(
      File('android/app/src/main/res/xml/backup_rules.xml').readAsStringSync(),
      contains(exclude),
    );
    final extraction = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();
    expect(RegExp(RegExp.escape(exclude)).allMatches(extraction), hasLength(2));
    expect(extraction, contains('<cloud-backup>'));
    expect(extraction, contains('<device-transfer>'));
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
