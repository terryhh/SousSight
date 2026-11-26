// SS-072 offline step changes. Everything here runs against in-memory fakes
// (FakeSessionRepository, FakeHybridDispatcher); no Firestore, network or
// model is involved. The Firestore transaction body is covered through the
// pure `stepOpTransaction` it calls, not against a Firestore emulator.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/core/analytics.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/data/offline_ops.dart';
import 'package:soussight/data/offline_ops_banner.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/live/live_types.dart';

const _recipe = Recipe(
  id: 'test-wrap',
  version: 1,
  title: 'Chickpea wrap',
  summary: 'A simple wrap.',
  ingredients: [Ingredient(id: 'chickpeas', name: 'Chickpeas', qty: '1 can')],
  equipment: ['bowl'],
  steps: [
    RecipeStep(
      id: 'prep',
      title: 'Prepare',
      instruction: 'Drain the chickpeas.',
      cue: 'No excess liquid.',
    ),
    RecipeStep(
      id: 'mash',
      title: 'Mash',
      instruction: 'Mash with a fork.',
      cue: 'Small chunks remain.',
      timerSeconds: 60,
    ),
    RecipeStep(
      id: 'mix',
      title: 'Mix',
      instruction: 'Add yogurt.',
      cue: 'Evenly coated.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

CookingSession _session({
  String step = 'prep',
  List<String> completed = const [],
  int revision = 0,
}) => CookingSession(
  id: 's1',
  learnerId: 'cook',
  recipeId: _recipe.id,
  recipeVersion: 1,
  ingredients: const {},
  substitutions: const [],
  currentStepId: step,
  completedStepIds: completed,
  revision: revision,
  createdAt: DateTime.utc(2026, 11, 25),
  updatedAt: DateTime.utc(2026, 11, 25),
);

StepOp _op(
  String id,
  StepOpKind kind,
  String from,
  String to, {
  OpTimer? timer,
}) => StepOp(
  opId: id,
  kind: kind,
  expectedStepId: from,
  toStepId: to,
  timer: timer,
);

/// The server: a session store whose step saves follow the same transaction
/// rule as Firestore, with its own applied-id list. It can hold a save in
/// flight, lose the acknowledgement of a save it applied, and push a stale
/// (cached) snapshot.
class _Server extends FakeSessionRepository implements StepOpStore {
  final List<String> appliedOpIds = [];
  final List<StepOp> applied = [];
  final List<StepOpOutcome> outcomes = [];
  final _injected = StreamController<CookingSession>.broadcast();
  int plainUpdates = 0;
  Completer<void>? gate;
  bool loseNextAck = false;
  DateTime now = DateTime.utc(2026, 11, 25, 18);

  @override
  Future<CookingSession> update(
    String sessionId,
    CookingSession Function(CookingSession current) mutate,
  ) {
    plainUpdates++;
    return super.update(sessionId, mutate);
  }

  @override
  Future<StepOpCommit> commitStepOp(String sessionId, StepOp op) async {
    await gate?.future;
    late StepOpDecision decision;
    final saved = await super.update(sessionId, (current) {
      decision = decideStepOp(op, current, appliedOpIds, now: now);
      return decision.next ?? current;
    });
    outcomes.add(decision.outcome);
    if (decision.next != null) {
      appliedOpIds
        ..clear()
        ..addAll(decision.appliedOpIds);
      applied.add(op);
    }
    if (loseNextAck) {
      loseNextAck = false;
      throw StateError('Connection lost before the acknowledgement');
    }
    return StepOpCommit(decision.outcome, saved);
  }

  void pushStale(CookingSession snapshot) => _injected.add(snapshot);

  @override
  Stream<CookingSession> watch(String sessionId) {
    final out = StreamController<CookingSession>();
    final subs = <StreamSubscription<CookingSession>>[];
    out
      ..onListen = () {
        subs
          ..add(super.watch(sessionId).listen(out.add))
          ..add(
            _injected.stream.where((s) => s.id == sessionId).listen(out.add),
          );
      }
      ..onCancel = () async {
        for (final sub in subs) {
          await sub.cancel();
        }
      };
    return out.stream;
  }
}

class _Media implements LiveMedia {
  @override
  Stream<Uint8List> get frames => const Stream.empty();
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

class _Research implements CookingResearchClient {
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) =>
      throw StateError('No research in these tests');
}

class _Privacy implements PrivacySettings {
  @override
  bool localOnly(String feature) => false;
}

String _liteJson() => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['tip'],
    },
    {
      'id': 'tip',
      'component': 'stepCue',
      'title': 'Keep some texture',
      'body': 'Stop when a few small chunks remain.',
    },
  ],
});

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Fixture {
  _Fixture() {
    cook = CookingCoordinator(
      services: AppServices(
        auth: FakeAuthService(),
        recipes: FakeRecipeRepository(_recipe),
        sessions: server,
        bundledRecipe: _recipe,
        clock: () => now,
        analytics: analytics,
      ),
      research: _Research(),
      transportFactory: null, // Live off: typed questions go to Coach Lite.
      media: _Media(),
      coachLite: CoachLite(
        dispatcher: dispatcher,
        privacy: _Privacy(),
        cloudRoutes: const CloudRoutes({}),
        isOnline: () => online,
      ),
      isOnline: () => online,
      connectivityChanges: connectivity.stream,
      stepSaveRetryDelay: const Duration(milliseconds: 20),
    );
  }

  final server = _Server();
  final dispatcher = FakeHybridDispatcher();
  final analytics = RecordingAnalytics();
  final connectivity = StreamController<void>.broadcast();
  DateTime now = DateTime.utc(2026, 11, 25, 18);
  bool online = true;
  late final CookingCoordinator cook;

  Future<void> initialize() async {
    await cook.initialize();
    await _flush();
  }

  Future<void> setOnline(bool value) async {
    online = value;
    connectivity.add(null);
    await _flush();
  }

  Future<CookingSession> saved() => server.watch(cook.session!.id).first;

  Future<void> dispose() async {
    cook.dispose();
    await connectivity.close();
  }
}

