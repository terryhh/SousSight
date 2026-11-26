// SS-075: predeclared scoring for the on-device watch against the labelled
// reference photos in assets/reference-cooking/ (DESIGN.md §6 SS-075).
//
// The rules in this file are fixed before any run. Changing them after
// seeing results invalidates that run: bump [kWatchScoringVersion] and rerun.
//
// Nothing here calls a model. The runner (watch_eval_runner.dart) produces
// [WatchTrial]s; a human adds observation marks; this file turns both into
// the report. Every number in the report is counted from trials, never
// estimated, and every rate carries its denominator.
import 'dart:convert';

import 'package:soussight/watch/watch_verdict.dart';

/// Identifies the scoring rules below. Printed in every report.
const kWatchScoringVersion = 'ss075-v1';

/// What the fixture's `expectedOutcome` means for the watch's verdict class.
enum ExpectedOutcome { matchesTarget, adjust, needBetterView }

/// What the cook would do next after reading the watch's message. Derived
/// from [WatchState] and [WatchDirection] exactly as [WatchVerdict.message]
/// words them.
enum CookAction {
  /// `ready`: "This looks like the cue… have a look yourself before moving on".
  moveOn,

  /// `not_yet` with `more` ("keep going") or `none` ("Not at the cue yet").
  keepGoing,

  /// `not_yet` with `less`: "It may be past the cue — have a look".
  stopAndLook,

  /// `unsure`: "Move the camera closer, clear steam or hands, or add light".
  reframe,
}

CookAction cookActionFor(WatchState state, WatchDirection direction) =>
    switch (state) {
      WatchState.ready => CookAction.moveOn,
      WatchState.unsure => CookAction.reframe,
      WatchState.notYet =>
        direction == WatchDirection.less
            ? CookAction.stopAndLook
            : CookAction.keepGoing,
    };

/// Part 1, verdict class: matchesTarget ↔ ready, needBetterView ↔ unsure,
/// adjust ↔ not_yet.
WatchState expectedState(ExpectedOutcome outcome) => switch (outcome) {
  ExpectedOutcome.matchesTarget => WatchState.ready,
  ExpectedOutcome.adjust => WatchState.notYet,
  ExpectedOutcome.needBetterView => WatchState.unsure,
};

/// Part 3, action: the cook actions that count as correct for a fixture.
///
/// `fine_as_is` is the over-mashed bowl: mashing more cannot fix it, so
/// "keep going" is wrong; stopping to look or moving on are both right.
/// An adjustment id missing from this table is rejected when fixtures are
/// parsed, so a new label can never be scored by accident.
const Map<String, Set<CookAction>> kAcceptedActionsByAdjustment = {
  'mash_more': {CookAction.keepGoing},
  'fold_more': {CookAction.keepGoing},
  'fold_from_bottom': {CookAction.keepGoing},
  'fine_as_is': {CookAction.stopAndLook, CookAction.moveOn},
};

Set<CookAction> acceptedActions(WatchFixture fixture) =>
    switch (fixture.expectedOutcome) {
      ExpectedOutcome.matchesTarget => const {CookAction.moveOn},
      ExpectedOutcome.needBetterView => const {CookAction.reframe},
      ExpectedOutcome.adjust =>
        kAcceptedActionsByAdjustment[fixture.expectedAdjustmentId]!,
    };

/// One labelled photo from `fixtures.json`. Read only; never modified.
class WatchFixture {
  const WatchFixture({
    required this.fixtureId,
    required this.checkpointId,
    required this.stepId,
    required this.assetPath,
    required this.sha256,
    required this.expectedOutcome,
    required this.expectedAdjustmentId,
    required this.expectedObservations,
  });

  final String fixtureId;
  final String checkpointId;
  final String stepId;
  final String assetPath;

  /// Lowercase hex SHA-256 of the photo; the runner refuses a mismatch.
  final String sha256;
  final ExpectedOutcome expectedOutcome;
  final String? expectedAdjustmentId;
  final List<String> expectedObservations;

  /// The two `needBetterView` photos: the only correct verdict is to abstain.
  bool get isObscured => expectedOutcome == ExpectedOutcome.needBetterView;
}

