// SS-105: the receipt sits in the meal-complete panel only when the panel is
// given this session's ledger.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/meal_complete.dart';
import 'package:soussight/trust/ledger_source.dart';
import 'package:soussight/trust/privacy_receipt_card.dart';

import 'trust_test_helpers.dart';

void main() {
  Future<CookingCoordinator> pumpPanel(
    WidgetTester tester, {
    LedgerSource? ledger,
    PrivacyReceiptBinding? receiptBinding,
  }) async {
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() async {
      final recipe = await loadBundledRecipe();
      return AppServices(
        auth: FakeAuthService(),
        recipes: FakeRecipeRepository(recipe),
        sessions: FakeSessionRepository(),
        bundledRecipe: recipe,
        clock: () => DateTime(2026, 11, 26, 19, 42),
      );
    }))!;
    final cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: DemoLiveTransport.new,
      media: DemoLiveMedia(),
      isDemo: true,
      recipe: services.bundledRecipe,
    );
    addTearDown(cook.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MealCompletePanel(
              cook: cook,
              isDemo: true,
              onTextHousehold: () {},
              onCookSomethingElse: () {},
              ledger: ledger,
              receiptBinding: receiptBinding,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return cook;
  }

  testWidgets('with a ledger, the panel prints tonight\'s receipt', (
    tester,
  ) async {
    final cook = await pumpPanel(
      tester,
      ledger: ListLedgerSource([
        leg(Provenance.simulated),
        leg(Provenance.simulated, kinds: {DataKind.image}),
      ]),
      receiptBinding: PrivacyReceiptBinding(
        session: () => 'session-1',
        clock: () => DateTime(2026, 11, 26, 19, 42),
      ),
    );
    expect(find.byKey(const ValueKey('privacy-receipt')), findsOneWidget);
    expect(find.text(cook.recipe.title), findsOneWidget);
    expect(find.text('Thu 26 Nov · 7:42 pm'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('receipt-stamp-practice')),
      findsOneWidget,
    );
    // The panel's own actions are still there, below the receipt.
    final receipt = tester.getRect(
      find.byKey(const ValueKey('privacy-receipt')),
    );
    final text = tester.getRect(
      find.byKey(const ValueKey('meal-complete-text-household')),
    );
    expect(text.top, greaterThan(receipt.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a ledger without its receipt binding prints nothing', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      ledger: ListLedgerSource([leg(Provenance.simulated)]),
    );
    expect(find.byKey(const ValueKey('privacy-receipt')), findsNothing);
  });

  testWidgets('without a ledger, no receipt and no claims', (tester) async {
    await pumpPanel(tester);
    expect(find.byKey(const ValueKey('privacy-receipt')), findsNothing);
    expect(find.text("Tonight's privacy receipt"), findsNothing);
    expect(find.byKey(const ValueKey('meal-complete')), findsOneWidget);
  });
}
