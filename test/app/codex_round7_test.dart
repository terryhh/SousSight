// Codex review of #221 at 270edba. Fakes only.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/plain_research_text.dart';
import 'package:soussight/live/live_controller.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/main_learner.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/pantry_ui.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/trust/route_reason_text.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/watch_service.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';

import '../watch/watch_fakes.dart';

class _ClipMedia extends DemoLiveMedia {
  final _mic = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get microphone => _mic.stream;
  @override
  Future<void> start() async =>
      scheduleMicrotask(() => _mic.add(Uint8List(32000)));
}

/// Stop waits on [stopGate]; counts camera starts.
class _SlowStopMedia extends DemoLiveMedia {
  _SlowStopMedia(this.stopGate);
  final Future<void> stopGate;
  int cameraStarts = 0;
  bool cameraOn = false;
  @override
  Future<void> start() async {}
  @override
  Future<void> startCameraOnly() async {
    cameraStarts++;
    cameraOn = true;
  }

  @override
  Future<void> stop() async {
    await stopGate;
    cameraOn = false;
  }
}

class _Recording implements PantryClient {
  final inputs = <PantryInput>[];
  @override
  Future<PantryResult> identify(PantryInput input, List<Recipe> recipes) async {
    inputs.add(input);
    return const PantryResult(
      items: [PantryItem(name: 'rice', confidence: PantryConfidence.high)],
      meals: [],
    );
  }
}

class _Answer implements CookingResearchClient {
  const _Answer(this.answer);
  final String answer;
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async =>
      CookingResearchResult(answer: answer);
}

class _TurnTransport extends DemoLiveTransport {
  final _out = StreamController<LiveEvent>.broadcast();
  @override
  Stream<LiveEvent> get events => _out.stream;
  void emit(LiveEvent e) => _out.add(e);
}

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('#1 the voice gate is read live: off at send, no audio', (
    tester,
  ) async {
    await _phone(tester);
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
          mediaFactory: _ClipMedia.new,
          recordDuration: const Duration(milliseconds: 300),
          voiceOnline: () => online,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    expect(find.text(pantryVoiceDisclosure), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('record-voice')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    online = false; // the gate changed before the cook sends
    final findMeal = find.byKey(const ValueKey('find-meal'));
    await tester.ensureVisible(findMeal);
    await tester.pumpAndSettle();
    await tester.tap(findMeal);
    await tester.pumpAndSettle();
    // Gate re-read at send: the clip is dropped and the cook is told.
    expect(client.inputs, isEmpty);
    expect(find.text(pantryVoiceSkipped), findsOneWidget);
    // And the render reads it live too.
    await tester.ensureVisible(find.byKey(const ValueKey('mode-say')));
    await tester.tap(find.byKey(const ValueKey('mode-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    expect(find.text(pantryVoiceUnavailable), findsOneWidget);
    // Record is disabled while online processing is off.
    final record = tester.widget<FilledButton>(
      find.ancestor(
        of: find.byIcon(Icons.mic),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(record.onPressed, isNull);
  });

  testWidgets('#2 a superseded Scan never opens the camera after Type', (
    tester,
  ) async {
    await _phone(tester);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final gate = Completer<void>();
    final made = <_SlowStopMedia>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryScreen(
          recipes: recipes,
          client: const FakePantryClient(delay: Duration.zero),
          onChooseRecipe: (_, _) {},
          mediaFactory: () {
            final m = _SlowStopMedia(gate.future);
            made.add(m);
            return m;
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mode-scan')));
    await tester.pumpAndSettle();
    expect(made.single.cameraOn, isTrue);
    await tester.tap(find.byKey(const ValueKey('mode-say'))); // stopping…
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mode-scan'))); // superseded
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mode-type')));
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(made.where((m) => m.cameraOn), isEmpty);
  });

  test('#3 a less specific guess is not auto-confirmed', () {
    final ui = PantryUiController(onChooseMeal: (_) {});
    addTearDown(ui.dispose);
    ui.show(
      const PantryResult(
        items: [
          PantryItem(name: 'corn', confidence: PantryConfidence.high),
          PantryItem(
            name: 'canned black beans',
            confidence: PantryConfidence.high,
          ),
        ],
        meals: [],
      ),
      const <Recipe>[],
      typed: 'frozen corn, 2 cans black beans',
    );
    expect(ui.confirmedItems, ['canned black beans']);
  });

  test('#4 routing reasons never claim a send', () {
    for (final text in routeReasonText.values) {
      expect(text, isNot(contains('had to be sent')));
      expect(text, isNot(contains('was sent online')));
    }
  });

  test('#5 a Live watch ended by local-only clears "watching"', () {
    final service = WatchService(
      local: LocalWatchController(
        dispatcher: FakeHybridDispatcher(),
        capture: CaptureOwner(FakeMedia()),
      ),
      startLiveWatch: (_) => 'live-1',
      stopLiveWatch: () {},
    );
    service.liveWatchStarted('live-1');
    expect(service.activeRoute, WatchRoute.live);
    service.liveWatchEnded();
    expect(service.activeRoute, isNull);
    expect(service.statusText ?? '', isNot(contains('is watching')));
    service.liveWatchEnded(); // idempotent
  });

  test('#6 invisible or marker-only answers are no answer', () async {
    const q = CookingResearchQuery(question: 'q', currentStep: 's');
    for (final answer in ['​', '1.\n2.', ' ‍ - ']) {
      await expectLater(
        PlainTextResearchClient(_Answer(answer)).research(q),
        throwsA(isA<CookingResearchException>()),
        reason: answer.codeUnits.toString(),
      );
    }
    expect(
      (await const PlainTextResearchClient(_Answer('1. Stir.')).research(q))
          .answer,
      '1. Stir.',
    );
  });

  test('#8 the rehearsal bootstrap builds the practice runtime', () async {
    final (services, hybrid) = await loadPracticeApp();
    expect(services, isNotNull);
    expect(isPracticeRuntime(hybrid), isTrue);
  });

  test('#9 a turn with no new reply text keeps the old version', () {
    fakeAsync((async) {
      final transport = _TurnTransport();
      final live = LiveCookingController(
        transportFactory: () => transport,
        media: DemoLiveMedia(),
        onToolCall: (_) async => {'ok': true},
      );
      live.start(cookingContext: 'ctx');
      async.flushMicrotasks();
      transport.emit(
        const LiveTranscript('Stir.', isUser: false, finished: true),
      );
      transport.emit(const LiveTurnComplete());
      async.flushMicrotasks();
      final version = live.coachTranscriptVersion;
      expect(version, greaterThan(0));
      transport.emit(const LiveTurnComplete()); // a tool-only turn
      async.flushMicrotasks();
      expect(live.completedTurns, 2);
      expect(live.coachTranscriptVersion, version);
      live.stop();
      async.flushMicrotasks();
      live.dispose();
    });
  });
}
