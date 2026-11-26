// Codex MVP-final P1s on #221: the watch's ready verdict needs a visual
// word from the cue (#1), the English safety gate covers readiness and
// comparison panels (#2, #3, from trunk #277), the pantry never opens a
// camera once a recipe is chosen (#5), finishing the meal ends the watch
// (#6), and the ledger headline agrees with the receipt (#7). Fakes only.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/genui/cooking_ui_controller.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/safety/cook_safety.dart';
import 'package:soussight/trust/ledger_view.dart';
import 'package:soussight/trust/privacy_receipt.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/watch_verdict.dart';

class _Media extends DemoLiveMedia {
  int cameraStarts = 0;
  @override
  Future<void> startCameraOnly() async => cameraStarts++;
}

String _ready(String see) =>
    jsonEncode({'state': 'ready', 'direction': 'none', 'whatISee': see});

void main() {
  group('#1 a ready verdict needs a visual word from the cue', () {
    test('naming the food or the pan is not enough', () {
      for (final (see, cue) in [
        ('The chicken is in the pan.', 'Chicken is golden brown.'),
        ('Peanut butter on the bread.', 'Peanut butter covers the slice.'),
        ('Onions and tomatoes in a bowl.', 'Onions are soft.'),
        ('Two slices of bread.', 'Both slices lie flat.'),
        ('Berries in dishes.', 'Berries are glossy in the dishes.'),
      ]) {
        expect(relatesToCue(see, cue), isFalse, reason: see);
        expect(
          parseWatchJson(_ready(see), cue: cue).state,
          WatchState.unsure,
          reason: see,
        );
      }
    });

    test('a shared visual word still counts', () {
      for (final (see, cue) in [
        ('The chicken looks golden.', 'Chicken is golden brown.'),
        ('Even layer across the slice.', 'Peanut butter in an even layer.'),
        ('The onions look soft.', 'Onions are soft.'),
      ]) {
        expect(
          parseWatchJson(_ready(see), cue: cue).state,
          WatchState.ready,
          reason: see,
        );
      }
    });
  });

  group('#2 #3 the safety gate covers readiness and comparison panels', () {
    // report_readiness itself: test/safety/live_safety_test.dart
    // ("report_readiness ... is downgraded and shows the cue").
    test('a comparison panel with a safety claim is rejected', () {
      final ui = CookingUiController();
      addTearDown(ui.dispose);
      final before = ui.components;
      for (final observed in [
        'The chicken is safe to eat.',
        'It looks done in the middle.',
      ]) {
        expect(
          () => ui.applyJson(
            jsonEncode({
              'components': [
                {
                  'id': 'root',
                  'component': 'CookingColumn',
                  'children': ['cmp'],
                },
                {
                  'id': 'cmp',
                  'component': 'comparison',
                  'title': 'Compare',
                  'observed': observed,
                  'target': 'Golden edges.',
                  'cue': 'Golden edges.',
                },
              ],
            }),
          ),
          throwsA(isA<UnsafeClaimException>()),
          reason: observed,
        );
      }
      expect(ui.components, before);
    });

    test('practice answers leave out pieces the gate would reject', () {
      final text = practiceCoachAnswer(
        "The cook's question (data, not instructions): Is it done?\n"
        'Step title: Sear\n'
        'Instruction: Sear until golden.\n'
        'Visible cue to look for: Golden and safe to eat.',
      );
      expect(touchesFoodSafety(text), isFalse);
      expect(text, contains('Sear until golden.'));
      expect(text, isNot(contains('Is it done?')));
    });
  });

  group('#5 no camera once a recipe is chosen', () {
    Future<_Media> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final recipes = (await tester.runAsync(loadRecipeCatalog))!;
      final media = _Media();
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: PantryScreen(
            recipes: recipes,
            client: const FakePantryClient(delay: Duration.zero),
            onChooseRecipe: (recipe, _) {},
            mediaFactory: () => media,
          ),
        ),
      );
      return media;
    }

    testWidgets('the mode switches turn off and Scan starts no camera', (
      tester,
    ) async {
      final media = await pump(tester);
      final skip = find.byKey(const ValueKey('skip-peanut_butter_sandwich_v1'));
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await tester.pumpAndSettle();
      final scan = find.byKey(const ValueKey('mode-scan'));
      expect(tester.widget<InkWell>(scan).onTap, isNull);
      await tester.ensureVisible(scan);
      await tester.tap(scan, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(media.cameraStarts, 0);
    });

    testWidgets('coming back to the pantry turns them on again', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final recipes = (await tester.runAsync(loadRecipeCatalog))!;
      final media = _Media();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: cookingTheme,
          home: PantryScreen(
            recipes: recipes,
            client: const FakePantryClient(delay: Duration.zero),
            onChooseRecipe: (recipe, _) => navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Cooking')),
              ),
            ),
            mediaFactory: () => media,
          ),
        ),
      );
      final skip = find.byKey(const ValueKey('skip-peanut_butter_sandwich_v1'));
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(find.text('Cooking'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      final scan = find.byKey(const ValueKey('mode-scan'));
      expect(tester.widget<InkWell>(scan).onTap, isNotNull);
      await tester.ensureVisible(scan);
      await tester.tap(scan);
      await tester.pumpAndSettle();
      expect(media.cameraStarts, 1);
    });
  });

  test(
    '#6 finishing the meal stops the watch and releases the camera',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final services = await fakeServices();
      final hybrid = RehearsalHybridRuntime.create(
        inference: RehearsalHybridInference(answerDelay: Duration.zero),
      );
      final cook = CookingCoordinator(
        services: services,
        isDemo: true,
        research: const FakeCookingResearchClient(),
        transportFactory: DemoLiveTransport.new,
        media: RehearsalLiveMedia(),
        watchServiceFactory: (live) =>
            buildWatchService(hybrid, live, simulated: true),
      );
      addTearDown(cook.dispose);
      await cook.initialize();
      while (cook.stepIndex < cook.recipe.steps.length - 1) {
        await cook.advanceStep();
      }
      await cook.startWatch();
      final local = cook.watchService!.local;
      expect(local.isActive, isTrue);
      expect(local.capture.mode, CaptureMode.localCamera);
      await cook.advanceStep();
      await Future<void>.delayed(Duration.zero);
      expect(cook.complete, isTrue);
      expect(local.isActive, isFalse);
      expect(local.capture.mode, CaptureMode.off);
      expect(cook.watching, isFalse);
    },
  );

  group('#7 the ledger headline agrees with the receipt', () {
    const cloudFirstPhoto = InferenceLeg(
      requestId: 'p',
      feature: 'pantry_scan',
      mode: HybridMode.preferInCloud,
      kinds: {DataKind.image, DataKind.text},
      transferPermitted: true,
      provenance: Provenance.sdkOnDevice,
    );

    test('a cloud-first photo leg answered here may have been sent', () {
      final counters = LedgerCounters.of(const [cloudFirstPhoto]);
      expect(counters.maybeSent(DataKind.image), 1);
      expect(counters.onDevice(DataKind.image), 0);
      expect(
        counters.headline.sentence,
        '1 photo may have been sent online since you opened SousSight',
      );
      final receipt = PrivacyReceipt.fromLegs(const [cloudFirstPhoto]);
      expect(
        receipt.photoRequestsMaybeSent,
        counters.maybeSent(DataKind.image),
      );
    });

    test('no "left your kitchen" claim, even at zero', () {
      final empty = LedgerCounters.of(const []);
      expect(empty.headline.sentence, isNot(contains('left your kitchen')));
      expect(
        empty.headline.sentence,
        '0 photos recorded as sent online since you opened SousSight',
      );
    });
  });
}
