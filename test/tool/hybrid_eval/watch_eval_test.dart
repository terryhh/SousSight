import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/watch/watch_verdict.dart';

import '../../../tool/hybrid_eval/watch_eval.dart';

final _realFixtures = File('assets/reference-cooking/fixtures.json');

/// A minimal valid fixtures.json with [entries] (each merged over a default).
String fixturesJson(List<Map<String, Object?>> entries, {Object? version = 1}) {
  var n = 0;
  return jsonEncode({
    'schemaVersion': version,
    'fixtures': [
      for (final e in entries)
        {
          'fixtureId': 'FIX-${++n}',
          'checkpointId': 'cp_mash',
          'stepId': 'mash',
          'assetPath': 'assets/reference-cooking/x$n.jpg',
          'sha256': 'a' * 64,
          'expectedOutcome': 'matchesTarget',
          'expectedAdjustmentId': null,
          'expectedObservations': ['A bowl.'],
          ...e,
        },
    ],
  });
}

WatchFixture fixture(
  String id,
  ExpectedOutcome outcome, {
  String? adjustment,
}) => WatchFixture(
  fixtureId: id,
  checkpointId: 'cp_mash',
  stepId: 'mash',
  assetPath: 'assets/reference-cooking/$id.jpg',
  sha256: 'a' * 64,
  expectedOutcome: outcome,
  expectedAdjustmentId: adjustment,
  expectedObservations: const ['A bowl of chickpeas.'],
);

const onDevice = TrialLeg(
  provenance: 'sdkOnDevice',
  transferPermitted: false,
  carriedImage: true,
  modelLabel: 'gemini-nano',
);

WatchTrial answered(
  String id,
  WatchState state, {
  WatchDirection direction = WatchDirection.none,
  int ms = 100,
  int attempt = 1,
  List<TrialLeg> legs = const [onDevice],
  String see = 'A bowl.',
  bool redacted = false,
}) => WatchTrial(
  fixtureId: id,
  attempt: attempt,
  outcome: TrialOutcome.answered,
  latency: Duration(milliseconds: ms),
  legs: legs,
  state: state,
  direction: direction,
  whatISee: see,
  redacted: redacted,
  rawText: '{}',
);

WatchEvalContext ctx({
  String hardware = 'Pixel 9, Android 16, Chrome 142',
  String platform = 'web',
  String scorer = 'Jenna',
  String sha = 'abc1234',
}) => WatchEvalContext(
  hardware: hardware,
  platform: platform,
  scorer: scorer,
  buildSha: sha,
  startedAt: DateTime.utc(2026, 11, 28, 10),
  finishedAt: DateTime.utc(2026, 11, 28, 10, 2),
);

/// The eight real labels, in fixtures.json order.
final eight = [
  fixture('MASH-T', ExpectedOutcome.matchesTarget),
  fixture('MASH-WHOLE', ExpectedOutcome.adjust, adjustment: 'mash_more'),
  fixture('MASH-SMOOTH', ExpectedOutcome.adjust, adjustment: 'fine_as_is'),
  fixture('MASH-OBS', ExpectedOutcome.needBetterView),
  fixture('MIX-T', ExpectedOutcome.matchesTarget),
  fixture('MIX-UNFOLDED', ExpectedOutcome.adjust, adjustment: 'fold_more'),
  fixture('MIX-POOLED', ExpectedOutcome.adjust, adjustment: 'fold_from_bottom'),
  fixture('MIX-OBS', ExpectedOutcome.needBetterView),
];

/// A run where every answer is right.
List<WatchTrial> perfect() => [
  answered('MASH-T', WatchState.ready, ms: 300),
  answered(
    'MASH-WHOLE',
    WatchState.notYet,
    direction: WatchDirection.more,
    ms: 100,
  ),
  answered(
    'MASH-SMOOTH',
    WatchState.notYet,
    direction: WatchDirection.less,
    ms: 200,
  ),
  answered('MASH-OBS', WatchState.unsure, ms: 400),
  answered('MIX-T', WatchState.ready, ms: 500),
  answered(
    'MIX-UNFOLDED',
    WatchState.notYet,
    direction: WatchDirection.more,
    ms: 600,
  ),
  answered(
    'MIX-POOLED',
    WatchState.notYet,
    direction: WatchDirection.more,
    ms: 700,
  ),
  answered('MIX-OBS', WatchState.unsure, ms: 800),
];

Map<String, ObservationMark> allPass(List<WatchTrial> trials) => {
  for (final t in trials) t.key: ObservationMark.pass,
};