/// Parses `assets/reference-cooking/fixtures.json`. Throws [FormatException]
/// on anything this scoring version does not understand, rather than
/// skipping or guessing.
List<WatchFixture> parseWatchFixtures(String source) {
  final Object? root = jsonDecode(source);
  if (root is! Map || root['schemaVersion'] != 1) {
    throw const FormatException('fixtures.json: expected schemaVersion 1');
  }
  final list = root['fixtures'];
  if (list is! List || list.isEmpty) {
    throw const FormatException('fixtures.json: no fixtures');
  }
  final seen = <String>{};
  final fixtures = <WatchFixture>[];
  for (final raw in list) {
    if (raw is! Map) throw const FormatException('fixtures.json: bad entry');
    String text(String key) {
      final value = raw[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('fixtures.json: "$key" missing or empty');
      }
      return value;
    }

    final id = text('fixtureId');
    if (!seen.add(id)) {
      throw FormatException('fixtures.json: duplicate fixture $id');
    }
    final outcome = switch (raw['expectedOutcome']) {
      'matchesTarget' => ExpectedOutcome.matchesTarget,
      'adjust' => ExpectedOutcome.adjust,
      'needBetterView' => ExpectedOutcome.needBetterView,
      final other => throw FormatException(
        'fixtures.json: $id has unknown expectedOutcome "$other"',
      ),
    };
    final adjustment = raw['expectedAdjustmentId'];
    if (adjustment != null && adjustment is! String) {
      throw FormatException(
        'fixtures.json: $id has a bad expectedAdjustmentId',
      );
    }
    if (outcome == ExpectedOutcome.adjust &&
        !kAcceptedActionsByAdjustment.containsKey(adjustment)) {
      throw FormatException(
        'fixtures.json: $id has adjustment "$adjustment", which '
        '$kWatchScoringVersion has no predeclared action for',
      );
    }
    if (outcome != ExpectedOutcome.adjust && adjustment != null) {
      throw FormatException(
        'fixtures.json: $id is $outcome but names an adjustment',
      );
    }
    final observations = raw['expectedObservations'];
    if (observations is! List ||
        observations.isEmpty ||
        observations.any((o) => o is! String)) {
      throw FormatException('fixtures.json: $id has no expectedObservations');
    }
    final hash = text('sha256').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw FormatException('fixtures.json: $id has a malformed sha256');
    }
    fixtures.add(
      WatchFixture(
        fixtureId: id,
        checkpointId: text('checkpointId'),
        stepId: text('stepId'),
        assetPath: text('assetPath'),
        sha256: hash,
        expectedOutcome: outcome,
        expectedAdjustmentId: adjustment as String?,
        expectedObservations: List.unmodifiable(observations.cast<String>()),
      ),
    );
  }
  return List.unmodifiable(fixtures);
}

/// How one trial ended.
enum TrialOutcome {
  /// The model answered; [WatchTrial.state] is the parsed verdict.
  answered,

  /// The dispatcher refused to run it ([WatchTrial.blockedReason] says why).
  blocked,

  /// The send threw or timed out.
  failed,
}

/// One attempt from the dispatcher, reduced to what the report needs.
class TrialLeg {
  const TrialLeg({
    required this.provenance,
    required this.transferPermitted,
    required this.carriedImage,
    this.modelLabel,
    this.error,
  });

  /// `Provenance.name`: sdkOnDevice, sdkCloud, cloudAdapter, simulated, unknown.
  final String provenance;
  final bool transferPermitted;
  final bool carriedImage;
  final String? modelLabel;
  final String? error;

  /// The leg proves the photo left the device.
  bool get uploadedImage =>
      carriedImage &&
      (provenance == 'sdkCloud' || provenance == 'cloudAdapter');

  /// Unknown where it ran, but a transfer was allowed: report "may have".
  bool get mayHaveUploadedImage =>
      carriedImage && provenance == 'unknown' && transferPermitted;

  Map<String, Object?> toJson() => {
    'provenance': provenance,
    'transferPermitted': transferPermitted,
    'carriedImage': carriedImage,
    if (modelLabel != null) 'modelLabel': modelLabel,
    if (error != null) 'error': error,
  };
}

/// One fixture run once through the watch's dispatcher call.
class WatchTrial {
  const WatchTrial({
    required this.fixtureId,
    required this.attempt,
    required this.outcome,
    required this.latency,
    required this.legs,
    this.state,
    this.direction,
    this.whatISee,
    this.redacted = false,
    this.rawText,
    this.blockedReason,
    this.error,
  });

  final String fixtureId;

  /// 1-based repeat number for this fixture.
  final int attempt;
  final TrialOutcome outcome;

  /// From just before the dispatcher call to its result.
  final Duration latency;
  final List<TrialLeg> legs;

