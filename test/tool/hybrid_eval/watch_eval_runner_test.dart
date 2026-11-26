import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/ai/hybrid/payload_digest.dart';
import 'package:soussight/trust/privacy_preferences.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/watch_verdict.dart';

import '../../../tool/hybrid_eval/watch_eval.dart';
import '../../../tool/hybrid_eval/watch_eval_runner.dart';
import '../../watch/watch_fakes.dart';

final steps = recipeStepsById(
  File('assets/recipes/chickpea_wrap_v1.json').readAsStringSync(),
);
final realFixtures = parseWatchFixtures(
  File('assets/reference-cooking/fixtures.json').readAsStringSync(),
);

Future<Uint8List> readFile(String path) async => File(path).readAsBytes();

/// Two synthetic fixtures whose hashes match [photoA] and [photoB].
final photoA = Uint8List.fromList(List.generate(64, (i) => i));
final photoB = Uint8List.fromList(List.generate(64, (i) => 255 - i));
List<WatchFixture> synthetic() => [
  for (final (id, step, bytes) in [('A', 'mash', photoA), ('B', 'mix', photoB)])
    WatchFixture(
      fixtureId: id,
      checkpointId: 'cp_$step',
      stepId: step,
      assetPath: '$id.jpg',
      sha256: sha256Hex(bytes),
      expectedOutcome: ExpectedOutcome.matchesTarget,
      expectedAdjustmentId: null,
      expectedObservations: const ['x'],
    ),
];
Future<Uint8List> loadSynthetic(String path) async =>
    path == 'A.jpg' ? photoA : photoB;

