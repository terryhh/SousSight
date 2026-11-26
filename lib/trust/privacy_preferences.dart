// Per-feature "keep on this device" switches (SS-070).
//
// [PrivacyPreferences] is what the dispatcher reads as `PrivacySettings`
// (live, never cached) and what the On-device AI sheet writes.

import 'package:flutter/foundation.dart';

import '../ai/hybrid/hybrid_types.dart';

/// The features a cook can pin to this device, in display order.
const List<({String feature, String label, String detail})> privacyFeatures = [
  (
    feature: 'pantry_scan',
    label: 'Pantry scan',
    detail: 'Photos and typed lists of what you have.',
  ),
  (
    feature: 'recipe_draft',
    label: 'Recipe draft',
    detail: 'Turning your confirmed items into a recipe.',
  ),
  (
    feature: 'local_watch',
    label: 'Watch my food',
    detail: 'Camera checks for a visible change.',
  ),
  (
    feature: 'coach_lite',
    label: 'Questions to Coach Lite',
    detail:
        'Typed questions answered without the Live coach. This switch '
        "doesn't cover Live chat or the Research button.",
  ),
  (
    feature: 'label_check',
    label: 'Label check',
    detail: 'Reading allergen statements on packaging.',
  ),
];

abstract class PrivacyPreferences implements PrivacySettings, Listenable {
  void setLocalOnly(String feature, bool value);
}

/// In-memory preferences. Persistence is an integration concern; this keeps
/// the switches for the life of the app.
class InMemoryPrivacyPreferences extends ChangeNotifier
    implements PrivacyPreferences {
  InMemoryPrivacyPreferences([Set<String> localOnly = const {}])
    : _localOnly = {...localOnly};

  final Set<String> _localOnly;

  @override
  bool localOnly(String feature) => _localOnly.contains(feature);

  @override
  void setLocalOnly(String feature, bool value) {
    final changed = value
        ? _localOnly.add(feature)
        : _localOnly.remove(feature);
    if (changed) notifyListeners();
  }
}