  /// Parsed with the app's own [parseWatchJson]; malformed output is `unsure`.
  final WatchState? state;
  final WatchDirection? direction;
  final String? whatISee;
  final bool redacted;
  final String? rawText;
  final String? blockedReason;
  final String? error;

  bool get answered => outcome == TrialOutcome.answered;
  CookAction? get action => answered ? cookActionFor(state!, direction!) : null;
  String get key => '$fixtureId#$attempt';

  Map<String, Object?> toJson() => {
    'fixtureId': fixtureId,
    'attempt': attempt,
    'outcome': outcome.name,
    'latencyMs': latency.inMilliseconds,
    if (state != null) 'state': state!.name,
    if (direction != null) 'direction': direction!.name,
    if (whatISee != null) 'whatISee': whatISee,
    'redacted': redacted,
    if (rawText != null) 'rawText': rawText,
    if (blockedReason != null) 'blockedReason': blockedReason,
    if (error != null) 'error': error,
    'legs': [for (final leg in legs) leg.toJson()],
  };
}

/// Part 2 is scored by a person: does `whatISee` state the fixture's
/// expected observable fact and not its opposite?
enum ObservationMark { pass, fail }

/// Who ran it, on what, from which build. Reported as entered; an empty
/// field is printed as "not recorded" and makes the report incomplete.
class WatchEvalContext {
  const WatchEvalContext({
    required this.hardware,
    required this.platform,
    required this.scorer,
    required this.buildSha,
    required this.startedAt,
    required this.finishedAt,
  });

  /// Device, OS and browser, e.g. "Pixel 9, Android 16, Chrome 142".
  final String hardware;
  final String platform;

  /// The person who scored the observations.
  final String scorer;
  final String buildSha;
  final DateTime startedAt;
  final DateTime finishedAt;

  List<String> get missing => [
    if (hardware.trim().isEmpty) 'hardware',
    if (platform.trim().isEmpty) 'platform',
    if (scorer.trim().isEmpty) 'scorer',
    if (buildSha.trim().isEmpty || buildSha == 'unknown') 'build SHA',
  ];
}

/// A count with its denominator. Never rendered as a bare percentage.
class Tally {
  const Tally(this.hits, this.total);
  final int hits;
  final int total;
  @override
  String toString() => '$hits/$total';
  Map<String, int> toJson() => {'hits': hits, 'total': total};
}

class LatencySummary {
  const LatencySummary(this.samples);

  /// Milliseconds of answered trials only, in run order.
  final List<int> samples;

  int get n => samples.length;
  List<int> get _sorted => [...samples]..sort();
  int? get minMs => n == 0 ? null : _sorted.first;
  int? get maxMs => n == 0 ? null : _sorted.last;

  /// Lower median for an even count, so it is always a measured sample.
  int? get medianMs => n == 0 ? null : _sorted[(n - 1) ~/ 2];

  Map<String, Object?> toJson() => {
    'n': n,
    'minMs': minMs,
    'medianMs': medianMs,
    'maxMs': maxMs,
  };
}

/// Scores every trial against its fixture and adds up the parts.
class WatchEvalReport {
  WatchEvalReport({
    required this.fixtures,
    required this.trials,
    required this.observations,
    required this.context,
  }) {
    final ids = {for (final f in fixtures) f.fixtureId};
    for (final trial in trials) {
      if (!ids.contains(trial.fixtureId)) {
        throw ArgumentError('Trial for unknown fixture ${trial.fixtureId}');
      }
    }
  }

  final List<WatchFixture> fixtures;
  final List<WatchTrial> trials;

  /// Keyed by [WatchTrial.key]. An answered trial with no mark is
  /// "unscored", which counts as not passing. A blocked or failed trial has
  /// no sentence to score and is always [ObservationMark.fail].
  final Map<String, ObservationMark> observations;
  final WatchEvalContext context;

  WatchFixture fixtureOf(WatchTrial trial) =>
      fixtures.firstWhere((f) => f.fixtureId == trial.fixtureId);

  bool verdictCorrect(WatchTrial t) =>
      t.answered && t.state == expectedState(fixtureOf(t).expectedOutcome);

  bool actionCorrect(WatchTrial t) =>
      t.answered && acceptedActions(fixtureOf(t)).contains(t.action);

  ObservationMark? observationOf(WatchTrial t) =>
      t.answered ? observations[t.key] : ObservationMark.fail;