void main() {
  group('decideStepOp (the transaction rule)', () {
    final now = DateTime.utc(2026, 11, 25, 19);

    test('applies once, bumps revision and records the op id', () {
      final decision = decideStepOp(
        _op('a', StepOpKind.advance, 'prep', 'mash'),
        _session(revision: 4),
        const [],
        now: now,
      );
      expect(decision.outcome, StepOpOutcome.applied);
      expect(decision.next!.currentStepId, 'mash');
      expect(decision.next!.completedStepIds, ['prep']);
      expect(decision.next!.revision, 5);
      expect(decision.next!.updatedAt, now);
      expect(decision.appliedOpIds, ['a']);
    });

    test('an op id already saved writes nothing', () {
      final decision = decideStepOp(
        _op('a', StepOpKind.advance, 'prep', 'mash'),
        _session(),
        const ['a'],
        now: now,
      );
      expect(decision.outcome, StepOpOutcome.duplicate);
      expect(decision.next, isNull);
    });

    test('a step that no longer matches is dropped as stale', () {
      final decision = decideStepOp(
        _op('b', StepOpKind.advance, 'prep', 'mash'),
        _session(step: 'mix', completed: ['prep', 'mash']),
        const ['a'],
        now: now,
      );
      expect(decision.outcome, StepOpOutcome.stale);
      expect(decision.next, isNull);
    });

    test('completing an already completed last step is a duplicate, even '
        'under a new op id', () {
      final decision = decideStepOp(
        _op('c', StepOpKind.complete, 'mix', 'mix'),
        _session(step: 'mix', completed: ['prep', 'mash', 'mix']),
        const [],
        now: now,
      );
      expect(decision.outcome, StepOpOutcome.duplicate);
    });

    test('the timer end time travels in the op unchanged', () {
      final endsAt = DateTime.utc(2026, 11, 25, 18, 1);
      final decision = decideStepOp(
        _op(
          'a',
          StepOpKind.advance,
          'prep',
          'mash',
          timer: OpTimer(id: 't', label: 'Mash', endsAt: endsAt),
        ),
        _session(),
        const [],
        now: now,
      );
      expect(decision.next!.timerDeadline, endsAt);
      expect(decision.next!.timerId, 't');
    });

    test('the applied id list stays bounded, newest kept', () {
      final full = [for (var i = 0; i < maxAppliedOpIds; i++) 'old-$i'];
      final decision = decideStepOp(
        _op('new', StepOpKind.advance, 'prep', 'mash'),
        _session(),
        full,
        now: now,
      );
      expect(decision.appliedOpIds, hasLength(maxAppliedOpIds));
      expect(decision.appliedOpIds.first, 'old-1');
      expect(decision.appliedOpIds.last, 'new');
    });
  });

  group('Firestore transaction body', () {
    test('writes the session with appliedOpIds, and nothing for a repeat', () {
      final stored = _session().toMap();
      final op = _op('a', StepOpKind.advance, 'prep', 'mash');
      final first = stepOpTransaction(
        's1',
        stored,
        op,
        now: DateTime.utc(2026),
      );
      expect(first.commit.outcome, StepOpOutcome.applied);
      expect(first.write![appliedOpIdsField], ['a']);
      expect(first.write!['currentStepId'], 'mash');
      final again = stepOpTransaction(
        's1',
        first.write!,
        op,
        now: DateTime.utc(2026),
      );
      expect(again.commit.outcome, StepOpOutcome.duplicate);
      expect(again.write, isNull);
    });

    test('an ordinary update keeps the stored op ids; malformed ids are '
        'ignored', () {
      final next = _session(revision: 2).toMap();
      expect(
        keepAppliedOpIds({
          appliedOpIdsField: ['a', 'b'],
        }, next)[appliedOpIdsField],
        ['a', 'b'],
      );
      expect(
        keepAppliedOpIds(null, next).containsKey(appliedOpIdsField),
        isFalse,
      );
      expect(readAppliedOpIds({appliedOpIdsField: 'a'}), isEmpty);
      expect(
        readAppliedOpIds({
          appliedOpIdsField: ['a', 3],
        }),
        ['a'],
      );
    });
  });

  group('OfflineStepQueue', () {
    test('re-applies pending changes over any snapshot, in order', () {
      var id = 0;
      final queue = OfflineStepQueue(
        store: RepositoryStepOpStore(FakeSessionRepository()),
        isOnline: () => false,
        newOpId: () => 'op-${id++}',
      )..bind('s1');
      addTearDown(queue.dispose);
      queue
        ..enqueue(
          kind: StepOpKind.advance,
          expectedStepId: 'prep',
          toStepId: 'mash',
        )
        ..enqueue(
          kind: StepOpKind.advance,
          expectedStepId: 'mash',
          toStepId: 'mix',
        );
      // A cached snapshot from before both changes.
      expect(queue.overlay(_session()).currentStepId, 'mix');
      // A snapshot that already has the first change.
      final partly = queue.overlay(
        _session(step: 'mash', completed: ['prep'], revision: 1),
      );
      expect(partly.currentStepId, 'mix');
      expect(partly.completedStepIds, ['prep', 'mash']);
      expect(partly.revision, 2);
    });

    test('a timer joins the unsent step change and can be dismissed', () {
      final queue = OfflineStepQueue(
        store: RepositoryStepOpStore(FakeSessionRepository()),
        isOnline: () => false,
      )..bind('s1');
      addTearDown(queue.dispose);
      final op = queue.enqueue(
        kind: StepOpKind.advance,
        expectedStepId: 'prep',
        toStepId: 'mash',
      );
      final timer = OpTimer(id: 't', label: 'Mash', endsAt: DateTime.utc(2026));
      queue.recordTimer(timer);
      expect(op.timer, same(timer));
      expect(queue.dismissTimer('t'), isTrue);
      expect(op.timer, isNull);
      expect(queue.overlay(_session()).timerId, isNull);
    });
  });

  group('cooking session with the connection cut', () {
    late _Fixture f;
    setUp(() async {
      f = _Fixture();
      await f.initialize();
    });
    tearDown(() => f.dispose());

    test('Coach Lite answers, the step advances and a timer starts offline; '
        'on reconnect exactly one transition is saved with the original '
        'deadline', () async {
      await f.setOnline(false);
      expect(f.cook.offline, isTrue);

      f.dispatcher.enqueue(_liteJson());
      expect(await f.cook.say('How chunky should it be?'), isTrue);
      await _flush();
      expect(f.cook.coachLiteAnswer!.status, CoachLiteStatus.answered);

      await f.cook.advanceStep();
      expect(f.cook.step.id, 'mash');
      expect(f.cook.advancing, isFalse);
      expect(f.cook.pendingStepSaves, 1);

      await f.cook.startStepTimer();
      final deadline = f.now.add(const Duration(seconds: 60));
      expect(f.cook.ui.timers.single.deadline, deadline);
      expect(f.cook.session!.timerDeadline, deadline);
      expect(f.server.outcomes, isEmpty);
      expect(f.server.plainUpdates, 0);
      expect((await f.saved()).currentStepId, 'prep');

      // Time passes while offline; the deadline must not move.
      f.now = f.now.add(const Duration(seconds: 40));
      f.server.now = f.now;
      await f.setOnline(true);

      expect(f.server.applied, hasLength(1));
      expect(f.server.outcomes, [StepOpOutcome.applied]);
      expect(f.server.plainUpdates, 0);
      final saved = await f.saved();
      expect(saved.currentStepId, 'mash');
      expect(saved.completedStepIds, ['prep']);
      expect(saved.revision, 1);
      expect(saved.timerDeadline, deadline);
      expect(f.cook.pendingStepSaves, 0);
      expect(f.cook.step.id, 'mash');
      expect(f.cook.ui.timers.single.deadline, deadline);
      expect(f.cook.offline, isFalse);
    });

    test('a stale snapshot while a save is in flight does not roll the '
        'screen back', () async {
      f.server.gate = Completer<void>();
      final advancing = f.cook.advanceStep();
      await _flush();
      expect(f.cook.step.id, 'mash');
      // A cached snapshot from before the change arrives mid-flight.
      f.server.pushStale(_stale(f.cook.session!.id));
      await _flush();
      expect(f.cook.step.id, 'mash');
      expect(f.cook.session!.completedStepIds, ['prep']);
      f.server.gate!.complete();
      await advancing;
      await _flush();
      expect(f.cook.step.id, 'mash');
      expect(f.server.applied, hasLength(1));
      // And once saved, a late stale snapshot cannot undo it either: the
      // next real snapshot replaces it.
      expect((await f.saved()).currentStepId, 'mash');
    });

    test('a lost acknowledgement on the last step does not complete it '
        'twice', () async {
      await f.cook.advanceStep(); // prep -> mash
      await f.cook.advanceStep(); // mash -> mix
      expect(f.cook.step.id, 'mix');
      expect(f.server.applied, hasLength(2));
      final revisionBefore = (await f.saved()).revision;

      f.server.loseNextAck = true;
      await f.cook.advanceStep(); // finish mix; the server applies it
      expect(f.cook.complete, isTrue);
      expect(f.cook.pendingStepSaves, 1);
      expect(f.cook.error, CookingCoordinator.unsavedStepError);
      // The retry (20 ms later) finds the op id already saved.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _flush();

      expect(f.server.outcomes, [
        StepOpOutcome.applied,
        StepOpOutcome.applied,
        StepOpOutcome.applied,
        StepOpOutcome.duplicate,
      ]);
      expect(f.server.applied, hasLength(3));
      final saved = await f.saved();
      expect(saved.completedStepIds, ['prep', 'mash', 'mix']);
      expect(saved.revision, revisionBefore + 1);
      expect(f.cook.pendingStepSaves, 0);
      expect(f.cook.error, isNull);
      expect(f.cook.complete, isTrue);
      expect(
        f.analytics.events.where(
          (e) => e.name == AnalyticsEvents.mealCompleted,
        ),
        hasLength(1),
      );
      // A further tap is ignored: the meal is complete.
      await f.cook.advanceStep();
      expect(f.server.outcomes, hasLength(4));
    });

    test('a change made elsewhere wins: the queued change is dropped and the '
        'saved step is shown', () async {
      await f.setOnline(false);
      await f.cook.advanceStep(); // prep -> mash, queued
      // Another device finished prep and mash meanwhile.
      final id = f.cook.session!.id;
      await f.server.update(
        id,
        (s) => s.copyWith(
          currentStepId: 'mix',
          completedStepIds: ['prep', 'mash'],
          revision: s.revision + 1,
        ),
      );
      await f.setOnline(true);
      expect(f.server.outcomes, [StepOpOutcome.stale]);
      expect(f.cook.step.id, 'mix');
      expect(f.cook.pendingStepSaves, 0);
      expect(f.cook.alert, contains('changed somewhere else'));
    });

    test('a lost acknowledgement on an ordinary step is recognised by its '
        'op id, not reported as a conflict', () async {
      f.server.loseNextAck = true;
      await f.cook.advanceStep(); // applied on the server, ack lost
      expect(f.cook.pendingStepSaves, 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _flush();
      expect(f.server.outcomes, [
        StepOpOutcome.applied,
        StepOpOutcome.duplicate,
      ]);
      expect(f.cook.alert, isNull);
      expect(f.cook.step.id, 'mash');
      expect((await f.saved()).completedStepIds, ['prep']);
    });

    test('a timer started while a step save is in flight is saved after it, '
        'with its original deadline', () async {
      f.server.gate = Completer<void>();
      final advancing = f.cook.advanceStep();
      await _flush();
      await f.cook.startStepTimer();
      final deadline = f.now.add(const Duration(seconds: 60));
      expect(f.cook.session!.timerDeadline, deadline);
      f.now = f.now.add(const Duration(seconds: 10));
      f.server.gate!.complete();
      await advancing;
      await _flush();
      expect(f.server.applied.single.timer, isNull);
      expect(f.server.plainUpdates, 1);
      final saved = await f.saved();
      expect(saved.currentStepId, 'mash');
      expect(saved.timerDeadline, deadline);
      expect(f.cook.pendingStepSaves, 0);
    });

    test('a dismissed offline timer is not saved later', () async {
      await f.setOnline(false);
      await f.cook.advanceStep();
      await f.cook.startStepTimer();
      final timer = f.cook.ui.timers.single;
      f.cook.ui.dismissTimer(timer.id);
      await _flush();
      await f.setOnline(true);
      final saved = await f.saved();
      expect(saved.currentStepId, 'mash');
      expect(saved.timerDeadline, isNull);
    });
  });

  testWidgets('the offline banner says what keeps working', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: OfflineBanner(pendingSteps: 2))),
    );
    expect(find.text(offlineBannerText), findsOneWidget);
    expect(find.text('2 step changes are waiting to save.'), findsOneWidget);
  });
}

CookingSession _stale(String id) => CookingSession(
  id: id,
  learnerId: 'learner-1',
  recipeId: _recipe.id,
  recipeVersion: 1,
  ingredients: const {},
  substitutions: const [],
  currentStepId: 'prep',
  completedStepIds: const [],
  revision: 0,
  createdAt: DateTime.utc(2026, 11, 25),
  updatedAt: DateTime.utc(2026, 11, 25),
);
