// Codex review of #221 at b2f408f: the skipped-clip notice. Fakes only.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

/// A clip on start; stop runs [onStop] (to close the gate mid-await).
class _Media extends DemoLiveMedia {
  _Media(this.onStop);
  final void Function() onStop;
  final _mic = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get microphone => _mic.stream;
  @override
  Future<void> start() async =>
      scheduleMicrotask(() => _mic.add(Uint8List(32000)));
  @override
  Future<void> stop() async => onStop();
}

class _Recording implements PantryClient {
  final inputs = <PantryInput>[];
  @override
  Future<PantryResult> identify(PantryInput input, List<Recipe> recipes) async {
    inputs.add(input);
    return const PantryResult(items: [], meals: []);
  }
}

void main() {
  Future<({_Recording client, void Function(bool) setOnline})> pump(
    WidgetTester tester, {
    bool closeOnStop = false,
  }) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    var online = true;
    final client = _Recording();
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryScreen(
          recipes: recipes,
          client: client,
          onChooseRecipe: (_, _) {},
          mediaFactory: () => _Media(() {
            if (closeOnStop) online = false;
          }),
          recordDuration: const Duration(milliseconds: 300),
          voiceOnline: () => online,
        ),
      ),
    );
    return (client: client, setOnline: (bool v) => online = v);
  }

  Future<void> record(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('record-voice')));
    await tester.tap(find.byKey(const ValueKey('record-voice')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> findMeal(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('find-meal'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('#1 a gate that closes during the stop still drops the clip', (
    tester,
  ) async {
    final p = await pump(tester, closeOnStop: true);
    await record(tester);
    await findMeal(tester); // the gate closes inside _stopMedia
    expect(p.client.inputs, isEmpty);
    expect(find.text(pantryVoiceSkipped), findsWidgets);
  });

  testWidgets('#2 the notice belongs to the submission that dropped a clip', (
    tester,
  ) async {
    final p = await pump(tester);
    await record(tester);
    p.setOnline(false);
    await findMeal(tester);
    expect(find.text(pantryVoiceSkipped), findsWidgets);
    // A new recording clears it at once.
    p.setOnline(true);
    await record(tester);
    await tester.pumpAndSettle();
    expect(find.text(pantryVoiceSkipped), findsNothing);
    // A later submission without a clip never repeats it.
    await tester.ensureVisible(find.byKey(const ValueKey('mode-type')));
    await tester.tap(find.byKey(const ValueKey('mode-type')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'rice');
    p.setOnline(false);
    await findMeal(tester);
    expect(find.text(pantryVoiceSkipped), findsNothing);
  });
}