  Iterable<WatchTrial> get _obscured =>
      trials.where((t) => fixtureOf(t).isObscured);
  Iterable<WatchTrial> get _clear =>
      trials.where((t) => !fixtureOf(t).isObscured);

  Tally get verdict =>
      Tally(trials.where(verdictCorrect).length, trials.length);
  Tally get observation => Tally(
    trials.where((t) => observationOf(t) == ObservationMark.pass).length,
    trials.length,
  );
  Tally get action => Tally(trials.where(actionCorrect).length, trials.length);

  /// Observation marks entered so far, over all trials.
  Tally get observationsScored => Tally(
    trials.where((t) => observationOf(t) != null).length,
    trials.length,
  );

  /// Obscured photos where the watch said `unsure`.
  Tally get correctAbstentions => Tally(
    _obscured.where((t) => t.answered && t.state == WatchState.unsure).length,
    _obscured.length,
  );

  /// Clear photos where the watch said `unsure` anyway.
  Tally get unneededAbstentions => Tally(
    _clear.where((t) => t.answered && t.state == WatchState.unsure).length,
    _clear.length,
  );

  /// Obscured photos where the watch claimed `ready`: the unsafe miss.
  Tally get readyOnObscured => Tally(
    _obscured.where((t) => t.answered && t.state == WatchState.ready).length,
    _obscured.length,
  );

  Tally get answeredTrials =>
      Tally(trials.where((t) => t.answered).length, trials.length);

  int get redactedAnswers => trials.where((t) => t.redacted).length;

  LatencySummary get latency => LatencySummary([
    for (final t in trials)
      if (t.answered) t.latency.inMilliseconds,
  ]);

  /// Photos a leg proves were uploaded.
  int get framesUploaded =>
      trials.expand((t) => t.legs).where((leg) => leg.uploadedImage).length;

  /// Legs of unknown provenance that were allowed to transfer the photo.
  int get framesMaybeUploaded => trials
      .expand((t) => t.legs)
      .where((leg) => leg.mayHaveUploadedImage)
      .length;

  Set<String> get modelLabels => {
    for (final leg in trials.expand((t) => t.legs))
      if (leg.modelLabel != null) leg.modelLabel!,
  };

  /// Where the answers came from, counted from the final leg of each
  /// answered trial. A simulated leg means the run is not model evidence.
  String get evidenceLevel {
    final counts = <String, int>{};
    for (final t in trials) {
      if (!t.answered || t.legs.isEmpty) continue;
      counts.update(t.legs.last.provenance, (n) => n + 1, ifAbsent: () => 1);
    }
    if (counts.isEmpty) return 'not measured';
    final parts = (counts.keys.toList()..sort())
        .map((k) => '$k ${counts[k]}')
        .join(', ');
    if (counts.containsKey('simulated')) {
      return 'simulated ($parts): fakes only, not evidence of the real model';
    }
    if (counts.length == 1 && counts.containsKey('sdkOnDevice')) {
      return 'on-device model, from the inference legs ($parts); hardware '
          'as recorded above';
    }
    return 'mixed, from the inference legs ($parts)';
  }

  /// A report is publishable only when every trial has an observation mark
  /// and the context names hardware, platform, scorer and build.
  bool get complete =>
      trials.isNotEmpty &&
      observationsScored.hits == trials.length &&
      context.missing.isEmpty;

  String get uploadSummary {
    if (trials.isEmpty) return 'not measured';
    final legs = trials.expand((t) => t.legs).length;
    final maybe = framesMaybeUploaded;
    return '$framesUploaded of ${trials.length} photos (from $legs legs)'
        '${maybe == 0 ? '' : '; $maybe more may have been uploaded'}';
  }

  Map<String, Object?> toJson() => {
    'scoringVersion': kWatchScoringVersion,
    'complete': complete,
    'context': {
      'hardware': context.hardware,
      'platform': context.platform,
      'scorer': context.scorer,
      'buildSha': context.buildSha,
      'startedAt': context.startedAt.toUtc().toIso8601String(),
      'finishedAt': context.finishedAt.toUtc().toIso8601String(),
      'missing': context.missing,
    },
    'summary': {
      'verdict': verdict.toJson(),
      'observation': observation.toJson(),
      'observationsScored': observationsScored.toJson(),
      'action': action.toJson(),
      'answered': answeredTrials.toJson(),
      'correctAbstentions': correctAbstentions.toJson(),
      'unneededAbstentions': unneededAbstentions.toJson(),
      'readyOnObscured': readyOnObscured.toJson(),
      'redactedAnswers': redactedAnswers,
      'latency': latency.toJson(),
      'framesUploaded': framesUploaded,
      'framesMaybeUploaded': framesMaybeUploaded,
      'modelLabels': modelLabels.toList()..sort(),
      'evidenceLevel': evidenceLevel,
    },
    'trials': [
      for (final t in trials)
        {
          ...t.toJson(),
          'verdictCorrect': verdictCorrect(t),
          'actionCorrect': actionCorrect(t),
          'observation': observationOf(t)?.name ?? 'unscored',
        },
    ],
  };

