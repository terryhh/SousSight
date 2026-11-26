import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/label/household_allergens.dart';
import 'package:soussight/label/label_check.dart';
import 'package:soussight/label/label_check_controller.dart';
import 'package:soussight/label/label_check_sheet.dart';
import 'package:soussight/trust/privacy_preferences.dart';

import 'label_fakes.dart';

void main() {
  late FakeHybridDispatcher dispatcher;
  late InMemoryHouseholdAllergens household;
  late ManualConsentGate gate;

  LabelCheckController make(HybridCapabilities caps) => LabelCheckController(
    dispatcher: dispatcher,
    privacy: InMemoryPrivacyPreferences(),
    household: household,
    capabilities: () async => caps,
    sessionId: 's1',
    consentGate: gate,
    cloudRoutes: const CloudRoutes({CloudRoute.hybridFallback}),
  );

  setUp(() {
    dispatcher = FakeHybridDispatcher();
    household = InMemoryHouseholdAllergens(['peanut']);
    gate = ManualConsentGate();
  });

  Future<void> pump(
    WidgetTester tester,
    LabelCheckController c, {
    Future<Uint8List?> Function()? takePhoto,
  }) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LabelCheckSheet(
            controller: c,
            takePhoto: takePhoto ?? () async => fakeJpeg(),
          ),
        ),
      ),
    );
  }

  void expectNoSafetyClaim(WidgetTester tester) {
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      final value = (text.data ?? '').toLowerCase();
      expect(value, isNot(contains('safe')), reason: value);
      expect(value, isNot(contains('allergen-free')), reason: value);
      expect(value, isNot(contains('free of')), reason: value);
    }
  }

  testWidgets('readable label: household match is prominent, with legs', (
    tester,
  ) async {
    final c = make(webCaps);
    addTearDown(c.dispose);
    dispatcher.enqueue(readableWithPeanut);
    await pump(tester, c);

    await tester.tap(find.byKey(const ValueKey('label-take-photo')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('label-matches')), findsOneWidget);
    expect(find.text('On your household list: peanut'), findsOneWidget);
    expect(find.text('The label mentions: milk, peanut.'), findsOneWidget);
    expect(find.text(kReadItYourselfWording), findsOneWidget);
    expect(find.textContaining('Contains: milk, peanuts.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('inference-source-badge')),
      findsOneWidget,
    );
    expect(find.text('On this device'), findsOneWidget);
    expectNoSafetyClaim(tester);
  });

  testWidgets('unreadable label uses the abstaining wording', (tester) async {
    final c = make(webCaps);
    addTearDown(c.dispose);
    dispatcher.enqueue('not json at all');
    await pump(tester, c);

    await tester.tap(find.byKey(const ValueKey('label-take-photo')));
    await tester.pumpAndSettle();

    expect(find.text(kUnreadableWording), findsOneWidget);
    expect(find.byKey(const ValueKey('label-matches')), findsNothing);
    expect(find.byKey(const ValueKey('label-mentions')), findsNothing);
    expectNoSafetyClaim(tester);
  });

  testWidgets('household picker toggles allergens locally', (tester) async {
    final c = make(webCaps);
    addTearDown(c.dispose);
    await pump(tester, c);
    expect(find.text(kHouseholdStaysHereWording), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('household-sesame')));
    await tester.pump();
    expect(household.allergens, {'peanut', 'sesame'});
    expect(dispatcher.tasks, isEmpty);
  });

  testWidgets('iOS: choice card, then the typed path', (tester) async {
    final c = make(iosCaps);
    addTearDown(c.dispose);
    await pump(tester, c);

    await tester.tap(find.byKey(const ValueKey('label-take-photo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('label-choice')), findsOneWidget);
    expect(find.byKey(const ValueKey('label-choice-cloud')), findsOneWidget);
    expect(dispatcher.tasks, isEmpty);

    await tester.tap(find.byKey(const ValueKey('label-choice-type')));
    await tester.pumpAndSettle();
    dispatcher.enqueue(unreadableJson);
    await tester.enterText(
      find.byKey(const ValueKey('label-typed-field')),
      'Sugar, cocoa butter',
    );
    await tester.tap(find.byKey(const ValueKey('label-check-typed')));
    await tester.pumpAndSettle();

    expect(dispatcher.tasks.single.hasImage, isFalse);
    expect(find.text(kUnreadableWording), findsOneWidget);
  });

  testWidgets('closing the sheet drops a late result', (tester) async {
    final c = make(webCaps);
    addTearDown(c.dispose);
    dispatcher.delay = const Duration(milliseconds: 50);
    dispatcher.enqueue(readableWithPeanut);
    await pump(tester, c);

    await tester.tap(find.byKey(const ValueKey('label-take-photo')));
    await tester.pump();
    await tester.pump();
    expect(c.phase, LabelCheckPhase.checking);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(c.result, isNull);
    expect(dispatcher.cancelledOperations, ['op-1']);
  });

  testWidgets('a photo taken under an old session is never sent', (
    tester,
  ) async {
    final c = make(webCaps);
    addTearDown(c.dispose);
    final camera = Completer<Uint8List?>();
    dispatcher.enqueue(readableWithPeanut);
    await pump(tester, c, takePhoto: () => camera.future);

    await tester.tap(find.byKey(const ValueKey('label-take-photo')));
    await tester.pump();
    expect(find.text('Taking the photo…'), findsOneWidget);
    c.setSession('s2');
    camera.complete(fakeJpeg());
    await tester.pumpAndSettle();

    expect(dispatcher.tasks, isEmpty);
    expect(find.byKey(const ValueKey('label-mentions')), findsNothing);
  });
}
