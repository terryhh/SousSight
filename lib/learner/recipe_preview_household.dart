// The household's allergens, kept on this device across launches (SS-099).
// On web `shared_preferences` writes `localStorage`, on Android
// SharedPreferences, on iOS NSUserDefaults. The list never leaves the
// device: it is not put in a model request, a ledger entry or Firestore.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../label/household_allergens.dart';
import '../label/label_check.dart' show kLabelAllergens;

/// [HouseholdAllergens] saved in `shared_preferences`. It starts empty and
/// fills in when the saved list loads; a choice the cook makes before then is
/// merged per allergen into the saved list, never replacing it. Storage
/// errors (private browsing, a full disk) leave the in-memory list working
/// for this run. On Android, app preferences are excluded from cloud backup
/// and device transfer (`res/xml/backup_rules.xml`,
/// `res/xml/data_extraction_rules.xml`).
class DeviceHouseholdAllergens extends ChangeNotifier
    implements HouseholdAllergens {
  DeviceHouseholdAllergens({Future<SharedPreferences> Function()? open})
    : _open = open ?? SharedPreferences.getInstance {
    loaded = _load();
  }

  static const storageKey = 'soussight.household.allergens';

  final Future<SharedPreferences> Function() _open;
  final Set<String> _allergens = {};

  /// Choices made before the saved list loaded: allergen → present.
  final Map<String, bool> _pending = {};
  bool _loaded = false;
  bool _disposed = false;

  /// Completes when the saved list has been read (or could not be).
  late final Future<void> loaded;

  Future<void> _load() async {
    try {
      final saved = (await _open()).getStringList(storageKey) ?? const [];
      if (_disposed) return;
      _allergens
        ..clear()
        ..addAll(saved.where(kLabelAllergens.contains));
      for (final MapEntry(key: allergen, value: present) in _pending.entries) {
        present ? _allergens.add(allergen) : _allergens.remove(allergen);
      }
      if (_pending.isNotEmpty) _save();
      _pending.clear();
      notifyListeners();
    } catch (_) {
      // Unavailable storage: keep the in-memory list.
    } finally {
      _loaded = true;
    }
  }

  @override
  Set<String> get allergens => Set.unmodifiable(_allergens);

  @override
  void setAllergen(String allergen, bool present) {
    if (!kLabelAllergens.contains(allergen)) return;
    // Before the saved list loads, every choice is kept, even one that does
    // not change the (still empty) local set, and merged in on load.
    if (!_loaded) _pending[allergen] = present;
    final changed = present
        ? _allergens.add(allergen)
        : _allergens.remove(allergen);
    if (!changed) return;
    notifyListeners();
    if (_loaded) _save();
  }

  void _save() {
    final value = [
      for (final a in kLabelAllergens)
        if (_allergens.contains(a)) a,
    ];
    _open().then((prefs) => prefs.setStringList(storageKey, value)).ignore();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
