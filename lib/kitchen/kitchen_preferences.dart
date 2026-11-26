// Kitchen-mode settings kept on this device (SS-107). Nothing here leaves the
// device: on web `shared_preferences` writes `localStorage`, on Android
// SharedPreferences, on iOS NSUserDefaults.

import 'package:shared_preferences/shared_preferences.dart';

abstract class KitchenPreferences {
  /// The saved "Big text" choice, or null if the cook never chose.
  Future<bool?> readBigText();

  Future<void> writeBigText(bool value);
}

/// [KitchenPreferences] in `shared_preferences`.
class DeviceKitchenPreferences implements KitchenPreferences {
  DeviceKitchenPreferences({Future<SharedPreferences> Function()? open})
    : _open = open ?? SharedPreferences.getInstance;

  static const bigTextKey = 'soussight.kitchen.bigText';

  final Future<SharedPreferences> Function() _open;

  @override
  Future<bool?> readBigText() async {
    final value = (await _open()).get(bigTextKey);
    // Anything other than a bool was not written by us: no choice made.
    return value is bool ? value : null;
  }

  @override
  Future<void> writeBigText(bool value) async {
    await (await _open()).setBool(bigTextKey, value);
  }
}

/// For tests and builds without storage. [failReads] / [failWrites] simulate
/// unavailable storage (private browsing, a full disk).
class InMemoryKitchenPreferences implements KitchenPreferences {
  InMemoryKitchenPreferences({
    this.bigText,
    this.failReads = false,
    this.failWrites = false,
  });

  bool? bigText;
  bool failReads;
  bool failWrites;
  int writes = 0;

  @override
  Future<bool?> readBigText() async {
    if (failReads) throw StateError('storage unavailable');
    return bigText;
  }

  @override
  Future<void> writeBigText(bool value) async {
    if (failWrites) throw StateError('storage unavailable');
    writes++;
    bigText = value;
  }
}
