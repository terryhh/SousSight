// The household's allergens for label check. Kept on this device only: they
// are never put in a model request, a ledger entry or Firestore. The label
// check compares the model's answer against them locally.

import 'package:flutter/foundation.dart';

import 'label_check.dart';

abstract class HouseholdAllergens implements Listenable {
  /// Members of [kLabelAllergens].
  Set<String> get allergens;

  /// Ignores anything not in [kLabelAllergens].
  void setAllergen(String allergen, bool present);
}

/// For the life of the app. Persisting across launches needs a local storage
/// package (e.g. shared_preferences), which is a root `pubspec.yaml` change
/// for the integration owner; implement [HouseholdAllergens] over it then.
class InMemoryHouseholdAllergens extends ChangeNotifier
    implements HouseholdAllergens {
  InMemoryHouseholdAllergens([Iterable<String> initial = const []])
    : _allergens = {
        for (final a in initial)
          if (kLabelAllergens.contains(a)) a,
      };

  final Set<String> _allergens;

  @override
  Set<String> get allergens => Set.unmodifiable(_allergens);

  @override
  void setAllergen(String allergen, bool present) {
    if (!kLabelAllergens.contains(allergen)) return;
    final changed = present
        ? _allergens.add(allergen)
        : _allergens.remove(allergen);
    if (changed) notifyListeners();
  }
}
