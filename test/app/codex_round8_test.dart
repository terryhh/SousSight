// Codex review of #221 at c32a2db. Fakes only.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/label/label_check.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_flow.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/watch/watch_verdict.dart';

/// Stop waits on [stopGate]; tracks the camera.
class _SlowStopMedia extends DemoLiveMedia {
  _SlowStopMedia(this.stopGate);
  final Future<void> stopGate;
  bool cameraOn = false;
  final _mic = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get microphone => _mic.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> startCameraOnly() async => cameraOn = true;
  @override
  Future<void> stop() async {
    await stopGate;
    cameraOn = false;
  }
}

void main() {
  testWidgets('#1 choosing a recipe while capture stops opens no camera', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final services = (await tester.runAsync(fakeServices))!;
    final gate = Completer<void>();
    final made = <_SlowStopMedia>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryFlow(
          services: services,
          isDemo: false,
          loadRecipes: () => SynchronousFuture(recipes),
          client: const FakePantryClient(delay: Duration.zero),
          mediaFactory: () {
            final m = _SlowStopMedia(gate.future);
            made.add(m);
            return m;
          },
          cookingBuilder: (recipe, back) => Text('Cooking ${recipe.id}'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('record-voice')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mode-scan'))); // stopping…
    await tester.pump();
    final pick = find.byKey(const ValueKey('skip-peanut_butter_sandwich_v1'));
    await tester.ensureVisible(pick);
    await tester.tap(pick); // choose a recipe before the stop completes
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Cooking peanut_butter_sandwich_v1'), findsOneWidget);
    expect(made.where((m) => m.cameraOn), isEmpty);
  });

  testWidgets('#4 a pretend voice clip works in the rehearsal flow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final services = (await tester.runAsync(fakeServices))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryFlow(
          services: services,
          isDemo: true,
          hybrid: RehearsalHybridRuntime.create(
            inference: RehearsalHybridInference(answerDelay: Duration.zero),
          ),
          loadRecipes: () => SynchronousFuture(recipes),
          cookingBuilder: (recipe, back) => Text('Cooking ${recipe.id}'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('record-voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('record-voice')));
    await tester.pumpAndSettle();
    expect(find.text('Pretend voice clip ready.'), findsOneWidget);
    expect(find.text(pantryVoiceUnavailable), findsNothing);
  });

  test('#6 the practice camera frame is a JPEG the label check accepts', () {
    final frame = practiceCameraFrame(0);
    expect(frame.sublist(0, 2), [0xff, 0xd8]);
    final reading = parseLabelReading(practiceLabelAnswer(buildPhotoPrompt()));
    expect(reading.readable, isTrue);
    expect(reading.allergensMentioned, ['wheat']);
  });

  test(
    '#7 the practice watch reaches ready on every bundled final step',
    () async {
      final recipes = await loadRecipeCatalog();
      for (final recipe in recipes) {
        final step = recipe.steps.last;
        final cue = watchCue(step);
        final parsed = parseWatchJson(
          practiceWatchAnswer(2, cue: cue),
          cue: cue,
        );
        expect(
        parsed.state,
        WatchState.ready,
        reason: '${recipe.id}: $cue -> ${practiceWatchAnswer(2, cue: cue)}',
      );
        expect(parsed.redacted, isFalse, reason: recipe.id);
      }
    },
  );

  test('#3 the skipped-clip message names what happened', () {
    expect(pantryVoiceSkipped, contains('skipped'));
    expect(pantryVoiceSkipped, contains('off in this build'));
  });

  // Keep the Recipe import used in signatures.
  test('catalog loads', () async {
    final List<Recipe> recipes = await loadRecipeCatalog();
    expect(recipes, isNotEmpty);
  });
}