void main() {
  group('fixtures.json', () {
    test('the real file parses into the eight predeclared labels', () {
      final fixtures = parseWatchFixtures(_realFixtures.readAsStringSync());
      expect(fixtures, hasLength(8));
      expect(fixtures.map((f) => f.expectedOutcome).toList(), [
        ExpectedOutcome.matchesTarget,
        ExpectedOutcome.adjust,
        ExpectedOutcome.adjust,
        ExpectedOutcome.needBetterView,
        ExpectedOutcome.matchesTarget,
        ExpectedOutcome.adjust,
        ExpectedOutcome.adjust,
        ExpectedOutcome.needBetterView,
      ]);
      expect(fixtures.where((f) => f.isObscured), hasLength(2));
      expect(
        fixtures.map((f) => f.expectedAdjustmentId).whereType<String>().toSet(),
        kAcceptedActionsByAdjustment.keys.toSet(),
        reason: 'every adjustment in the file has a predeclared action',
      );
      for (final f in fixtures) {
        expect(File(f.assetPath).existsSync(), isTrue, reason: f.assetPath);
        expect(f.stepId, anyOf('mash', 'mix'));
      }
    });

    test('rejects what this scoring version does not understand', () {
      void rejects(String source, Pattern message) => expect(
        () => parseWatchFixtures(source),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(message),
          ),
        ),
      );
      rejects(fixturesJson([{}], version: 2), 'schemaVersion');
      rejects('[]', 'schemaVersion');
      rejects(jsonEncode({'schemaVersion': 1, 'fixtures': []}), 'no fixtures');
      rejects(
        jsonEncode({
          'schemaVersion': 1,
          'fixtures': [1],
        }),
        'bad entry',
      );
      rejects(
        fixturesJson([
          {'expectedOutcome': 'ready'},
        ]),
        'unknown expectedOutcome',
      );
      rejects(
        fixturesJson([
          {'expectedOutcome': 'adjust', 'expectedAdjustmentId': 'stir_more'},
        ]),
        'no predeclared action',
      );
      rejects(
        fixturesJson([
          {'expectedOutcome': 'adjust'},
        ]),
        'no predeclared action',
      );
      rejects(
        fixturesJson([
          {'expectedAdjustmentId': 'mash_more'},
        ]),
        'names an adjustment',
      );
      rejects(
        fixturesJson([
          {'expectedAdjustmentId': 3},
        ]),
        'bad expectedAdjustmentId',
      );
      rejects(
        fixturesJson([
          {'expectedObservations': []},
        ]),
        'expectedObservations',
      );
      rejects(
        fixturesJson([
          {
            'expectedObservations': [1],
          },
        ]),
        'expectedObservations',
      );
      rejects(
        fixturesJson([
          {'sha256': 'abc'},
        ]),
        'malformed sha256',
      );
      rejects(
        fixturesJson([
          {'stepId': ' '},
        ]),
        '"stepId" missing',
      );
      rejects(
        fixturesJson([
          {'fixtureId': 'A'},
          {'fixtureId': 'A'},
        ]),
        'duplicate fixture A',
      );
    });

    test('normalises the hash to lowercase', () {
      final f = parseWatchFixtures(
        fixturesJson([
          {'sha256': 'AB' * 32},
        ]),
      ).single;
      expect(f.sha256, 'ab' * 32);
    });
  });

  group('predeclared scoring', () {
    test('verdict classes map one to one', () {
      expect(expectedState(ExpectedOutcome.matchesTarget), WatchState.ready);
      expect(expectedState(ExpectedOutcome.adjust), WatchState.notYet);
      expect(expectedState(ExpectedOutcome.needBetterView), WatchState.unsure);
    });

    test('the cook action follows the message the app actually shows', () {
      String message(WatchState s, WatchDirection d) => WatchVerdict(
        state: s,
        direction: d,
        whatISee: '',
        watchId: 'w',
        stepId: 'mash',
        sessionId: 's',
        frameCapturedAt: DateTime(2026),
        source: WatchVerdictSource.onDevice,
      ).message;
      final cases = {
        (WatchState.ready, WatchDirection.none): (
          CookAction.moveOn,
          'before moving on',
        ),
        (WatchState.notYet, WatchDirection.more): (
          CookAction.keepGoing,
          'keep going',
        ),
        (WatchState.notYet, WatchDirection.none): (
          CookAction.keepGoing,
          'Not at the cue yet',
        ),
        (WatchState.notYet, WatchDirection.less): (
          CookAction.stopAndLook,
          'past the cue',
        ),
        (WatchState.unsure, WatchDirection.none): (
          CookAction.reframe,
          'Move the camera',
        ),
      };
      cases.forEach((verdict, expected) {
        expect(cookActionFor(verdict.$1, verdict.$2), expected.$1);
        expect(message(verdict.$1, verdict.$2), contains(expected.$2));
      });
    });

    test('an over-mashed bowl must not be told to keep mashing', () {
      final smooth = eight[2];
      expect(acceptedActions(smooth), {
        CookAction.stopAndLook,
        CookAction.moveOn,
      });
      expect(acceptedActions(smooth), isNot(contains(CookAction.keepGoing)));
      expect(acceptedActions(eight[1]), {CookAction.keepGoing});
      expect(acceptedActions(eight[0]), {CookAction.moveOn});
      expect(acceptedActions(eight[3]), {CookAction.reframe});
    });
  });

  group('report', () {
    test('a perfect, fully scored run is complete and counts every part', () {
      final trials = perfect();
      final r = WatchEvalReport(
        fixtures: eight,
        trials: trials,
        observations: allPass(trials),
        context: ctx(),
      );
      expect('${r.verdict} ${r.observation} ${r.action}', '8/8 8/8 8/8');
      expect('${r.correctAbstentions}', '2/2');
      expect('${r.readyOnObscured} ${r.unneededAbstentions}', '0/2 0/6');
      expect('${r.answeredTrials}', '8/8');
      expect(r.complete, isTrue);
      expect(r.framesUploaded, 0);
      expect(r.uploadSummary, '0 of 8 photos (from 8 legs)');
      expect(r.modelLabels, {'gemini-nano'});
      expect(r.evidenceLevel, startsWith('on-device model'));
      final l = r.latency;
      expect([l.n, l.minMs, l.medianMs, l.maxMs], [8, 100, 400, 800]);
      final md = r.toMarkdown();
      expect(md, contains('**Status:** complete.'));
      expect(md, contains('| Verdict class correct | 8/8 |'));
      expect(md, contains('median 400 ms'));
      expect(
        md,
        contains(
          '| MASH-SMOOTH | 1 | adjust (fine_as_is) | not_yet/less | ✓ | ✓ | pass |',
        ),
      );
      final json = r.toJson();
      expect(json['scoringVersion'], kWatchScoringVersion);
      expect(json['complete'], isTrue);
      final summary = json['summary'] as Map<String, Object?>;
      expect(summary['verdict'], {'hits': 8, 'total': 8});
      expect(
        (json['trials'] as List).first,
        containsPair('observation', 'pass'),
      );
      expect(jsonDecode(jsonEncode(json)), isA<Map<String, dynamic>>());
    });

    test('wrong answers, blocks and failures count against every part', () {
      final trials = [
        // keep going on the over-mashed bowl: verdict right, action wrong
        answered(
          'MASH-SMOOTH',
          WatchState.notYet,
          direction: WatchDirection.more,
        ),
        // ready on an obscured photo: the unsafe miss
        answered('MASH-OBS', WatchState.ready),
        // abstained on a clear photo
        answered('MASH-T', WatchState.unsure),
        const WatchTrial(
          fixtureId: 'MIX-T',
          attempt: 1,
          outcome: TrialOutcome.blocked,
          latency: Duration(milliseconds: 5),
          legs: [],
          blockedReason: 'modelNotReady',
        ),
        const WatchTrial(
          fixtureId: 'MIX-OBS',
          attempt: 1,
          outcome: TrialOutcome.failed,
          latency: Duration(milliseconds: 9000),
          legs: [],
          error: 'timeout',
        ),
      ];
      final r = WatchEvalReport(
        fixtures: eight,
        trials: trials,
        observations: allPass(trials),
        context: ctx(),
      );
      expect('${r.verdict}', '1/5');
      expect('${r.action}', '0/5');
      expect('${r.observation}', '3/5', reason: 'no answer is never a pass');
      expect('${r.observationsScored}', '5/5');
      expect('${r.answeredTrials}', '3/5');
      expect('${r.readyOnObscured}', '1/2');
      expect('${r.correctAbstentions}', '0/2');
      expect('${r.unneededAbstentions}', '1/3');
      expect(r.latency.n, 3, reason: 'blocked and failed trials are not timed');
      expect(r.latency.medianMs, 100);
      final md = r.toMarkdown();
      expect(md, contains('blocked: modelNotReady'));
      expect(md, contains('failed: timeout'));
      expect(
        md,
        contains(
          '| MIX-OBS | 1 | needBetterView | failed: timeout | ✗ | ✗ | fail | — | — |',
        ),
      );
    });

    test(
      'uploads come only from legs that prove or may have sent the photo',
      () {
        final trials = [
          answered(
            'MASH-T',
            WatchState.ready,
            legs: const [
              TrialLeg(
                provenance: 'sdkOnDevice',
                transferPermitted: false,
                carriedImage: true,
              ),
              TrialLeg(
                provenance: 'sdkCloud',
                transferPermitted: true,
                carriedImage: true,
              ),
            ],
          ),
          answered(
            'MIX-T',
            WatchState.ready,
            legs: const [
              TrialLeg(
                provenance: 'cloudAdapter',
                transferPermitted: true,
                carriedImage: false,
              ),
              TrialLeg(
                provenance: 'unknown',
                transferPermitted: true,
                carriedImage: true,
              ),
              TrialLeg(
                provenance: 'unknown',
                transferPermitted: false,
                carriedImage: true,
              ),
            ],
          ),
        ];
        final r = WatchEvalReport(
          fixtures: eight,
          trials: trials,
          observations: const {},
          context: ctx(),
        );
        expect(r.framesUploaded, 1);
        expect(r.framesMaybeUploaded, 1);
        expect(
          r.uploadSummary,
          '1 of 2 photos (from 5 legs); 1 more may have been uploaded',
        );
        expect(
          r.evidenceLevel,
          'mixed, from the inference legs (sdkCloud 1, unknown 1)',
        );
      },
    );

    test('a run on fakes is labelled simulated, never device evidence', () {
      final r = WatchEvalReport(
        fixtures: eight,
        trials: [
          answered(
            'MASH-T',
            WatchState.ready,
            legs: const [
              TrialLeg(
                provenance: 'simulated',
                transferPermitted: false,
                carriedImage: true,
              ),
            ],
          ),
        ],
        observations: const {},
        context: ctx(),
      );
      expect(r.evidenceLevel, contains('not evidence of the real model'));
      expect(r.toMarkdown(), contains('fakes only'));
    });

    test('missing context or scores make the report incomplete', () {
      final trials = perfect();
      WatchEvalReport build(
        WatchEvalContext c,
        Map<String, ObservationMark> m,
      ) => WatchEvalReport(
        fixtures: eight,
        trials: trials,
        observations: m,
        context: c,
      );
      expect(build(ctx(hardware: ' '), allPass(trials)).complete, isFalse);
      expect(build(ctx(scorer: ''), allPass(trials)).complete, isFalse);
      expect(build(ctx(platform: ''), allPass(trials)).complete, isFalse);
      expect(build(ctx(sha: 'unknown'), allPass(trials)).complete, isFalse);
      final unscored = build(ctx(), {...allPass(trials)}..remove('MIX-T#1'));
      expect(unscored.complete, isFalse);
      expect('${unscored.observationsScored}', '7/8');
      final md = build(
        ctx(hardware: '', scorer: '', sha: 'unknown'),
        const {},
      ).toMarkdown();
      expect(md, contains('INCOMPLETE'));
      expect(md, contains('- **Hardware:** _not recorded_'));
      expect(md, contains('- **Observation scorer:** _not recorded_'));
      expect(md, contains('- **Build:** _not recorded_'));
      expect(
        build(ctx(hardware: '', sha: 'unknown'), const {}).context.missing,
        ['hardware', 'build SHA'],
      );
    });

    test('an empty run measures nothing and says so', () {
      final r = WatchEvalReport(
        fixtures: eight,
        trials: const [],
        observations: const {},
        context: ctx(),
      );
      expect(r.complete, isFalse);
      expect(r.uploadSummary, 'not measured');
      expect(r.evidenceLevel, 'not measured');
      expect(r.latency.medianMs, isNull);
      expect(r.toMarkdown(), contains('min not measured'));
      expect(r.toMarkdown(), contains('_not reported by the bridge_'));
    });

    test(
      'pipes in the model sentence cannot break the table; redactions show',
      () {
        final r = WatchEvalReport(
          fixtures: eight,
          trials: [
            answered('MASH-T', WatchState.ready, see: 'a | b', redacted: true),
            answered('MIX-T', WatchState.ready, see: ''),
          ],
          observations: const {},
          context: ctx(),
        );
        final md = r.toMarkdown();
        expect(md, contains(r'a \| b _(redacted)_'));
        expect(md, contains('| unscored | 100 ms | — |'));
        expect(r.redactedAnswers, 1);
      },
    );

    test('trials for a fixture that is not in the set are refused', () {
      expect(
        () => WatchEvalReport(
          fixtures: eight,
          trials: [answered('NOPE', WatchState.ready)],
          observations: const {},
          context: ctx(),
        ),
        throwsArgumentError,
      );
    });

    test('the lower median is always a measured sample', () {
      expect(const LatencySummary([40, 10, 30, 20]).medianMs, 20);
      expect(const LatencySummary([7]).toJson(), {
        'n': 1,
        'minMs': 7,
        'medianMs': 7,
        'maxMs': 7,
      });
    });
  });
}