  /// The Markdown pasted into docs/buildhybridai/EVIDENCE.md.
  String toMarkdown() {
    String orMissing(String v) => v.trim().isEmpty ? '_not recorded_' : v;
    String ms(int? v) => v == null ? 'not measured' : '$v ms';
    final b = StringBuffer()
      ..writeln('### Watch evaluation run ($kWatchScoringVersion)')
      ..writeln()
      ..writeln(
        complete
            ? '**Status:** complete.'
            : '**Status:** INCOMPLETE — do not publish these numbers until '
                  'every observation is scored and hardware, platform, scorer '
                  'and build are recorded.',
      )
      ..writeln()
      ..writeln('- **Hardware:** ${orMissing(context.hardware)}')
      ..writeln('- **Platform:** ${orMissing(context.platform)}')
      ..writeln('- **Observation scorer:** ${orMissing(context.scorer)}')
      ..writeln(
        '- **Build:** ${context.buildSha == 'unknown' ? '_not recorded_' : context.buildSha}',
      )
      ..writeln(
        '- **Model:** ${modelLabels.isEmpty ? '_not reported by the bridge_' : (modelLabels.toList()..sort()).join(', ')}',
      )
      ..writeln(
        '- **Run:** ${context.startedAt.toUtc().toIso8601String()} → '
        '${context.finishedAt.toUtc().toIso8601String()}',
      )
      ..writeln('- **Evidence level:** $evidenceLevel')
      ..writeln()
      ..writeln('| Measure | Result |')
      ..writeln('|---|---|')
      ..writeln('| Verdict class correct | $verdict |')
      ..writeln(
        '| Observation correct (human-scored) | $observation '
        '(${observationsScored.hits} scored) |',
      )
      ..writeln('| Next action correct | $action |')
      ..writeln('| Answered (not blocked or failed) | $answeredTrials |')
      ..writeln(
        '| Correct abstentions on obscured photos | $correctAbstentions |',
      )
      ..writeln('| `ready` on an obscured photo | $readyOnObscured |')
      ..writeln('| Abstained on a clear photo | $unneededAbstentions |')
      ..writeln(
        '| Answers redacted for an unsupported claim | $redactedAnswers |',
      )
      ..writeln(
        '| Latency, answered trials (n=${latency.n}) | min ${ms(latency.minMs)} · '
        'median ${ms(latency.medianMs)} · max ${ms(latency.maxMs)} |',
      )
      ..writeln('| Photos uploaded (from inference legs) | $uploadSummary |')
      ..writeln()
      ..writeln(
        '| Fixture | Try | Expected | Got | Verdict | Action | Observation | '
        'Latency | What the watch said |',
      )
      ..writeln('|---|---|---|---|---|---|---|---|---|');
    for (final t in trials) {
      final f = fixtureOf(t);
      final expected = f.expectedAdjustmentId == null
          ? f.expectedOutcome.name
          : '${f.expectedOutcome.name} (${f.expectedAdjustmentId})';
      final got = switch (t.outcome) {
        TrialOutcome.answered =>
          t.state == WatchState.notYet
              ? 'not_yet/${t.direction!.name}'
              : t.state!.name,
        TrialOutcome.blocked => 'blocked: ${t.blockedReason ?? 'unknown'}',
        TrialOutcome.failed => 'failed: ${t.error ?? 'unknown'}',
      };
      final said = (t.whatISee ?? '').replaceAll('|', r'\|');
      b.writeln(
        '| ${f.fixtureId} | ${t.attempt} | $expected | $got | '
        '${verdictCorrect(t) ? '✓' : '✗'} | ${actionCorrect(t) ? '✓' : '✗'} | '
        '${observationOf(t)?.name ?? 'unscored'} | '
        '${t.answered ? '${t.latency.inMilliseconds} ms' : '—'} | '
        '${said.isEmpty ? '—' : said}${t.redacted ? ' _(redacted)_' : ''} |',
      );
    }
    return b.toString();
  }
}
