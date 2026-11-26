// Codex review of #221 at 14e7373. Fakes only.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/learner/plain_research_text.dart';
import 'package:soussight/live/live_controller.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_handoff.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/pantry_ui.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/watch_service.dart';
import 'package:soussight/watch/watch_verdict.dart';

import '../watch/watch_fakes.dart';

/// Microphone permission waits on [gate]; the camera starts at once.
class _GatedMicMedia extends DemoLiveMedia {
  _GatedMicMedia(this.gate);
  final Future<void> gate;
  final _mic = StreamController<Uint8List>.broadcast();
  bool micLive = false;
  @override
  Stream<Uint8List> get microphone => _mic.stream;
  @override
  Future<void> start() async {
    await gate;
    micLive = true;
    scheduleMicrotask(() => _mic.add(Uint8List(32000)));
  }

  @override
  Future<void> stop() async => micLive = false;
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

/// Local-only for Watch turns on after [after] reads.
class _FlippingPrivacy implements PrivacySettings {
  _FlippingPrivacy(this.after);
  final int after;
  int reads = 0;
  @override
  bool localOnly(String feature) =>
      feature == kLocalWatchFeature && ++reads > after;
}

class _Markdown implements CookingResearchClient {
  const _Markdown(this.answer);
  final String answer;
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) async =>
      CookingResearchResult(answer: answer);
}

