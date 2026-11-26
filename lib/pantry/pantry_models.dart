import 'dart:convert';
import 'dart:typed_data';

import '../ai/hybrid/hybrid_types.dart' show InferenceLeg;

enum PantryConfidence { low, medium, high }

/// A candidate ingredient. Only the cook can confirm it is really there.
class PantryItem {
  const PantryItem({required this.name, required this.confidence});
  final String name;
  final PantryConfidence confidence;
}

class PantryMeal {
  const PantryMeal({
    required this.recipeId,
    required this.why,
    required this.matched,
    required this.missing,
  });
  final String recipeId;
  final String why;
  final List<String> matched;
  final List<String> missing;
}

class PantryResult {
  const PantryResult({
    required this.items,
    required this.meals,
    this.question,
    this.simulated = false,
    this.legs = const [],
    this.notice,
  });
  final List<PantryItem> items;
  final List<PantryMeal> meals;
  final String? question;

  /// True for the rehearsal client. The UI must label simulated results.
  final bool simulated;

  /// Every inference attempt behind this result, in order (DESIGN.md §5). A
  /// scan built from a local photo leg and a cloud voice leg carries both;
  /// the screen shows each one, never one merged badge.
  final List<InferenceLeg> legs;

  /// Cook-facing note about an input that could not be used, for example a
  /// voice clip whose list could not be read. Null when everything was used.
  final String? notice;

  PantryResult copyWith({
    List<PantryItem>? items,
    List<InferenceLeg>? legs,
    String? notice,
  }) => PantryResult(
    items: items ?? this.items,
    meals: meals,
    question: question,
    simulated: simulated,
    legs: legs ?? this.legs,
    notice: notice ?? this.notice,
  );
}

/// What the cook shared. Media stays in memory for one request only.
class PantryInput {
  const PantryInput({this.text = '', this.photoJpeg, this.audioWav});
  final String text;
  final Uint8List? photoJpeg;
  final Uint8List? audioWav;

  bool get isEmpty =>
      text.trim().isEmpty &&
      (photoJpeg?.isEmpty ?? true) &&
      (audioWav?.isEmpty ?? true);
}

/// The response schema is a generation aid, not a trust boundary. This rejects
/// malformed output and any recipe ID outside the reviewed catalog.
PantryResult parsePantryResult(String? text, Set<String> allowedRecipeIds) {
  if (text == null || text.isEmpty || text.length > 16000) {
    throw const FormatException('Missing or oversized pantry response');
  }
  final data = jsonDecode(text);
  if (data is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object');
  }
  final rawItems = data['items'];
  final rawMeals = data['meals'];
  if (rawItems is! List || rawMeals is! List) {
    throw const FormatException('items and meals are required lists');
  }
  final items = _items(rawItems);
  final meals = <PantryMeal>[];
  final seenMeals = <String>{};
  for (final raw in rawMeals.take(10)) {
    // Only reviewed catalog recipes are ever shown; anything else is dropped.
    if (raw is! Map) continue;
    final id = raw['recipeId'];
    if (id is! String || !allowedRecipeIds.contains(id)) continue;
    if (!seenMeals.add(id)) continue;
    meals.add(
      PantryMeal(
        recipeId: id,
        why: raw['why'] is String ? _text(raw['why'], 400) : '',
        matched: _strings(raw['matched']),
        missing: _strings(raw['missing']),
      ),
    );
  }
  final question = data['question'];
  if (question != null && question is! String) {
    throw const FormatException('Invalid question');
  }
  final trimmed = (question as String?)?.trim();
  return PantryResult(
    items: items,
    meals: List.unmodifiable(meals),
    question: trimmed == null || trimmed.isEmpty ? null : _text(trimmed, 300),
  );
}

/// Parses the items-only answer to a voice clip (`{"items": [...]}`). It is
/// validated on its own, before any ranking, so a bad voice answer can be
/// dropped without losing the photo or typed list.
List<PantryItem> parsePantryItems(String? text) {
  if (text == null || text.isEmpty || text.length > 8000) {
    throw const FormatException('Missing or oversized voice item list');
  }
  final data = jsonDecode(text);
  if (data is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object');
  }
  final rawItems = data['items'];
  if (rawItems is! List) throw const FormatException('items is required');
  return _items(rawItems);
}

List<PantryItem> _items(List<Object?> rawItems) {
  final items = <PantryItem>[];
  final seenItems = <String>{};
  for (final raw in rawItems.take(30)) {
    // Skip unusable entries instead of discarding the whole answer.
    if (raw is! Map || raw['name'] is! String) continue;
    final name = _text(raw['name'], 80);
    if (name.isEmpty) continue;
    final level = '${raw['confidence'] ?? ''}'.trim().toLowerCase();
    final confidence = PantryConfidence.values.firstWhere(
      (value) => value.name == level,
      orElse: () => PantryConfidence.low,
    );
    if (seenItems.add(name.toLowerCase())) {
      items.add(PantryItem(name: name, confidence: confidence));
    }
  }
  return List.unmodifiable(items);
}

/// Display text from the model. Structure is strict (must be a string), but
/// length is not a validity signal: models often copy long catalog ingredient
/// names or write a long reason, so over-long text is shortened, not rejected.
String _text(Object? value, int maxLength) {
  if (value is! String) throw const FormatException('Invalid text field');
  final text = value.trim();
  if (text.length <= maxLength) return text;
  return '${text.substring(0, maxLength - 1).trimRight()}…';
}

List<String> _strings(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('Invalid string list');
  return List.unmodifiable([
    for (final item in value.take(20))
      if (_text(item, 80) case final text when text.isNotEmpty) text,
  ]);
}