/// Waits for real file reads until [dispatcher] has [n] sends.
Future<void> untilSends(ManualDispatcher dispatcher, int n) async {
  for (var i = 0; i < 400 && dispatcher.tasks.length < n; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class FixedStopwatch extends Stopwatch {
  FixedStopwatch(this.fixed);
  final Duration fixed;
  @override
  Duration get elapsed => fixed;
}

class ThrowingDispatcher implements HybridDispatcher {
  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) => HybridOperation(
    'x',
    Future<DispatchResult>.error(StateError('bridge gone')),
    () {},
  );
}

void main() {
  group('the request', () {
    test('is byte-for-byte the request the on-device watch sends', () {
      fakeAsync((async) {
        final t0 = DateTime(2026, 11, 28, 10);
        final media = FakeMedia();
        final dispatcher = FakeHybridDispatcher()
          ..enqueue(verdictJson('not_yet', direction: 'more'));
        final watch = LocalWatchController(
          dispatcher: dispatcher,
          capture: CaptureOwner(media),
          now: () => t0.add(async.elapsed),
        );
        final step = steps['mash']!;
        watch.start(step: step, sessionId: 's1');
        async.flushMicrotasks();
        final jpeg = Uint8List.fromList([9, 8, 7, 6]);
        media.emit(t0.add(async.elapsed), jpeg);
        async.flushMicrotasks();
        final sent = dispatcher.tasks.single;
        final ours = watchEvalTask(step, jpeg, timeout: watch.requestTimeout);
        expect(hybridPayloadDigest(ours), hybridPayloadDigest(sent));
        expect(ours.feature, sent.feature);
        expect(ours.maxOutputTokens, sent.maxOutputTokens);
        expect(ours.timeout, sent.timeout);
        watch.dispose();
        async.flushMicrotasks();
      });
    });

    test('recipe steps are read by id and bad recipes are refused', () {
      expect(steps.keys, containsAll(['mash', 'mix']));
      expect(steps['mix']!.cue, contains('no white streaks'));
      expect(() => recipeStepsById('{}'), throwsFormatException);
      expect(() => recipeStepsById('{"steps":[1]}'), throwsFormatException);
    });
  });

  group('a run', () {
    test(
      'sends all eight real photos, verified, in one session, in order',
      () async {
        final dispatcher = ManualDispatcher();
        final runner = WatchEvalRunner(
          dispatcher: dispatcher,
          loadAsset: readFile,
          steps: steps,
          newSessionId: () => 'eval-1',
          stopwatch: () => FixedStopwatch(const Duration(milliseconds: 420)),
        );
        final seen = <String>[];
        final done = runner.run(
          realFixtures,
          onTrial: (t) => seen.add(t.fixtureId),
        );
        expect(runner.isRunning, isTrue);
        for (var i = 0; i < realFixtures.length; i++) {
          await untilSends(dispatcher, i + 1);
          await pumpEventQueue();
          expect(
            dispatcher.tasks,
            hasLength(i + 1),
            reason: 'one send at a time',
          );
          dispatcher.answer(i, verdictJson('unsure', see: 'A bowl.'));
        }
        final trials = await done;
        expect(runner.isRunning, isFalse);
        expect(
          trials.map((t) => t.fixtureId),
          realFixtures.map((f) => f.fixtureId),
        );
        expect(seen, trials.map((t) => t.fixtureId));
        expect(dispatcher.sessions.toSet(), {'eval-1'});
        for (var i = 0; i < realFixtures.length; i++) {
          final f = realFixtures[i];
          final photo = await File(f.assetPath).readAsBytes();
          expect(
            hybridPayloadDigest(dispatcher.tasks[i]),
            hybridPayloadDigest(watchEvalTask(steps[f.stepId]!, photo)),
          );
        }
        final t = trials.first;
        expect(t.outcome, TrialOutcome.answered);
        expect(t.state, WatchState.unsure);
        expect(t.latency, const Duration(milliseconds: 420));
        expect(t.legs.single.provenance, 'sdkOnDevice');
        expect(t.legs.single.carriedImage, isTrue);
        expect(t.rawText, contains('"unsure"'));
      },
    );

    test(
      'a photo that does not match its hash stops the run before any send',
      () async {
        final dispatcher = ManualDispatcher();
        final runner = WatchEvalRunner(
          dispatcher: dispatcher,
          loadAsset: (_) async => Uint8List.fromList([1, 2, 3]),
          steps: steps,
        );
        await expectLater(
          runner.run(synthetic()),
          throwsA(
            isA<FixtureIntegrityError>().having(
              (e) => e.toString(),
              'message',
              contains('declares'),
            ),
          ),
        );
        expect(dispatcher.tasks, isEmpty);
        expect(runner.isRunning, isFalse);
      },
    );

    test('a fixture for a step the recipe lacks stops the run', () async {
      final runner = WatchEvalRunner(
        dispatcher: ManualDispatcher(),
        loadAsset: loadSynthetic,
        steps: {'mash': steps['mash']!},
      );
      await expectLater(
        runner.run(synthetic()),
        throwsA(isA<FixtureIntegrityError>()),
      );
    });

    test(
      'blocked, thrown and malformed answers are recorded as such',
      () async {
        final fake = FakeHybridDispatcher()
          ..enqueueBlocked(RouteReason.modelDownloading)
          ..enqueue('not json at all');
        final trials = await WatchEvalRunner(
          dispatcher: fake,
          loadAsset: loadSynthetic,
          steps: steps,
        ).run(synthetic());
        expect(trials[0].outcome, TrialOutcome.blocked);
        expect(trials[0].blockedReason, 'modelDownloading');
        expect(trials[0].action, isNull);
        expect(trials[1].outcome, TrialOutcome.answered);
        expect(
          trials[1].state,
          WatchState.unsure,
          reason: 'malformed abstains',
        );
        expect(
          fake.tasks.every((t) => t.feature == kLocalWatchFeature),
          isTrue,
        );

        final failed = await WatchEvalRunner(
          dispatcher: ThrowingDispatcher(),
          loadAsset: loadSynthetic,
          steps: steps,
        ).run(synthetic());
        expect(failed.map((t) => t.outcome), everyElement(TrialOutcome.failed));
        expect(failed.first.error, contains('bridge gone'));
      },
    );

    test('repeats each fixture when asked, numbering the attempts', () async {
      final fake = FakeHybridDispatcher();
      for (var i = 0; i < 4; i++) {
        fake.enqueue(verdictJson('ready'));
      }
      final trials = await WatchEvalRunner(
        dispatcher: fake,
        loadAsset: loadSynthetic,
        steps: steps,
        attemptsPerFixture: 2,
      ).run(synthetic());
      expect(trials.map((t) => t.key), ['A#1', 'A#2', 'B#1', 'B#2']);
    });

    test(
      'cancel stops the send in flight and a late answer is dropped',
      () async {
        final dispatcher = ManualDispatcher();
        final runner = WatchEvalRunner(
          dispatcher: dispatcher,
          loadAsset: loadSynthetic,
          steps: steps,
        );
        final recorded = <WatchTrial>[];
        final done = runner.run(synthetic(), onTrial: recorded.add);
        await pumpEventQueue();
        dispatcher.answer(0, verdictJson('ready'));
        await pumpEventQueue();
        expect(dispatcher.tasks, hasLength(2));
        runner.cancel();
        expect(dispatcher.cancelled, [1]);
        expect(
          runner.isRunning,
          isFalse,
          reason: 'free to start again at once',
        );
        // This dispatcher cannot interrupt, so the answer still arrives late.
        dispatcher.answer(1, verdictJson('ready'));
        final trials = await done;
        expect(trials.map((t) => t.fixtureId), ['A']);
        expect(recorded.map((t) => t.fixtureId), ['A']);
      },
    );

    test(
      'a cancelled run that is still loading photos sends nothing',
      () async {
        final gate = Completer<Uint8List>();
        final dispatcher = ManualDispatcher();
        final runner = WatchEvalRunner(
          dispatcher: dispatcher,
          loadAsset: (_) => gate.future,
          steps: steps,
        );
        final done = runner.run(synthetic());
        runner.cancel();
        gate.complete(photoA);
        expect(await done, isEmpty);
        expect(dispatcher.tasks, isEmpty);
      },
    );

    test('a second run while one is in progress is refused', () async {
      final dispatcher = ManualDispatcher();
      final runner = WatchEvalRunner(
        dispatcher: dispatcher,
        loadAsset: loadSynthetic,
        steps: steps,
      );
      final first = runner.run(synthetic());
      expect(() => runner.run(synthetic()), throwsA(isA<RunInProgressError>()));
      runner.cancel();
      expect(await first, isEmpty);
      expect(dispatcher.tasks, isEmpty);
    });
  });

  group('through the real dispatcher (fakes for the model)', () {
    DefaultHybridDispatcher dispatcherFor(FakeHybridInference bridge) =>
        DefaultHybridDispatcher(
          inference: bridge,
          privacy: InMemoryPrivacyPreferences(),
          cloudRoutes: const CloudRoutes({}),
          consent: FakeConsentGate(),
          ledger: InferenceLedger(sessionId: 'ledger'),
        );

    test(
      'answers come from the on-device leg and no photo is uploaded',
      () async {
        final bridge = FakeHybridInference()
          ..enqueueText(verdictJson('ready', see: 'Coarse chunks.'))
          ..enqueueText(verdictJson('not_yet', direction: 'less'));
        final trials = await WatchEvalRunner(
          dispatcher: dispatcherFor(bridge),
          loadAsset: loadSynthetic,
          steps: steps,
        ).run(synthetic());
        expect(
          trials.map((t) => t.outcome),
          everyElement(TrialOutcome.answered),
        );
        expect(bridge.requests, hasLength(2));
        expect(
          bridge.requests.map((r) => r.mode),
          everyElement(HybridMode.onlyOnDevice),
          reason: 'local_watch is forced on-device by the policy',
        );
        final report = WatchEvalReport(
          fixtures: synthetic(),
          trials: trials,
          observations: const {},
          context: WatchEvalContext(
            hardware: 'test',
            platform: 'test',
            scorer: 'test',
            buildSha: 'test',
            startedAt: DateTime(2026),
            finishedAt: DateTime(2026),
          ),
        );
        expect(report.framesUploaded, 0);
        expect(report.framesMaybeUploaded, 0);
        expect(
          trials.expand((t) => t.legs).map((l) => l.provenance),
          everyElement('sdkOnDevice'),
        );
      },
    );

    test(
      'with no local vision the photo is blocked, never sent to the cloud',
      () async {
        final bridge = FakeHybridInference(
          imageAvailability: const HybridAvailability(
            status: OnDeviceStatus.unavailable,
          ),
        );
        final trials = await WatchEvalRunner(
          dispatcher: dispatcherFor(bridge),
          loadAsset: loadSynthetic,
          steps: steps,
        ).run(synthetic());
        expect(
          trials.map((t) => t.outcome),
          everyElement(TrialOutcome.blocked),
        );
        expect(
          trials.expand((t) => t.legs).where((l) => l.uploadedImage),
          isEmpty,
        );
      },
    );
  });
}