Map<String, dynamic> _leaf(String id, {String component = 'stepCue'}) =>
    component == 'watchStatus'
    ? {
        'id': id,
        'component': 'watchStatus',
        'status': 'watching',
        'title': 'Model watch',
        'body': 'b',
      }
    : {'id': id, 'component': 'stepCue', 'title': id, 'body': 'b'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('#1 leaving Say while mic permission is pending sends no '
      'audio', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    final gate = Completer<void>();
    final media = <_GatedMicMedia>[];
    final client = _Recording();
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryScreen(
          recipes: recipes,
          client: client,
          onChooseRecipe: (_, _) {},
          mediaFactory: () {
            final m = _GatedMicMedia(gate.future);
            media.add(m);
            return m;
          },
          recordDuration: const Duration(milliseconds: 300),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mode-say')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('record-voice')));
    await tester.pump(); // permission pending
    await tester.tap(find.byKey(const ValueKey('mode-scan')));
    await tester.pump();
    gate.complete(); // permission granted after the cook left Say
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(media.first.micLive, isFalse);
    await tester.tap(find.byKey(const ValueKey('mode-type')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pantry-text')), 'rice');
    final findMeal = find.byKey(const ValueKey('find-meal'));
    await tester.ensureVisible(findMeal);
    await tester.pumpAndSettle();
    await tester.tap(findMeal);
    await tester.pumpAndSettle();
    expect(client.inputs.single.audioWav, isNull);
  });

  test('#2 Watch local-only is re-read right before the Live watch', () async {
    final goals = <String>[];
    final privacy = _FlippingPrivacy(1); // off at the first read, then on
    final service = WatchService(
      local: LocalWatchController(
        dispatcher: FakeHybridDispatcher(),
        capture: CaptureOwner(FakeMedia()),
        privacy: privacy,
      ),
      startLiveWatch: (goal) {
        goals.add(goal);
        return 'live-1';
      },
      stopLiveWatch: () {},
    );
    final start = await service.startWatch(
      step: stepA,
      sessionId: 's1',
      liveActive: true,
    );
    expect(privacy.reads, greaterThanOrEqualTo(2));
    expect(goals, isEmpty);
    expect(start.message, contains('Tap Stop'));
  });

  group('#3 the watch panel never breaks a full layout', () {
    late CookingCoordinator cook;
    setUp(() async {
      cook = CookingCoordinator(
        services: await fakeServices(),
        research: const FakeCookingResearchClient(),
        transportFactory: null,
        media: DemoLiveMedia(),
      );
      await cook.initialize();
    });
    tearDown(() => cook.dispose());

    Map<String, dynamic> layout(List<Map<String, dynamic>> leaves) => {
      'components': [
        {
          'id': 'root',
          'component': 'CookingColumn',
          'children': [for (final l in leaves) l['id']],
        },
        ...leaves,
      ],
    };

    test('16 components with a model watch leaf: updated in place', () {
      cook.ui.applyToolPayload(
        layout([
          for (var i = 0; i < 14; i++) _leaf('tip$i'),
          _leaf('watch', component: 'watchStatus'),
        ]),
      );
      expect(cook.ui.components, hasLength(16));
      cook.stopWatch();
      expect(cook.ui.components, hasLength(16));
      final watch = cook.ui.components.singleWhere((c) => c['id'] == 'watch');
      expect(watch['status'], 'paused');
    });

    test('16 components and no watch leaf: watch panel and step only', () {
      cook.ui.applyToolPayload(
        layout([for (var i = 0; i < 15; i++) _leaf('tip$i')]),
      );
      cook.stopWatch();
      final ids = cook.ui.components.map((c) => c['id']).toList();
      expect(ids, ['root', CookingCoordinator.watchPanelId, 'step']);
    });
  });

  group('#4/#5 one identity rule for ranking and handoff', () {
    late Recipe wrap;
    late Recipe salsa;
    setUpAll(() async {
      final recipes = await loadRecipeCatalog();
      wrap = recipes.firstWhere((r) => r.id == 'chickpea_wrap_v1');
      salsa = recipes.firstWhere((r) => r.id == 'black_bean_corn_salsa_v1');
    });

    test('"salt and black pepper", whole or split, is salt_pepper', () {
      expect(
        matchIngredientIds(['salt and black pepper'], wrap),
        contains('salt_pepper'),
      );
      expect(
        matchIngredientIds(['salt', 'black pepper'], wrap),
        contains('salt_pepper'),
      );
      expect(
        matchIngredientIds(['salt'], wrap),
        isNot(contains('salt_pepper')),
      );
      expect(
        practiceIngredientMatch([
          'salt and black pepper',
        ], 'Salt and black pepper'),
        ['salt and black pepper'],
      );
    });

    test('frozen is not canned; an unstated state still matches', () {
      expect(pantrySameItem('frozen corn', 'canned corn'), isFalse);
      expect(pantrySameItem('corn', 'canned corn'), isTrue);
      expect(
        practiceHasIngredient('frozen corn', 'Canned corn, drained'),
        isFalse,
      );
      expect(matchIngredientId('frozen corn', salsa), isNull);
      expect(matchIngredientId('canned corn', salsa), 'corn');
    });
  });

  test('#8 a bullet-only research answer is no answer', () async {
    const query = CookingResearchQuery(question: 'q', currentStep: 's');
    await expectLater(
      const PlainTextResearchClient(_Markdown('- ** **')).research(query),
      throwsA(isA<CookingResearchException>()),
    );
  });

  test(
    '#9 each practice watch starts at "not yet" and names the cue',
    () async {
      final inference = RehearsalHybridInference(answerDelay: Duration.zero);
      Future<WatchState> check() async => parseWatchJson(
        (await inference.generate(
          HybridRequest(
            requestId: 'r',
            mode: HybridMode.onlyOnDevice,
            task: HybridTask(
              feature: kLocalWatchFeature,
              parts: [HybridText(buildWatchPrompt(stepA))],
              maxOutputTokens: 50,
              timeout: const Duration(seconds: 5),
            ),
          ),
        )).text,
      ).state;
      expect(await check(), WatchState.notYet);
      expect(await check(), WatchState.unsure);
      final media = RehearsalLiveMedia(onCameraStart: inference.newWatch);
      await media.startCameraOnly(); // a new watch
      await media.stop();
      expect(await check(), WatchState.notYet);
      final answer = practiceWatchAnswer(0, cue: stepA.cue);
      expect(answer, contains(stepA.cue));
    },
  );

  group('pre-existing: Live honours Watch local-only', () {
    test('a model watch is refused while local-only is on, and stops when '
        'it turns on mid-watch', () {
      fakeAsync((async) {
        var localOnly = true;
        final live = LiveCookingController(
          transportFactory: DemoLiveTransport.new,
          media: DemoLiveMedia(),
          onToolCall: (_) async => {'ok': true},
          watchLocalOnly: () => localOnly,
        );
        live.start(cookingContext: 'ctx');
        async.flushMicrotasks();
        expect(live.isActive, isTrue);
        expect(live.startWatch('Golden edges'), isNull);
        expect(live.notice, kLiveWatchLocalOnlyNotice);

        localOnly = false;
        expect(live.startWatch('Golden edges'), isNotNull);
        localOnly = true;
        async.elapse(const Duration(seconds: 16));
        expect(live.watchId, isNull);
        expect(live.notice, kLiveWatchLocalOnlyNotice);
        live.stop();
        async.flushMicrotasks();
        live.dispose();
      });
    });

    test('completed turns are counted for the reveal', () {
      fakeAsync((async) {
        final transport = _TurnTransport();
        final live = LiveCookingController(
          transportFactory: () => transport,
          media: DemoLiveMedia(),
          onToolCall: (_) async => {'ok': true},
        );
        live.start(cookingContext: 'ctx');
        async.flushMicrotasks();
        transport.emit(const LiveTurnComplete());
        transport.emit(const LiveTurnComplete());
        async.flushMicrotasks();
        expect(live.completedTurns, 2);
        live.stop();
        async.flushMicrotasks();
        live.dispose();
      });
    });
  });
}

class _TurnTransport extends DemoLiveTransport {
  final _out = StreamController<LiveEvent>.broadcast();
  @override
  Stream<LiveEvent> get events => _out.stream;
  void emit(LiveEvent e) => _out.add(e);
}
