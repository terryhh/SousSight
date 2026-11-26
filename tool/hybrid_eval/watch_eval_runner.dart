// SS-075: runs each reference photo through the same dispatcher call the
// on-device watch makes (LocalWatchController._task / _send), one at a time,
// and records what came back. It never scores; see watch_eval.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/payload_digest.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/watch/watch_verdict.dart';

import 'watch_eval.dart';

/// The request the watch sends for one frame, built from the same constants
/// and prompt builder. A test pins it to the controller's actual request by
/// payload digest, so the two cannot drift apart unnoticed.
HybridTask watchEvalTask(
  RecipeStep step,
  Uint8List jpeg, {
  Duration timeout = const Duration(seconds: 15),
}) => HybridTask(
  feature: kLocalWatchFeature,
  systemInstruction: kWatchSystemInstruction,
  parts: [
    HybridText(buildWatchPrompt(step)),
    HybridInlineData(jpeg, 'image/jpeg'),
  ],
  jsonSchema: kWatchSchema,
  maxOutputTokens: 96,
  timeout: timeout,
);

/// The steps of a recipe JSON (assets/recipes/*.json) by id.
Map<String, RecipeStep> recipeStepsById(String recipeJson) {
  final Object? root = jsonDecode(recipeJson);
  final steps = root is Map ? root['steps'] : null;
  if (steps is! List) throw const FormatException('recipe: no steps');
  final byId = <String, RecipeStep>{};
  for (final raw in steps) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('recipe: bad step');
    }
    final step = RecipeStep.fromMap(raw);
    byId[step.id] = step;
  }
  return byId;
}

/// A fixture photo whose bytes do not match `fixtures.json`. The run stops:
/// scoring a different photo against these labels would be meaningless.
class FixtureIntegrityError implements Exception {
  const FixtureIntegrityError(this.message);
  final String message;
  @override
  String toString() => 'FixtureIntegrityError: $message';
}

/// Raised when [WatchEvalRunner.run] is called while a run is in progress.
class RunInProgressError extends StateError {
  RunInProgressError() : super('A watch evaluation run is already in progress');
}

class WatchEvalRunner {
  WatchEvalRunner({
    required this.dispatcher,
    required this.loadAsset,
    required this.steps,
    this.timeout = const Duration(seconds: 15),
    this.attemptsPerFixture = 1,
    String Function()? newSessionId,
    Stopwatch Function()? stopwatch,
  }) : assert(attemptsPerFixture > 0),
       _newSessionId =
           newSessionId ??
           (() => 'watch-eval-${DateTime.now().microsecondsSinceEpoch}'),
       _stopwatch = stopwatch ?? Stopwatch.new;

  final HybridDispatcher dispatcher;

  /// Reads a fixture photo by its `assetPath`.
  final Future<Uint8List> Function(String assetPath) loadAsset;

  /// The recipe steps by id; each fixture's `stepId` must be here.
  final Map<String, RecipeStep> steps;
  final Duration timeout;
  final int attemptsPerFixture;
  final String Function() _newSessionId;
  final Stopwatch Function() _stopwatch;

  /// Bumped by every [run] and [cancel]. Work that awaited across a bump is
  /// abandoned and its result is never recorded.
  int _epoch = 0;

  /// The epoch of the run in progress, or null. [cancel] clears it at once,
  /// so a new run can start while the cancelled one unwinds.
  int? _activeEpoch;
  HybridOperation? _inFlight;

  bool get isRunning => _activeEpoch != null;

  /// Stops the run: cancels the send in flight and records nothing more.
  void cancel() {
    _epoch++;
    _activeEpoch = null;
    _inFlight?.cancel();
    _inFlight = null;
  }

  /// Runs every fixture [attemptsPerFixture] times, in order, one send at a
  /// time. Returns the trials recorded before any [cancel].
  ///
  /// Every photo is hashed and checked against its fixture before anything
  /// is sent; a mismatch, a missing step or an unreadable photo throws before
  /// the first send.
  Future<List<WatchTrial>> run(
    List<WatchFixture> fixtures, {
    void Function(WatchTrial trial)? onTrial,
  }) async {
    if (isRunning) throw RunInProgressError();
    final epoch = ++_epoch;
    _activeEpoch = epoch;
    bool current() => epoch == _epoch;
    final trials = <WatchTrial>[];
    try {
      final photos = <String, Uint8List>{};
      for (final fixture in fixtures) {
        if (!steps.containsKey(fixture.stepId)) {
          throw FixtureIntegrityError(
            '${fixture.fixtureId} names step "${fixture.stepId}", which the '
            'recipe does not have',
          );
        }
        final bytes = await loadAsset(fixture.assetPath);
        if (!current()) return trials;
        final digest = sha256Hex(bytes);
        if (digest != fixture.sha256) {
          throw FixtureIntegrityError(
            '${fixture.assetPath} has SHA-256 $digest, but fixtures.json '
            'declares ${fixture.sha256}',
          );
        }
        photos[fixture.fixtureId] = bytes;
      }
      // One session for the whole run, like one cook's session.
      final sessionId = _newSessionId();
      for (final fixture in fixtures) {
        for (var attempt = 1; attempt <= attemptsPerFixture; attempt++) {
          if (!current()) return trials;
          final trial = await _runOne(
            fixture,
            attempt,
            photos[fixture.fixtureId]!,
            sessionId,
            current,
          );
          if (trial == null || !current()) return trials;
          trials.add(trial);
          onTrial?.call(trial);
        }
      }
      return trials;
    } finally {
      if (current()) {
        _inFlight = null;
        _activeEpoch = null;
      }
    }
  }

  Future<WatchTrial?> _runOne(
    WatchFixture fixture,
    int attempt,
    Uint8List photo,
    String sessionId,
    bool Function() current,
  ) async {
    final task = watchEvalTask(steps[fixture.stepId]!, photo, timeout: timeout);
    final clock = _stopwatch()..start();
    // No `validate`, as in the watch: a rejected on-device answer must never
    // trigger a cloud retry with this photo.
    final operation = dispatcher.start(task, sessionId: sessionId);
    _inFlight = operation;
    DispatchResult result;
    try {
      result = await operation.result;
    } catch (error) {
      clock.stop();
      if (!current()) return null;
      _inFlight = null;
      return WatchTrial(
        fixtureId: fixture.fixtureId,
        attempt: attempt,
        outcome: TrialOutcome.failed,
        latency: clock.elapsed,
        legs: const [],
        error: '$error',
      );
    }
    clock.stop();
    if (!current()) return null;
    _inFlight = null;
    final legs = [for (final leg in result.legs) _legOf(leg)];
    if (!result.ok) {
      return WatchTrial(
        fixtureId: fixture.fixtureId,
        attempt: attempt,
        outcome: TrialOutcome.blocked,
        latency: clock.elapsed,
        legs: legs,
        blockedReason: result.blocked?.name ?? 'unknown',
      );
    }
    final parsed = parseWatchJson(result.text!);
    return WatchTrial(
      fixtureId: fixture.fixtureId,
      attempt: attempt,
      outcome: TrialOutcome.answered,
      latency: clock.elapsed,
      legs: legs,
      state: parsed.state,
      direction: parsed.direction,
      whatISee: parsed.whatISee,
      redacted: parsed.redacted,
      rawText: result.text,
    );
  }

  static TrialLeg _legOf(InferenceLeg leg) => TrialLeg(
    provenance: leg.provenance.name,
    transferPermitted: leg.transferPermitted,
    carriedImage: leg.kinds.contains(DataKind.image),
    modelLabel: leg.modelLabel,
    error: leg.error?.name,
  );
}
