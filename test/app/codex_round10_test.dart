// Codex review of #221 at 259a97b. Fakes only.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/trust/trust_labels.dart';

class _Media extends DemoLiveMedia {
  final _mic = StreamController<Uint8List>.broadcast();
  int stops = 0;
  @override
  Stream<Uint8List> get microphone => _mic.stream;
  @override
  Future<void> start() async =>
      scheduleMicrotask(() => _mic.add(Uint8List(32000)));
  @override
  Future<void> stop() async => stops++;
}

InferenceLeg _leg({required bool permitted}) => InferenceLeg(
  requestId: 'r',
  feature: 'pantry_scan',
  mode: permitted ? HybridMode.preferInCloud : HybridMode.onlyOnDevice,
  kinds: const {DataKind.text},
  transferPermitted: permitted,
  provenance: Provenance.sdkOnDevice,
);

void main() {
  testWidgets('#1 a voice-only skip still releases capture and the clip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    var online = true;
    final media = _Media();
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryScreen(
          recipes: recipes,
          client: const FakePantryClient(delay: Duration.zero),
          onChooseRecipe: (_, _) {},
          mediaFactory: () => media,
          recordDuration: const Duration(milliseconds: 300),
          voiceOnline: () => online,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('record-voice')));
    await tester.tap(find.byKey(const ValueKey('record-voice')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('clip is ready'), findsOneWidget);
    online = false;
    final stopsBefore = media.stops;
    final findMeal = find.byKey(const ValueKey('find-meal'));
    await tester.ensureVisible(findMeal);
    await tester.pumpAndSettle();
    await tester.tap(findMeal);
    await tester.pumpAndSettle();
    expect(media.stops, greaterThan(stopsBefore));
    expect(find.text(pantryVoiceSkipped), findsWidgets);
    expect(find.textContaining('clip is ready'), findsNothing);
  });

  test('#2 sending wording comes from the leg, not the on-device result', () {
    final cloudFirst = legExplanation(_leg(permitted: true));
    expect(cloudFirst, contains('may also have been sent'));
    expect(cloudFirst, isNot(contains("wasn't sent")));
    final localOnly = legExplanation(_leg(permitted: false));
    expect(localOnly, contains('not allowed to leave this device'));
    expect(outcomeExplanation(LegOutcome.onDevice), isNot(contains('sent')));
    expect(
      legExplanation(
        const InferenceLeg(
          requestId: 'c',
          feature: 'pantry_scan',
          mode: HybridMode.onlyInCloud,
          kinds: {DataKind.text},
          transferPermitted: true,
          provenance: Provenance.sdkCloud,
        ),
      ),
      outcomeExplanation(LegOutcome.cloudSdk),
    );
  });
}
