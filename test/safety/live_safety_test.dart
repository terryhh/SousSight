// The shared safety gate on the Live / GenUI path (SS-131): coach panels,
// timer labels and readiness observations that certify doneness or safety,
// never reach the cook. Fakes only: no model, camera
// or network.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/analytics.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/genui/cooking_ui_controller.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/safety/cook_safety.dart';

const _recipe = Recipe(
  id: 'chicken',
  version: 1,
  title: 'Pan chicken',
  summary: 'A test recipe.',
  ingredients: [Ingredient(id: 'chicken', name: 'Chicken', qty: '2 pieces')],
  equipment: ['pan'],
  steps: [
    RecipeStep(
      id: 'sear',
      title: 'Sear the chicken',
      instruction: 'Cook the chicken in the pan.',
      cue: 'Golden on both sides.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

class _Media implements LiveMedia {
  final video = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get frames => video.stream;
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Stream<CapturedFrame> get timedFrames => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> startCameraOnly() async {}
  @override
  Future<void> stop() async {}
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void interruptPlayback() {}
  @override
  void playAudio(Uint8List pcm24khz) {}
}

class _Transport implements LiveTransport {
  final source = StreamController<LiveEvent>.broadcast();
  final responses = <Map<String, Object?>>[];
  @override
  Stream<LiveEvent> get events => source.stream;
  @override
  Future<void> connect({required String systemInstruction}) async {}
  @override
  Future<void> sendAudio(Uint8List pcm16khz) async {}
  @override
  Future<void> sendVideo(Uint8List jpeg) async {}
  @override
  Future<void> sendText(String text) async {}
  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async => responses.add(response);
  @override
  Future<void> close() async {}
}

class _Research implements CookingResearchClient {
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) =>
      Completer<CookingResearchResult>().future;
}

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _panel(String body) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['generated'],
    },
    {'id': 'generated', 'component': 'stepCue', 'title': 'Coach', 'body': body},
  ],
});

