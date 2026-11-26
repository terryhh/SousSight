// The pantry (first) screen's SS-089 fixes: one calm readiness line, labelled
// header buttons, a typed list that is respected in practice mode, results
// and errors scrolled into view, a reason and source line on failures, and
// an unclipped quick-question hint. Fakes only.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_controls.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_flow.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/trust/app_readiness.dart';

const _unavailable = HybridAvailability(
  status: OnDeviceStatus.unavailable,
  reason: 'device_not_eligible',
);
const _available = HybridAvailability(status: OnDeviceStatus.available);

AppReadiness _readiness({
  HybridAvailability text = _available,
  bool online = true,
  bool cloud = false,
  HybridCapabilities caps = fakeWebCapabilities,
}) => AppReadiness.evaluate(
  ReadinessInput(
    capabilities: caps,
    text: text,
    image: text,
    camera: CameraAccess.notAsked,
    online: online,
    cloudApproved: cloud,
  ),
);

class _Throwing implements PantryClient {
  _Throwing(this.error);
  final Object error;
  @override
  Future<PantryResult> identify(PantryInput input, List<Recipe> recipes) =>
      Future.error(error);
}

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

void main() {
  group('one calm line instead of warning cards (item 6)', () {
    test('ready: nothing to say', () {
      expect(readinessCalmLine(_readiness()), isNull);
    });

    test('no AI at all: points to the recipes, calmly', () {
      final line = readinessCalmLine(_readiness(text: _unavailable))!;
      expect(line, startsWith('Pick a recipe below to start cooking.'));
      expect(line, isNot(contains('on-device AI')));
    });

    test('offline with no local model', () {
      expect(
        readinessCalmLine(_readiness(text: _unavailable, online: false)),
        startsWith("You're offline."),
      );
    });

    test('cloud is the chosen path: no definite transfer claim', () {
      final line = readinessCalmLine(
        _readiness(text: _unavailable, cloud: true),
      )!;
      expect(line, contains("if a request goes online to Google's AI"));
      expect(line, isNot(contains('is sent online')));
    });

    test('limited but usable: the plain invitation', () {
      expect(
        readinessCalmLine(
          _readiness(
            text: const HybridAvailability(status: OnDeviceStatus.downloadable),
            cloud: true,
          ),
        ),
        'Type what you have, or pick a recipe below.',
      );
    });

    testWidgets('ReadinessLine: one line and a Details button', (tester) async {
      var details = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadinessLine(
              readiness: _readiness(text: _unavailable),
              onDetails: () => details++,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('readiness-line')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('readiness-details')));
      expect(details, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: ReadinessLine(readiness: _readiness(), onDetails: () {}),
        ),
      );
      expect(find.byKey(const ValueKey('readiness-line')), findsNothing);
    });
  });

  group('hybridUnavailableReason (item 11)', () {
    HybridRuntime runtime({
      HybridAvailability text = _unavailable,
      String routes = '',
      bool online = true,
    }) => HybridRuntime.create(
      inference: FakeHybridInference(
        textAvailability: text,
        imageAvailability: text,
      ),
      cloudRoutes: CloudRoutes.parse(routes),
      cloudFallback: _NoCloud(),
      isOnline: () => online,
    );

    test('ready device: no reason', () async {
      expect(await hybridUnavailableReason(runtime(text: _available)), isNull);
    });

    test('no device model and sending online off', () async {
      expect(
        await hybridUnavailableReason(runtime()),
        "This device can't do it on its own, and sending online is off in "
        'this build.',
      );
    });

    test('offline', () async {
      expect(
        await hybridUnavailableReason(
          runtime(routes: 'hybridFallback', online: false),
        ),
        startsWith("You're offline"),
      );
    });

    test('cloud approved and online: AI can run, so no reason', () async {
      expect(
        await hybridUnavailableReason(runtime(routes: 'hybridFallback')),
        isNull,
      );
    });
  });

  group('pantry screen', () {
    late List<Recipe> recipes;
    late AppServices services;

    Future<void> phone(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);
      recipes = (await tester.runAsync(loadRecipeCatalog))!;
      services = (await tester.runAsync(fakeServices))!;
    }

    Future<void> findMeal(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const ValueKey('pantry-text')), text);
      await tester.ensureVisible(find.byKey(const ValueKey('find-meal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('find-meal')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }

    testWidgets('practice mode respects the typed list (items 9, 13) and '
        'shows it in view (persona 5)', (tester) async {
      await phone(tester);
      final hybrid = RehearsalHybridRuntime.create(
        inference: RehearsalHybridInference(answerDelay: Duration.zero),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: PantryFlow(
            services: services,
            isDemo: true,
            hybrid: hybrid,
            loadRecipes: () => SynchronousFuture(recipes),
            cookingBuilder: (recipe, back) => Text('Cooking ${recipe.id}'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Labelled header buttons and no warning stack in practice mode.
      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('What we sent'), findsOneWidget);
      expect(find.byKey(const ValueKey('readiness-line')), findsNothing);
      expect(find.text(pantryPrivacyLine), findsOneWidget);
      expect(pantryPrivacyLine, isNot(contains('On-device AI')));

      await findMeal(tester, 'bread, peanut butter, banana');
      expect(find.text('Your pantry haul'), findsOneWidget);
      final header = tester.getRect(find.text('Your pantry haul'));
      expect(header.top, greaterThanOrEqualTo(0));
      expect(header.bottom, lessThan(915));
      expect(find.text('PRACTICE MODE'), findsOneWidget);
      for (final item in ['bread', 'peanut butter', 'banana']) {
        expect(find.bySemanticsLabel('$item, clear'), findsOneWidget);
      }
      expect(find.bySemanticsLabel(RegExp('black beans')), findsNothing);
      expect(
        find.textContaining('Items you typed are already ticked'),
        findsOneWidget,
      );
      // Nothing typed is dropped silently.
      expect(find.text('Not used in these recipes: banana'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cook-peanut_butter_sandwich_v1')),
        findsOneWidget,
      );
      expect(find.textContaining('banana'), findsWidgets);
      expect(hybrid.ledger.legs.map((l) => l.provenance).toSet(), {
        Provenance.simulated,
      });
    });

    Widget screen(PantryClient client, {Future<String?> Function()? reason}) =>
        MaterialApp(
          theme: cookingTheme,
          home: PantryScreen(
            recipes: recipes,
            client: client,
            onChooseRecipe: (_, _) {},
            unavailableReason: reason,
            headerActions: const Text('ACTIONS'),
          ),
        );

    testWidgets('a reasonless failure says why and shows a source line '
        '(item 11)', (tester) async {
      await phone(tester);
      await tester.pumpWidget(
        screen(
          _Throwing(StateError('bridge')),
          reason: () async =>
              "This device can't do it on its own, and sending online is "
              'off in this build.',
        ),
      );
      await findMeal(tester, 'bread');
      expect(
        find.text(
          "Matching your food didn't work just now. This device can't do it "
          'on its own, and sending online is off in this build. Pick a '
          'recipe below, or try again.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pantry-no-answer-source')),
        findsOneWidget,
      );
      expect(find.textContaining('Ingredient matching'), findsNothing);
    });

    testWidgets('PantryFlow wires the hybrid runtime\'s reason into a '
        'failed scan (item 11)', (tester) async {
      await phone(tester);
      final hybrid = HybridRuntime.create(
        inference: FakeHybridInference(
          textAvailability: _unavailable,
          imageAvailability: _unavailable,
        ),
        cloudRoutes: const CloudRoutes({}),
        cloudFallback: _NoCloud(),
        isOnline: () => true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          navigatorKey: hybrid.navigatorKey,
          home: PantryFlow(
            services: services,
            isDemo: false,
            hybrid: hybrid,
            client: _Throwing(StateError('bridge')),
            loadRecipes: () => SynchronousFuture(recipes),
            cookingBuilder: (recipe, back) => Text('Cooking ${recipe.id}'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await findMeal(tester, 'bread');
      expect(
        find.textContaining(
          "This device can't do it on its own, and sending online is off in "
          'this build.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('no known reason: the plain message; a reason lookup that '
        'throws is ignored', (tester) async {
      await phone(tester);
      await tester.pumpWidget(
        screen(const _Generic(), reason: () => Future.error(StateError('x'))),
      );
      await findMeal(tester, 'bread');
      expect(find.text(pantryUnavailableMessage), findsOneWidget);
    });

    testWidgets('a specific client message is shown as is', (tester) async {
      await phone(tester);
      await tester.pumpWidget(
        screen(
          _Throwing(const PantryException('Please keep the list short.')),
          reason: () async => 'never used',
        ),
      );
      await findMeal(tester, 'bread');
      expect(find.text('Please keep the list short.'), findsOneWidget);
    });

    testWidgets('header actions sit under the brand row', (tester) async {
      await phone(tester);
      await tester.pumpWidget(screen(const _Generic()));
      await tester.pumpAndSettle();
      final brand = tester.getRect(find.text('SousSight'));
      final actions = tester.getRect(find.text('ACTIONS'));
      expect(actions.top, greaterThan(brand.top));
    });

    testWidgets('the quick-question hint wraps instead of clipping (item 10)', (
      tester,
    ) async {
      await phone(tester);
      await tester.pumpWidget(
        screen(const FakePantryClient(delay: Duration.zero)),
      );
      await findMeal(tester, 'beans');
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('pantry-answer')),
      );
      expect(field.decoration!.hintText, 'Your answer (optional)');
      expect(field.decoration!.hintMaxLines, 2);
      expect(field.decoration!.helperText, 'I’ll pass it to your coach.');
    });
  });
}

/// Fails with the old catch-all wording, which the screen upgrades.
class _Generic implements PantryClient {
  const _Generic();
  @override
  Future<PantryResult> identify(PantryInput input, List<Recipe> recipes) =>
      Future.error(
        const PantryException(
          'Ingredient matching is unavailable right now. Pick a recipe below.',
        ),
      );
}
