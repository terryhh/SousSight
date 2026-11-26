import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/payload_digest.dart';
import 'package:soussight/core/models.dart';

import '../../../tool/hybrid_eval/watch_eval.dart';
import '../../../tool/hybrid_eval/watch_eval_app.dart';
import '../../../tool/hybrid_eval/watch_eval_runner.dart';
import '../../watch/watch_fakes.dart';

/// A real (tiny) PNG, built at runtime so Image.memory can decode it.
final photo = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));

const step = RecipeStep(
  id: 'mash',
  title: 'Mash the chickpeas',
  instruction: 'Press until most are broken.',
  cue: 'Mostly broken and chunky.',
);

List<WatchFixture> fixtures() => [
  WatchFixture(
    fixtureId: 'T',
    checkpointId: 'cp_mash',
    stepId: 'mash',
    assetPath: 't.png',
    sha256: sha256Hex(photo),
    expectedOutcome: ExpectedOutcome.matchesTarget,
    expectedAdjustmentId: null,
    expectedObservations: const ['Coarse, crumbly pieces.'],
  ),
  WatchFixture(
    fixtureId: 'S',
    checkpointId: 'cp_mash',
    stepId: 'mash',
    assetPath: 's.png',
    sha256: sha256Hex(photo),
    expectedOutcome: ExpectedOutcome.adjust,
    expectedAdjustmentId: 'fine_as_is',
    expectedObservations: const ['A smooth paste.'],
  ),
];

Future<Uint8List> load(String _) async => photo;

class Harness {
  Harness(this.dispatcher, {Future<Uint8List> Function(String)? runnerLoad})
    : runner = WatchEvalRunner(
        dispatcher: dispatcher,
        loadAsset: runnerLoad ?? load,
        steps: const {'mash': step},
      );
  final HybridDispatcher dispatcher;
  final WatchEvalRunner runner;

  Widget app({String sha = 'abc1234'}) => MaterialApp(
    home: WatchEvalScreen(
      fixtures: fixtures(),
      runner: runner,
      loadAsset: load,
      buildSha: sha,
      platform: 'web',
      now: () => DateTime.utc(2026, 11, 28, 10),
    ),
  );
}

/// A tall surface, so every scoring card is built.
void tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> fillContext(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('hardware')),
    'MacBook Air M3, Chrome 142',
  );
  await tester.enterText(find.byKey(const Key('scorer')), 'Jenna');
}

Future<void> tapRun(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('run')));
  await tester.pumpAndSettle();
}

Future<void> mark(WidgetTester tester, String key, ObservationMark m) async {
  final chip = find.byKey(Key('mark-$key-${m.name}'));
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  test('platform names the web or the target platform', () {
    expect(describePlatform(isWeb: true), 'web');
    expect(
      describePlatform(isWeb: false, platform: TargetPlatform.android),
      'android',
    );
  });

  testWidgets('runs, hides the verdict while scoring, then copies the report', (
    tester,
  ) async {
    final fake = FakeHybridDispatcher()
      ..enqueue(verdictJson('ready', see: 'Coarse chunks in a bowl.'))
      ..enqueue(
        verdictJson('not_yet', direction: 'less', see: 'A smooth paste.'),
      );
    final h = Harness(fake);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    tallView(tester);
    await tester.pumpWidget(h.app());
    await fillContext(tester);
    await tapRun(tester);

    expect(find.byKey(const Key('trial-T#1')), findsOneWidget);
    expect(
      find.text('The watch said: Coarse chunks in a bowl.'),
      findsOneWidget,
    );
    expect(find.text('• A smooth paste.'), findsOneWidget);
    // Blind scoring: nothing reveals the verdict or the score yet.
    expect(find.byKey(const Key('report')), findsNothing);
    expect(find.textContaining('ready'), findsNothing);
    expect(find.textContaining('✓'), findsNothing);
    expect(find.byKey(const Key('incomplete')), findsOneWidget);

    await mark(tester, 'T#1', ObservationMark.pass);
    expect(find.byKey(const Key('report')), findsNothing);
    await mark(tester, 'S#1', ObservationMark.fail);

    final report = tester.widget<SelectableText>(
      find.byKey(const Key('report')),
    );
    expect(report.data, contains('**Status:** complete.'));
    expect(report.data, contains('| Verdict class correct | 2/2 |'));
    expect(
      report.data,
      contains('| Observation correct (human-scored) | 1/2 (2 scored) |'),
    );
    expect(report.data, contains('| Next action correct | 2/2 |'));
    expect(report.data, contains('MacBook Air M3, Chrome 142'));
    expect(find.byKey(const Key('incomplete')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('copy-md')));
    await tester.tap(find.byKey(const Key('copy-md')));
    await tester.pumpAndSettle();
    expect(copied, contains('| Next action correct | 2/2 |'));
    expect(find.text('Markdown copied'), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-json')));
    await tester.pumpAndSettle();
    expect(copied, contains('"scoringVersion": "$kWatchScoringVersion"'));
    expect(copied, contains('"complete": true'));
  });

  testWidgets(
    'a blocked photo has nothing to score and the report says incomplete without a build SHA',
    (tester) async {
      final fake = FakeHybridDispatcher()
        ..enqueueBlocked(RouteReason.modelNotReady)
        ..enqueue(verdictJson('not_yet', direction: 'more'));
      tallView(tester);
      await tester.pumpWidget(Harness(fake).app(sha: 'unknown'));
      await fillContext(tester);
      await tapRun(tester);
      expect(
        find.text('No answer (blocked): scored as not matching.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mark-T#1-pass')), findsNothing);
      await mark(tester, 'S#1', ObservationMark.pass);
      final report = tester.widget<SelectableText>(
        find.byKey(const Key('report')),
      );
      expect(report.data, contains('INCOMPLETE'));
      expect(report.data, contains('blocked: modelNotReady'));
      expect(find.textContaining('no GIT_SHA define'), findsOneWidget);
    },
  );

  testWidgets('a photo that fails its hash check stops with the reason', (
    tester,
  ) async {
    final h = Harness(
      FakeHybridDispatcher(),
      runnerLoad: (_) async => Uint8List.fromList([1, 2, 3]),
    );
    tallView(tester);
    await tester.pumpWidget(h.app());
    await tapRun(tester);
    final error = tester.widget<Text>(find.byKey(const Key('error')));
    expect(error.data, contains('FixtureIntegrityError'));
    expect(find.byKey(const Key('trial-T#1')), findsNothing);
  });

  testWidgets('cancel stops the run and records nothing', (tester) async {
    final manual = ManualDispatcher();
    tallView(tester);
    await tester.pumpWidget(Harness(manual).app());
    await tester.tap(find.byKey(const Key('run')));
    await tester.pump();
    await tester.pump();
    expect(manual.tasks, hasLength(1));
    expect(find.text('Checked 0 of 2 on this device…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pump();
    expect(manual.cancelled, [0]);
    expect(find.text('Run cancelled; nothing was recorded.'), findsOneWidget);
    manual.answer(0, verdictJson('ready'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trial-T#1')), findsNothing);
    final run = tester.widget<FilledButton>(find.byKey(const Key('run')));
    expect(run.onPressed, isNotNull);
  });

  testWidgets('leaving the screen mid-run cancels the send', (tester) async {
    final manual = ManualDispatcher();
    tallView(tester);
    await tester.pumpWidget(Harness(manual).app());
    await tester.tap(find.byKey(const Key('run')));
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(manual.cancelled, [0]);
    manual.answer(0, verdictJson('ready'));
    await tester.pumpAndSettle();
  });
}
