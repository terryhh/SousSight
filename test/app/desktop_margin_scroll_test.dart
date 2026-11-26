// The wheel scrolls the page over the side margins on a wide desktop window,
// not only over the centred content column (Terry, SS-089). Fakes only.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/centered_scroll.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/trust/ledger_view.dart';
import 'package:soussight/trust/ledger_source.dart';

Future<void> wide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<double> wheelAtMargin(WidgetTester tester, Finder scrollable) async {
  final state = tester.state<ScrollableState>(scrollable);
  final before = state.position.pixels;
  tester.binding.handlePointerEvent(
    const PointerScrollEvent(
      position: Offset(20, 400),
      scrollDelta: Offset(0, 300),
    ),
  );
  await tester.pumpAndSettle();
  return state.position.pixels - before;
}

void main() {
  test('centeredSide keeps the gutter on phones and centres on desktop', () {
    expect(centeredSide(412, maxWidth: 720, gutter: 16), 16);
    expect(centeredSide(1280, maxWidth: 720, gutter: 16), 296);
    expect(centeredSide(1280, maxWidth: 1320), 0);
    expect(centeredSide(1920, maxWidth: 1320), 300);
  });

  testWidgets('pantry: the wheel scrolls at x=20 on a 1280 px window', (
    tester,
  ) async {
    await wide(tester);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryScreen(
          recipes: recipes,
          client: const FakePantryClient(delay: Duration.zero),
          onChooseRecipe: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = find.descendant(
      of: find.byKey(const ValueKey('pantry-scroll')),
      matching: find.byType(Scrollable),
    );
    expect(await wheelAtMargin(tester, scroll.first), greaterThan(0));
    // The content column is still centred and 688 px wide.
    final hero = tester.getRect(find.text('What did you get from the pantry?'));
    expect(hero.left, greaterThan(250));
  });

  testWidgets('cooking: the wheel scrolls at x=20 on a 1920 px window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(fakeServices))!;
    await tester.pumpWidget(
      CookingApp(
        services: services,
        isDemo: true,
        hybrid: RehearsalHybridRuntime.create(
          inference: RehearsalHybridInference(answerDelay: Duration.zero),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = find.descendant(
      of: find.byKey(const ValueKey('cooking-scroll')),
      matching: find.byType(Scrollable),
    );
    expect(await wheelAtMargin(tester, scroll.first), greaterThan(0));
    final dock = tester.getRect(
      find.byKey(const ValueKey('cooking-control-dock')),
    );
    expect(dock.width, 1320);
  });

  testWidgets('sheets span the window and scroll at the margin', (
    tester,
  ) async {
    await wide(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showLedgerSheet(context, ledger: ListLedgerSource()),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final sheet = tester.getRect(find.byKey(const ValueKey('ledger-view')));
    expect(sheet.width, 1280);
    final scroll = find.descendant(
      of: find.byKey(const ValueKey('ledger-view')),
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scroll.first);
    final before = state.position.pixels;
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: Offset(20, sheet.top + 200),
        scrollDelta: const Offset(0, 300),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.position.pixels, greaterThan(before));
  });
}
