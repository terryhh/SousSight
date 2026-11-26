// SS-075: the screen a person uses on the device under test. It runs the
// eight photos, asks the person to score each observation blind (the
// verdict is hidden while scoring), and produces the report to paste into
// docs/buildhybridai/EVIDENCE.md.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'watch_eval.dart';
import 'watch_eval_runner.dart';

/// "web" or the Flutter target platform; the scorer adds the browser and OS
/// in the hardware field.
String describePlatform({bool? isWeb, TargetPlatform? platform}) =>
    (isWeb ?? kIsWeb) ? 'web' : (platform ?? defaultTargetPlatform).name;

enum _Phase { idle, running, scoring, failed }

class WatchEvalScreen extends StatefulWidget {
  const WatchEvalScreen({
    super.key,
    required this.fixtures,
    required this.runner,
    required this.loadAsset,
    required this.buildSha,
    required this.platform,
    this.now = DateTime.now,
  });

  final List<WatchFixture> fixtures;
  final WatchEvalRunner runner;
  final Future<Uint8List> Function(String assetPath) loadAsset;
  final String buildSha;
  final String platform;
  final DateTime Function() now;

  @override
  State<WatchEvalScreen> createState() => _WatchEvalScreenState();
}

class _WatchEvalScreenState extends State<WatchEvalScreen> {
  final _hardware = TextEditingController();
  final _scorer = TextEditingController();
  final _photos = <String, Uint8List>{};
  final _marks = <String, ObservationMark>{};
  List<WatchTrial> _trials = [];
  _Phase _phase = _Phase.idle;
  String? _error;
  DateTime? _startedAt;
  DateTime? _finishedAt;

  /// When the scorer locked the observation marks. Verdicts and scores are
  /// shown only after this, and marks never change once it is set.
  DateTime? _lockedAt;

  /// Bumped by every run and cancel; a run that awaited across it is dropped.
  int _run = 0;