void main() {
  group('CookingUiController.applyJson', () {
    late CookingUiController ui;
    setUp(() => ui = CookingUiController());
    tearDown(() => ui.dispose());

    for (final claim in [
      'The chicken is safe to eat.',
      'The camera shows 165F at the center',
      'If it looks white inside it is cooked.',
      'This is sesame-free.',
    ]) {
      test('rejects "$claim" before replacing anything', () {
        final before = ui.components;
        expect(
          () => ui.applyJson(_panel(claim)),
          throwsA(isA<UnsafeClaimException>()),
        );
        expect(ui.components, before);
      });
    }

    test('accepts plain coaching in either language', () {
      ui.applyJson(_panel('Cocina hasta que esté dorado; usa un termómetro.'));
      expect(jsonEncode(ui.components), contains('dorado'));
    });
  });

  group('coordinator tool calls', () {
    late _Transport transport;
    late _Media media;
    late CookingCoordinator cook;

    setUp(() async {
      transport = _Transport();
      media = _Media();
      cook = CookingCoordinator(
        services: AppServices(
          auth: FakeAuthService(),
          recipes: FakeRecipeRepository(_recipe),
          sessions: FakeSessionRepository(),
          bundledRecipe: _recipe,
          clock: () => DateTime.utc(2026, 11, 26, 12),
          analytics: RecordingAnalytics(),
        ),
        research: _Research(),
        transportFactory: () => transport,
        media: media,
      );
      await cook.initialize();
      await _flush();
      await cook.connect();
      await _flush();
    });

    tearDown(() async {
      await cook.live.stop();
      cook.dispose();
      await transport.source.close();
      await media.video.close();
    });

    Future<Map<String, Object?>> call(
      String name,
      Map<String, Object?> args,
    ) async {
      transport.responses.clear();
      transport.source.add(
        LiveToolCall(id: '$name-${args.hashCode}', name: name, arguments: args),
      );
      await _flush();
      return transport.responses.single;
    }

    for (final claim in [
      'The chicken is safe to eat.',
      'The juices run clear, so it is done.',
    ]) {
      test(
        'show_cooking_ui with "$claim" falls back to the recipe cue',
        () async {
          final r = await call('show_cooking_ui', {
            'stepId': 'sear',
            'uiJson': _panel(claim),
          });
          expect(r['ok'], isFalse);
          expect('${r['error']}', contains('Never certify'));
          final shown = jsonEncode(cook.ui.components);
          expect(shown, isNot(contains(claim)));
          expect(shown, contains('Golden on both sides.'));
          expect(shown, contains('food thermometer'));
        },
      );
    }

    test('start_timer with a certifying label is refused', () async {
      final r = await call('start_timer', {
        'id': 'rest',
        'label': 'Rest until safe to eat',
        'seconds': 60,
      });
      expect(r['ok'], isFalse);
      expect(cook.ui.timers, isEmpty);
    });

    for (final claim in [
      'The chicken is safe to eat.',
      'The juices run clear, so it is done.',
    ]) {
      test(
        'report_readiness "$claim" is downgraded and shows the cue',
        () async {
          final watch = await call('watch_cooking', {
            'goal': 'Golden on both sides',
          });
          expect(watch['ok'], isTrue);
          final watchId = cook.live.watchId!;
          media.video.add(Uint8List.fromList([1, 2, 3]));
          await _flush();
          final r = await call('report_readiness', {
            'watchId': watchId,
            'state': 'ready',
            'observation': claim,
          });
          expect(r['ok'], isFalse);
          expect(r['state'], 'uncertain');
          expect(cook.alert ?? '', isNot(contains(claim)));
          final shown = jsonEncode(cook.ui.components);
          expect(shown, isNot(contains(claim)));
          expect(shown, contains('Look for: Golden on both sides.'));
          // Not marked ready: the watch keeps checking.
          expect(cook.live.watchId, watchId);
        },
      );
    }

    test('ask_cook questions and watch goals pass the gate', () async {
      final ask = await call('ask_cook', {
        'question': 'The chicken is safe to eat. Shall we serve it?',
        'reason': 'checking',
      });
      expect(ask['ok'], isFalse);
      expect(cook.cookQuestion, isNull);
      expect(jsonEncode(cook.ui.components), isNot(contains('safe to eat')));

      final plainAsk = await call('ask_cook', {
        'question': 'Do you have a lid for the pan?',
        'reason': 'technique',
      });
      expect(plainAsk['ok'], isTrue);
      expect(cook.cookQuestion, 'Do you have a lid for the pan?');

      final watch = await call('watch_cooking', {
        'goal': 'Watch until the chicken is cooked through',
      });
      expect(watch['ok'], isFalse);
      expect(cook.live.watchId, isNull, reason: 'the watch is stopped');
    });

    test('second-round probes are blocked at the panel boundary', () async {
      for (final claim in [
        'The chicken is done when the juices run clear.',
        'No peanuts in this dish',
        'The milk is fresh.',
        'Sesame-free',
      ]) {
        final r = await call('show_cooking_ui', {
          'stepId': 'sear',
          'uiJson': _panel(claim),
        });
        expect(r['ok'], isFalse, reason: claim);
        expect(jsonEncode(cook.ui.components), isNot(contains(claim)));
      }
    });

    test('a rejected new watch goal keeps the current watch', () async {
      final first = await call('watch_cooking', {
        'goal': 'Golden on both sides',
      });
      expect(first['ok'], isTrue);
      final watchId = cook.live.watchId;
      expect(watchId, isNotNull);
      final second = await call('watch_cooking', {
        'goal': 'Tell me when it is done',
      });
      expect(second['ok'], isFalse);
      expect(cook.live.watchId, watchId);
    });

    test('a plain readiness observation still works', () async {
      await call('watch_cooking', {'goal': 'Golden on both sides'});
      final watchId = cook.live.watchId!;
      media.video.add(Uint8List.fromList([1, 2, 3]));
      await _flush();
      final r = await call('report_readiness', {
        'watchId': watchId,
        'state': 'ready',
        'observation': 'Both sides look golden.',
      });
      expect(r['ok'], isTrue);
      expect(cook.alert, contains('Both sides look golden.'));
    });
  });
}
