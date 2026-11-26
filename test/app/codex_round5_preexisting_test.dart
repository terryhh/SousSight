// Pre-existing findings from the Codex review of #221 at 3b0369d: a Live
// session can't turn a local-only watch into a cloud watch, and the pantry
// takes only the camera for Scan and releases capture on Type. Fakes only.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/watch_service.dart';
import 'package:soussight/watch/watch_verdict.dart';

import '../watch/watch_fakes.dart';

class _Privacy implements PrivacySettings {
  _Privacy(this.local);
  final Set<String> local;
  @override
  bool localOnly(String feature) => local.contains(feature);
}

class _Media extends DemoLiveMedia {
  final calls = <String>[];
  final _mic = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get microphone => _mic.stream;
  @override
  Future<void> start() async => calls.add('start');
  @override
  Future<void> startCameraOnly() async => calls.add('cameraOnly');
  @override
  Future<void> stop() async => calls.add('stop');
}

void main() {
  group('Live never turns a local-only watch into a cloud watch', () {
    WatchService service(Set<String> local, List<String> liveGoals) =>
        WatchService(
          local: LocalWatchController(
            dispatcher: FakeHybridDispatcher(),
            capture: CaptureOwner(FakeMedia()),
            privacy: _Privacy(local),
          ),
          startLiveWatch: (goal) {
            liveGoals.add(goal);
            return 'live-1';
          },
          stopLiveWatch: () {},
        );

    test('local-only on: asks the cook to stop Live first', () async {
      final goals = <String>[];
      final start = await service({
        kLocalWatchFeature,
      }, goals).startWatch(step: stepA, sessionId: 's1', liveActive: true);
      expect(start.started, isFalse);
      expect(start.message, contains('Tap Stop to end the Live coach'));
      expect(goals, isEmpty);
    });

    test('local-only off: the Live watch starts as before', () async {
      final goals = <String>[];
      final start = await service(
        {},
        goals,
      ).startWatch(step: stepA, sessionId: 's1', liveActive: true);
      expect(start.route, WatchRoute.live);
      expect(goals, hasLength(1));
    });
  });

  testWidgets('Scan takes only the camera; Record asks for the mic; Type '
      'releases capture', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final made = <_Media>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryScreen(
          recipes: recipes,
          client: const FakePantryClient(delay: Duration.zero),
          onChooseRecipe: (_, _) {},
          mediaFactory: () {
            final m = _Media();
            made.add(m);
            return m;
          },
          recordDuration: const Duration(milliseconds: 300),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mode-scan')));
    await tester.pumpAndSettle();
    expect(made.single.calls, ['cameraOnly']);

    await tester.tap(find.byKey(const ValueKey('mode-type')));
    await tester.pumpAndSettle();
    expect(made.single.calls, ['cameraOnly', 'stop']);

    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('record-voice')));
    await tester.tap(find.byKey(const ValueKey('record-voice')));
    await tester.pump();
    expect(made.last.calls, ['start']);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.ensureVisible(find.byKey(const ValueKey('mode-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-type')));
    await tester.pumpAndSettle();
    expect(made.last.calls.last, 'stop');
  });

  test('the storage line separates raw media from the saved list', () {
    expect(pantryPrivacyLine, contains("Photos and voice clips aren't stored"));
    expect(
      pantryPrivacyLine,
      contains(
        'items you confirmed and your answer are saved with your '
        'cooking session',
      ),
    );
    expect(pantryPrivacyLine, isNot(contains('Nothing is stored')));
  });
}
