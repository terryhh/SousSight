import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soussight/kitchen/kitchen_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no saved choice reads as null', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await DeviceKitchenPreferences().readBigText(), isNull);
  });

  test('a saved choice survives a new instance on this device', () async {
    SharedPreferences.setMockInitialValues({});
    await DeviceKitchenPreferences().writeBigText(true);
    expect(await DeviceKitchenPreferences().readBigText(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(DeviceKitchenPreferences.bigTextKey), isTrue);
    await DeviceKitchenPreferences().writeBigText(false);
    expect(await DeviceKitchenPreferences().readBigText(), isFalse);
  });

  test('a value of the wrong type reads as no choice', () async {
    SharedPreferences.setMockInitialValues({
      DeviceKitchenPreferences.bigTextKey: 'yes',
    });
    expect(await DeviceKitchenPreferences().readBigText(), isNull);
  });

  test('opens the store it is given', () async {
    SharedPreferences.setMockInitialValues({
      DeviceKitchenPreferences.bigTextKey: true,
    });
    var opened = 0;
    final prefs = DeviceKitchenPreferences(
      open: () {
        opened++;
        return SharedPreferences.getInstance();
      },
    );
    expect(await prefs.readBigText(), isTrue);
    expect(opened, 1);
  });

  test('the in-memory store can fail reads and writes', () async {
    final prefs = InMemoryKitchenPreferences(bigText: true);
    expect(await prefs.readBigText(), isTrue);
    await prefs.writeBigText(false);
    expect(prefs.bigText, isFalse);
    expect(prefs.writes, 1);
    prefs
      ..failReads = true
      ..failWrites = true;
    await expectLater(prefs.readBigText(), throwsStateError);
    await expectLater(prefs.writeBigText(true), throwsStateError);
    expect(prefs.writes, 1);
  });
}