  @override
  void dispose() {
    _run++;
    widget.runner.cancel();
    _hardware.dispose();
    _scorer.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final run = ++_run;
    setState(() {
      _phase = _Phase.running;
      _error = null;
      _trials = [];
      _marks.clear();
      _startedAt = widget.now();
      _finishedAt = null;
      _lockedAt = null;
    });
    try {
      for (final f in widget.fixtures) {
        _photos[f.fixtureId] ??= await widget.loadAsset(f.assetPath);
        if (!mounted || run != _run) return;
      }
      final trials = await widget.runner.run(
        widget.fixtures,
        onTrial: (trial) {
          if (mounted && run == _run) setState(() => _trials.add(trial));
        },
      );
      if (!mounted || run != _run) return;
      setState(() {
        _trials = trials;
        _finishedAt = widget.now();
        _phase = _Phase.scoring;
      });
    } catch (error) {
      if (!mounted || run != _run) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$error';
      });
    }
  }

  void _cancel() {
    _run++;
    widget.runner.cancel();
    setState(() {
      _phase = _Phase.idle;
      _trials = [];
      _marks.clear();
      _lockedAt = null;
      _error = 'Run cancelled; nothing was recorded.';
    });
  }

  WatchEvalReport _report() => WatchEvalReport(
    fixtures: widget.fixtures,
    trials: _trials,
    observations: Map.of(_marks),
    observationsLockedAt: _lockedAt,
    context: WatchEvalContext(
      hardware: _hardware.text,
      platform: widget.platform,
      scorer: _scorer.text,
      buildSha: widget.buildSha,
      startedAt: _startedAt!,
      finishedAt: _finishedAt!,
    ),
  );

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied')));
  }

  @override
  Widget build(BuildContext context) {
    final running = _phase == _Phase.running;
    return Scaffold(
      appBar: AppBar(title: const Text('SousSight watch evaluation (SS-075)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Runs the ${widget.fixtures.length} labelled photos through the '
            'on-device watch, one at a time. Cloud routes are off for this '
            'tool. Scoring rules: $kWatchScoringVersion.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('hardware'),
            controller: _hardware,
            decoration: const InputDecoration(
              labelText: 'Hardware (device, OS, browser and version)',
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const Key('scorer'),
            controller: _scorer,
            decoration: const InputDecoration(
              labelText: 'Who is scoring the observations',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                key: const Key('run'),
                onPressed: running ? null : _start,
                child: Text(_trials.isEmpty ? 'Run the photos' : 'Run again'),
              ),
              const SizedBox(width: 12),
              if (running)
                OutlinedButton(
                  key: const Key('cancel'),
                  onPressed: _cancel,
                  child: const Text('Cancel'),
                ),
            ],
          ),
          if (running)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Checked ${_trials.length} of '
                '${widget.fixtures.length * widget.runner.attemptsPerFixture} '
                'on this device…',
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                key: const Key('error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_phase == _Phase.scoring) ..._scoring(),
        ],
      ),
    );
  }

  List<Widget> _scoring() {
    final report = _report();
    return [
      const SizedBox(height: 16),
      Text(
        'Score each observation. Does the watch\'s sentence state what the '
        'photo is expected to show, and not its opposite? The verdicts stay '
        'hidden until you lock your scores, and locked scores cannot change.',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      for (final t in _trials) _trialCard(t),
      const SizedBox(height: 16),
      if (!report.complete)
        Text(
          'Report incomplete: score every observation and fill in hardware '
          'and scorer${report.context.missing.contains('build SHA') ? '; this build has no GIT_SHA define' : ''}.',
          key: const Key('incomplete'),
        ),
      if (_lockedAt == null)
        FilledButton(
          key: const Key('lock'),
          onPressed: report.observationsScored.hits == _trials.length
              ? () => setState(() => _lockedAt = widget.now())
              : null,
          child: const Text('Lock my scores and show the results'),
        )
      else ...[
        const Text(
          'Scores locked. To score again, run the photos again: that is a '
          'new run.',
          key: Key('locked'),
        ),
        const SizedBox(height: 8),
        SelectableText(report.toMarkdown(), key: const Key('report')),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton(
              key: const Key('copy-md'),
              onPressed: () => _copy('Markdown', report.toMarkdown()),
              child: const Text('Copy Markdown'),
            ),
            OutlinedButton(
              key: const Key('copy-json'),
              onPressed: () => _copy(
                'JSON',
                const JsonEncoder.withIndent('  ').convert(report.toJson()),
              ),
              child: const Text('Copy JSON'),
            ),
          ],
        ),
      ],
    ];
  }

  Widget _trialCard(WatchTrial t) {
    final fixture = widget.fixtures.firstWhere(
      (f) => f.fixtureId == t.fixtureId,
    );
    final photo = _photos[t.fixtureId];
    final mark = t.answered ? _marks[t.key] : ObservationMark.fail;
    return Card(
      key: Key('trial-${t.key}'),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${t.fixtureId} · try ${t.attempt}'),
            if (photo != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Image.memory(photo, height: 160, fit: BoxFit.contain),
              ),
            const Text('Expected to be visible:'),
            for (final o in fixture.expectedObservations) Text('• $o'),
            const SizedBox(height: 8),
            Text(
              t.answered
                  ? 'The watch said: ${t.whatISee!.isEmpty ? '(nothing)' : t.whatISee}'
                  : 'No answer (${t.outcome.name}): scored as not matching.',
            ),
            if (t.answered)
              Wrap(
                spacing: 8,
                children: [
                  for (final m in ObservationMark.values)
                    ChoiceChip(
                      key: Key('mark-${t.key}-${m.name}'),
                      label: Text(
                        m == ObservationMark.pass
                            ? 'Matches'
                            : 'Doesn\'t match',
                      ),
                      selected: mark == m,
                      onSelected: _lockedAt != null
                          ? null
                          : (_) => setState(() => _marks[t.key] = m),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
