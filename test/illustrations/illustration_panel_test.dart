import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show HybridErrorCode;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/illustrations/illustration_controller.dart';
import 'package:soussight/illustrations/illustration_generator.dart';
import 'package:soussight/illustrations/illustration_panel.dart';
import 'package:soussight/illustrations/illustration_prompts.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

import 'fakes.dart';

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Future<void> pumpPanel(
  WidgetTester tester, {
  required Recipe recipe,
  required String stepId,
  String? sessionId = 's1',
  bool showPlate = false,
  Harness? harness,
}) => tester.pumpWidget(
  host(
    StepIllustrations(
      recipe: recipe,
      step: recipe.steps.firstWhere((s) => s.id == stepId),
      sessionId: sessionId,
      showPlate: showPlate,
      controller: harness?.controller,
    ),
  ),
);

const askLabel = 'Show me what it should look like';

void main() {
  group('reviewed recipes show their pre-made images', () {
    late List<Recipe> recipes;
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      recipes = await loadRecipeCatalog();
    });

    testWidgets('with the label and compare copy, and no cloud button', (
      tester,
    ) async {
      final wrap = recipes.firstWhere((r) => r.id == 'chickpea_wrap_v1');
      final h = Harness();
      await pumpPanel(
        tester,
        recipe: wrap,
        stepId: 'roll',
        showPlate: true,
        harness: h,
      );
      expect(
        find.byKey(const ValueKey('illustration-step_roll')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('illustration-plate')), findsOneWidget);
      expect(find.text(kIllustrationLabel), findsNWidgets(2));
      expect(find.text(kIllustrationCompareCopy), findsNWidgets(2));
      expect(find.text('The finished plate'), findsOneWidget);
      expect(find.text('What it should look like'), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.text(askLabel), findsNothing);
      expect(find.text(kIllustrationHeatCopy), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('not a photo of your food')),
        findsNWidgets(2),
      );
      // Reviewed recipes never ask the cloud.
      expect(h.consent.asks, isEmpty);
    });

    testWidgets('in rehearsal too (no hybrid services)', (tester) async {
      final pb = recipes.firstWhere((r) => r.id == 'peanut_butter_sandwich_v1');
      await pumpPanel(tester, recipe: pb, stepId: 'spread');
      expect(find.text(kIllustrationLabel), findsOneWidget);
    });
  });

  testWidgets('a draft without hybrid services shows nothing', (tester) async {
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate');
    expect(find.text(askLabel), findsNothing);
    expect(find.text(kIllustrationLabel), findsNothing);
  });

  testWidgets('a draft: ask, consent, then a labelled illustration', (
    tester,
  ) async {
    final h = Harness();
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    expect(find.text(askLabel), findsOneWidget);
    expect(
      find.text(
        'Uses Google cloud AI (fake-image-model). 4 of 4 left this cook.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(askLabel));
    await tester.pumpAndSettle();
    expect(h.consent.asks, hasLength(1));
    expect(find.text(kIllustrationLabel), findsOneWidget);
    expect(find.text(kIllustrationCompareCopy), findsOneWidget);
    expect(find.text(askLabel), findsNothing);
    expect(h.ledger.entries.single.leg.modelLabel, contains('text→image'));
  });

  testWidgets('local-only: the button is off and says it needs the cloud', (
    tester,
  ) async {
    final h = Harness(localOnly: const {'recipe_draft'});
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);
    expect(
      find.text(illustrationBlockText(IllustrationBlock.localOnly)),
      findsOneWidget,
    );
    expect(find.textContaining('need the cloud'), findsOneWidget);
  });

  testWidgets('used-up is explained', (tester) async {
    final h = Harness(cap: 0);
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    expect(
      find.text(illustrationBlockText(IllustrationBlock.capReached)),
      findsOneWidget,
    );
  });

  testWidgets('offline is explained', (tester) async {
    final h = Harness()..online = false;
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'stir', harness: h);
    expect(
      find.text(illustrationBlockText(IllustrationBlock.offline)),
      findsOneWidget,
    );
  });

  testWidgets('a build without the images route offers nothing', (
    tester,
  ) async {
    final h = Harness(routes: const {CloudRoute.research});
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('loading, then failure with a retry', (tester) async {
    final h = Harness()..generator.hold = true;
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    await tester.tap(find.text(askLabel));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('illustration-loading')), findsOneWidget);
    expect(
      find.text('Drawing an AI illustration in the cloud…'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // A step change drops the pending result and its loading notice.
    final r = draftRecipe();
    await tester.pumpWidget(
      host(
        StepIllustrations(
          recipe: r,
          step: r.steps.last,
          sessionId: 's1',
          showPlate: false,
          controller: h.controller,
        ),
      ),
    );
    h.generator.release();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('illustration-loading')), findsNothing);
    expect(find.text(kIllustrationLabel), findsNothing);

    h.generator
      ..hold = false
      ..error = const IllustrationException(HybridErrorCode.timeout, 't');
    await tester.tap(find.text(askLabel));
    await tester.pumpAndSettle();
    expect(
      find.text("Couldn't make an illustration (took too long)."),
      findsOneWidget,
    );
    h.generator.error = null;
    await tester.tap(find.text('Try again: show me what it should look like'));
    await tester.pumpAndSettle();
    expect(find.text(kIllustrationLabel), findsOneWidget);
  });

  testWidgets('while the prompt is open, it says nothing is sent yet', (
    tester,
  ) async {
    final h = Harness()..consent.gate = Completer<void>();
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    await tester.tap(find.text(askLabel));
    await tester.pump();
    expect(
      find.text('Waiting for your answer. Nothing is sent until you allow it.'),
      findsOneWidget,
    );
    expect(h.ledger.entries, isEmpty);
    h.consent.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text(kIllustrationLabel), findsOneWidget);
  });

  testWidgets('a declined prompt says nothing was sent', (tester) async {
    final h = Harness()..consent.allow = false;
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    await tester.tap(find.text(askLabel));
    await tester.pumpAndSettle();
    expect(find.text('Nothing was sent.'), findsOneWidget);
  });

  testWidgets('heated steps keep the thermometer disclaimer', (tester) async {
    final r = draftRecipe(
      steps: const [
        RecipeStep(
          id: 'toast',
          title: 'Toast',
          instruction: 'Toast the bread in a dry pan.',
          cue: 'Golden brown on both sides.',
        ),
      ],
    );
    final h = Harness();
    await pumpPanel(tester, recipe: r, stepId: 'toast', harness: h);
    await tester.tap(find.text(askLabel));
    await tester.pumpAndSettle();
    expect(find.text(kIllustrationLabel), findsOneWidget);
    expect(find.text(kIllustrationHeatCopy), findsOneWidget);
  });

  testWidgets(
    'meat: raw prep is laid out; heated steps and plate say why not',
    (tester) async {
      final r = draftRecipe(
        ingredients: const [
          Ingredient(id: 'c', name: 'Chicken thighs', qty: '2'),
          Ingredient(id: 'o', name: 'Olive oil', qty: '1 tbsp'),
        ],
        steps: const [
          RecipeStep(
            id: 'season',
            title: 'Season',
            instruction: 'Rub the chicken with olive oil.',
            cue: 'Evenly coated.',
          ),
          RecipeStep(
            id: 'sear',
            title: 'Sear',
            instruction: 'Cook them in a hot pan.',
            cue: 'Golden outside.',
          ),
        ],
      );
      final h = Harness();
      await pumpPanel(tester, recipe: r, stepId: 'season', harness: h);
      expect(find.text(askLabel), findsNothing);
      expect(find.text('Show me the ingredients laid out'), findsOneWidget);
      await tester.tap(find.text('Show me the ingredients laid out'));
      await tester.pumpAndSettle();
      expect(h.generator.prompts.single, contains('before any cooking'));
      expect(h.generator.prompts.single, isNot(contains('Evenly coated')));
      expect(find.text('The ingredients, laid out'), findsOneWidget);
      expect(find.text(kIllustrationNoDonenessCopy), findsOneWidget);

      // The heated step and the plate: no button, a reason instead.
      await tester.pumpWidget(
        host(
          StepIllustrations(
            recipe: r,
            step: r.steps.last,
            sessionId: 's1',
            showPlate: true,
            controller: h.controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OutlinedButton), findsNothing);
      expect(
        find.byKey(const ValueKey('step_sear-no-picture')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('plate-no-picture')), findsOneWidget);
      expect(find.text(kIllustrationNoDonenessCopy), findsNWidgets(2));
      expect(h.generator.prompts, hasLength(1));
    },
  );

  testWidgets('offline during consent: reconnecting offers the button again', (
    tester,
  ) async {
    final h = Harness();
    h.consent.whileOpen = () => h.online = false;
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    await tester.tap(find.text(askLabel));
    await tester.pumpAndSettle();
    expect(
      find.text(illustrationBlockText(IllustrationBlock.offline)),
      findsOneWidget,
    );
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(h.generator.prompts, isEmpty);

    // Back online: the next rebuild offers the button, with a new prompt.
    h
      ..online = true
      ..consent.whileOpen = null;
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    final button = find.byType(OutlinedButton);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(h.consent.asks, hasLength(2));
    expect(find.text(kIllustrationLabel), findsOneWidget);
  });

  testWidgets('the plate button appears on the last step', (tester) async {
    final h = Harness();
    await pumpPanel(
      tester,
      recipe: draftRecipe(),
      stepId: 'stir',
      harness: h,
      showPlate: true,
    );
    await tester.tap(find.text('Show me the finished plate'));
    await tester.pumpAndSettle();
    expect(find.text('The finished plate'), findsOneWidget);
  });

  testWidgets('no session yet: nothing is requested', (tester) async {
    final h = Harness();
    await pumpPanel(
      tester,
      recipe: draftRecipe(),
      stepId: 'grate',
      harness: h,
      sessionId: null,
    );
    await tester.tap(find.text(askLabel));
    await tester.pumpAndSettle();
    expect(h.consent.asks, isEmpty);
  });

  testWidgets('the session owns the controller: a rebuilt widget keeps the '
      'cache and the cap', (tester) async {
    final h = Harness(cap: 1);
    await pumpPanel(tester, recipe: draftRecipe(), stepId: 'grate', harness: h);
    await tester.tap(find.text(askLabel));
    await tester.pumpAndSettle();
    expect(find.text(kIllustrationLabel), findsOneWidget);
    // The widget leaves the tree (a layout change), then comes back.
    await tester.pumpWidget(host(const SizedBox()));
    await pumpPanel(
      tester,
      recipe: draftRecipe(),
      stepId: 'grate',
      harness: h,
      showPlate: true,
    );
    expect(find.text(kIllustrationLabel), findsOneWidget); // cached
    expect(
      find.text(illustrationBlockText(IllustrationBlock.capReached)),
      findsOneWidget,
    );
    expect(h.generator.prompts, hasLength(1));
    expect(h.controller.remaining, 0);
  });

  testWidgets('the label badge is plain, visible text', (tester) async {
    await tester.pumpWidget(host(const IllustrationLabelBadge()));
    expect(find.text(kIllustrationLabel), findsOneWidget);
    expect(kIllustrationLabel, 'AI illustration — not a photo of your food');
  });
}
