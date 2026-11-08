import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:image/image.dart' as img;
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_flow.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

class _RecordingClient implements PantryClient {
  PantryInput? input;
  @override
  Future<PantryResult> identify(PantryInput input, List<Recipe> recipes) {
    this.input = input;
    return const FakePantryClient(delay: Duration.zero)
        .identify(input, recipes);
  }
}

class _FakeMedia implements LiveMedia {
  final frames$ = StreamController<Uint8List>.broadcast();
  final mic$ = StreamController<Uint8List>.broadcast();
  bool started = false;
  bool stopped = false;
  @override
  Stream<Uint8List> get frames => frames$.stream;
  @override
  Stream<Uint8List> get microphone => mic$.stream;
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Future<void> start() async => started = true;
  @override
  Future<void> stop() async => stopped = true;
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void playAudio(Uint8List pcm24khz) {}
  @override
  void interruptPlayback() {}
}

void main() {
  late List<Recipe> recipes;
  late AppServices services;

  Future<void> setUp360(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    recipes = (await tester.runAsync(loadRecipeCatalog))!;
    services = (await tester.runAsync(fakeServices))!;
  }

  Widget app({
    PantryClient? client,
    String? initialRecipeId,
    bool isDemo = true,
    LiveMedia Function()? media,
    CookingPageBuilder? cooking,
  }) => MaterialApp(
    theme: cookingTheme,
    home: PantryFlow(
      services: services,
      isDemo: isDemo,
      client: client,
      initialRecipeId: initialRecipeId,
      mediaFactory: media,
      loadRecipes: () => SynchronousFuture(recipes),
      cookingBuilder:
          cooking ??
          (recipe, back) => Scaffold(
            body: Column(
              children: [
                Text('Cooking ${recipe.id}'),
                TextButton(onPressed: back, child: const Text('Back')),
              ],
            ),
          ),
    ),
  );

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'rehearsal pantry suggests meals via GenUI and opens the chosen recipe',
    (tester) async {
      await setUp360(tester);
      final client = _RecordingClient();
      await tester.pumpWidget(app(client: client));
      await tester.pumpAndSettle();
      expect(find.text('What did you get from the pantry?'), findsOneWidget);
      expect(find.textContaining('Rehearsal mode'), findsOneWidget);
      expect(find.text(pantryPrivacyLine), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('pantry-text')),
        'beans',
      );
      await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
      expect(client.input!.text, 'beans');
      expect(find.byType(Surface), findsOneWidget);
      expect(find.text('SIMULATED'), findsOneWidget);
      expect(find.text('BEST MATCH'), findsOneWidget);

      // Nothing is confirmed until the cook taps it; model confidence is
      // not cook confirmation. The cook confirms two items, toggles one on
      // and off again, and answers the question.
      await tapVisible(tester, find.bySemanticsLabel('canned black beans, clear'));
      await tapVisible(tester, find.bySemanticsLabel('canned corn, clear'));
      await tapVisible(tester, find.bySemanticsLabel('bread, clear'));
      await tapVisible(tester, find.bySemanticsLabel('bread, clear'));
      await tester.enterText(
        find.byKey(const ValueKey('pantry-answer')),
        'Tortilla chips',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cook-black_bean_corn_salsa_v1')),
      );
      expect(find.text('Cooking black_bean_corn_salsa_v1'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final uid = await services.auth.signInLearner();
      final session = (await tester.runAsync(
        () => services.sessions.createOrResume(uid, recipes.last),
      ))!;
      expect(session.ingredients.keys, containsAll(['black_beans', 'corn']));
      expect(session.ingredients['lime'], isNull, reason: 'never tapped');
      expect(session.ingredients['tomato'], isNull,
          reason: 'medium/high confidence alone is not confirmation');
      expect(
        session.confirmedFacts.first,
        allOf(contains('canned black beans'), isNot(contains('bread'))),
      );
      expect(session.confirmedFacts.last, contains('Tortilla chips'));

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Your pantry haul'), findsOneWidget);
    },
  );

  testWidgets('skip list opens any recipe without pantry context', (
    tester,
  ) async {
    await setUp360(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.byKey(const ValueKey('skip-chickpea_wrap_v1')),
    );
    expect(find.text('Cooking chickpea_wrap_v1'), findsOneWidget);
    final uid = await services.auth.signInLearner();
    final session = (await tester.runAsync(
      () => services.sessions.createOrResume(uid, recipes[1]),
    ))!;
    expect(session.confirmedFacts, isEmpty);
  });

  testWidgets('deep link skips the pantry and can return to it', (
    tester,
  ) async {
    await setUp360(tester);
    await tester.pumpWidget(app(initialRecipeId: 'chickpea_wrap_v1'));
    await tester.pumpAndSettle();
    expect(find.text('Cooking chickpea_wrap_v1'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('What did you get from the pantry?'), findsOneWidget);
  });

  testWidgets('live mode captures a camera frame and a WAV voice clip', (
    tester,
  ) async {
    await setUp360(tester);
    final media = _FakeMedia();
    final client = _RecordingClient();
    await tester.pumpWidget(
      MaterialApp(
        home: PantryScreen(
          recipes: recipes,
          client: client,
          mediaFactory: () => media,
          recordDuration: const Duration(seconds: 1),
          onChooseRecipe: (_, _) {},
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mode-scan')));
    await tester.pumpAndSettle();
    expect(media.started, isTrue);
    expect(find.text('Snap photo'), findsNothing);
    final jpeg = img.encodeJpg(img.Image(width: 8, height: 6));
    media.frames$.add(jpeg);
    await tester.pump();
    await tester.pump();
    expect(find.text('LIVE PREVIEW'), findsOneWidget);
    await tester.ensureVisible(find.text('Snap photo'));
    await tester.tap(find.text('Snap photo'));
    await tester.pump();
    await tester.ensureVisible(find.text('PHOTO READY'));
    expect(find.text('PHOTO READY'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('mode-say')));
    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('record-voice')));
    await tester.tap(find.byKey(const ValueKey('record-voice')));
    await tester.pump();
    await tester.pump();
    media.mic$.add(Uint8List(16000));
    media.mic$.add(Uint8List(16000));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.textContaining('clip is ready'), findsOneWidget);

    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    expect(media.stopped, isTrue);
    expect(client.input!.photoJpeg, jpeg);
    expect(client.input!.audioWav!.length, 44 + 32000);
    expect(String.fromCharCodes(client.input!.audioWav!.sublist(0, 4)), 'RIFF');
  });

  testWidgets('choosing a meal opens the real cooking screen for that recipe', (
    tester,
  ) async {
    await setUp360(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryFlow(
          services: services,
          isDemo: true,
          client: const FakePantryClient(delay: Duration.zero),
          loadRecipes: () => SynchronousFuture(recipes),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    await tapVisible(
      tester,
      find.byKey(const ValueKey('cook-black_bean_corn_salsa_v1')),
    );
    expect(find.text('Black Bean & Corn Salsa'), findsWidgets);
    expect(find.text('Back to pantry'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Back to pantry'));
    await tester.pumpAndSettle();
    expect(find.text('Your pantry haul'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('untouched candidates are never handed off as confirmed', (
    tester,
  ) async {
    await setUp360(tester);
    await tester.pumpWidget(app(client: _RecordingClient()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'beans');
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    await tapVisible(
      tester,
      find.byKey(const ValueKey('cook-black_bean_corn_salsa_v1')),
    );
    final uid = await services.auth.signInLearner();
    final session = (await tester.runAsync(
      () => services.sessions.createOrResume(uid, recipes.last),
    ))!;
    expect(session.ingredients, isEmpty);
    expect(
      session.confirmedFacts.where((f) => f.startsWith('Pantry has')),
      isEmpty,
    );
  });

  testWidgets('a camera start still pending when the cook leaves never activates', (
    tester,
  ) async {
    await setUp360(tester);
    final gate = Completer<void>();
    final media = _SlowMedia(gate.future);
    await tester.pumpWidget(app(isDemo: false, media: () => media));
    await tester.pumpAndSettle();
    // The camera spinner animates while start is pending, so pump explicitly.
    Future<void> tapNow(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tapNow(find.byKey(const ValueKey('mode-scan')));
    expect(media.startCalls, 1, reason: 'scan requested the camera');
    await tapNow(find.byKey(const ValueKey('skip-chickpea_wrap_v1')));
    expect(find.text('Cooking chickpea_wrap_v1'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(media.stopped, isTrue,
        reason: 'late permission grant must release capture immediately');
    expect(media.started, isFalse);
  });
}

class _SlowMedia extends _FakeMedia {
  _SlowMedia(this.gate);
  final Future<void> gate;
  int startCalls = 0;
  @override
  Future<void> start() async {
    startCalls++;
    await gate;
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    started = false;
  }
}
