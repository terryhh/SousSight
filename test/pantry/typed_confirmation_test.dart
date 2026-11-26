// Codex review of #221: only an item that IS what the cook typed starts
// confirmed; a shared word or substring never confirms another food.

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_ui.dart';

PantryResult _result(List<(String, PantryConfidence)> items) => PantryResult(
  items: [for (final (n, c) in items) PantryItem(name: n, confidence: c)],
  meals: const [],
);

List<String> _confirmed(String typed, List<(String, PantryConfidence)> items) {
  final ui = PantryUiController(onChooseMeal: (_) {});
  addTearDown(ui.dispose);
  ui.show(_result(items), const <Recipe>[], typed: typed);
  return ui.confirmedItems;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a different food sharing a word is never auto-confirmed', () {
    expect(
      _confirmed('sunflower seed butter', [
        ('peanut butter', PantryConfidence.high),
      ]),
      isEmpty,
    );
    expect(
      _confirmed('oat milk', [('whole milk', PantryConfidence.high)]),
      isEmpty,
    );
    expect(_confirmed('eggplant', [('egg', PantryConfidence.low)]), isEmpty);
  });

  test('the draft-guard repro: "coconut milk, rice" confirms only rice', () {
    expect(
      _confirmed('coconut milk, rice', [
        ('milk', PantryConfidence.high),
        ('rice', PantryConfidence.high),
      ]),
      ['rice'],
    );
  });

  test('the same food in other words is confirmed', () {
    expect(
      _confirmed('2 tomatoes, 2 cans black beans, berries', [
        ('tomato', PantryConfidence.medium),
        ('canned black beans', PantryConfidence.high),
        ('berry', PantryConfidence.low),
        ('white beans', PantryConfidence.high),
      ]),
      ['tomato', 'canned black beans', 'berry'],
    );
  });

  test('pantryItemKey keeps colours and varieties', () {
    expect(pantryItemKey('Canned Black Beans'), 'black bean');
    expect(pantryItemKey('a jar of peanut butter'), 'peanut butter');
    expect(pantryItemKey('glass'), 'glass');
    expect(pantrySameItem('white beans', 'black beans'), isFalse);
    expect(pantrySameItem('', 'rice'), isFalse);
  });
}
