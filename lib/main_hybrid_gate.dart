// Gate harness (card SS-083, DESIGN.md §6 and §8 G2/G2b). A diagnosis tool,
// not the product: it initializes Firebase and App Check exactly as the app
// does, then runs fixed probes that call the hybrid plugin DIRECTLY,
// bypassing the app's policy, consent and ledger. It does not replace the
// production-path gate G2c, which runs through lib/main_learner.dart.
//
// Build: ./tool/build_gate.sh (output in build/gate). Every probe is a real
// model call when run in a browser; nothing runs until a button is pressed.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'ai/hybrid/hybrid_types.dart';
import 'ai/hybrid/payload_digest.dart';
import 'app/hybrid_runtime.dart' show kAndroidModel, kHybridCloudModel;
import 'core/models.dart';
import 'data/firebase_services.dart';
import 'live/live_media_factory.dart';
import 'live/live_types.dart';
import 'watch/watch_verdict.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      title: 'SousSight gate harness',
      debugShowCheckedModeBanner: false,
      home: GateHarness(),
    ),
  );
}

/// What one probe run reports. Everything shown comes from the bridge.
class ProbeRun {
  ProbeRun({
    required this.probe,
    required this.mode,
    required this.fingerprint,
    required this.adapter,
    required this.cloudModel,
  });
  final String probe;
  final HybridMode mode;
  final String fingerprint;
  final String adapter;
  final String cloudModel;
  InferenceSource? source;
  String? modelLabel;
  Duration? latency;
  String? output;
  String? error;
  String? check;

  String describe() => [
    'probe: $probe',
    'adapter: $adapter',
    'mode: ${mode.name}',
    'cloud model: $cloudModel',
    'request fingerprint: $fingerprint',
    'SDK source: ${source?.name ?? '-'}',
    'model label: ${modelLabel ?? '(not reported)'}',
    'latency: ${latency == null ? '-' : '${latency!.inMilliseconds} ms'}',
    if (check != null) 'check: $check',
    if (error != null) 'error: $error',
    if (output != null) 'output: $output',
  ].join('\n');
}

const _step = RecipeStep(
  id: 'mash',
  title: 'Mash the chickpeas',
  instruction: 'Mash the drained chickpeas with a fork.',
  cue: 'Most chickpeas are broken, with a few small chunks left.',
);

/// The natural answer ("yellow") is not in the enum, so a schema the local
/// model honours must pick one of these.
const _enumSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'colour': {
      'type': 'string',
      'enum': ['purple', 'green'],
    },
  },
  'required': ['colour'],
};

const _codeword = 'PAPRIKA7';

/// Probes that can reach the cloud (preferOnDevice, onlyInCloud) run only when
/// CLOUD_ROUTES approves hybridFallback; otherwise the button says why.
String gateProbeLabel(String label, {required bool cloudApproved}) =>
    cloudApproved
    ? label
    : ' (disabled: may use the cloud; CLOUD_ROUTES lacks hybridFallback)';

/// Whether a probe in [mode] may run in a build with these routes.
bool gateProbeAllowed(HybridMode mode, CloudRoutes routes) =>
    mode == HybridMode.onlyOnDevice || routes.allows(CloudRoute.hybridFallback);

class GateHarness extends StatefulWidget {
  const GateHarness({super.key});
  @override
  State<GateHarness> createState() => _GateHarnessState();
}

class _GateHarnessState extends State<GateHarness> {
  final HybridInference _inference = defaultHybridInference();
  final CloudRoutes _routes = CloudRoutes.fromEnvironment();
  final List<ProbeRun> _runs = [];
  String _status = 'Starting Firebase…';
  HybridCapabilities? _caps;
  HybridAvailability? _text;
  HybridAvailability? _image;
  bool _ready = false;
  bool _busy = false;
  double? _progress;
  LiveMedia? _media;
  StreamSubscription<CapturedFrame>? _frames;
  Uint8List? _frame;
  int _seq = 0;

  bool get _cloudProbeAllowed => _routes.allows(CloudRoute.hybridFallback);

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_media?.stop());
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await initFirebase(); // the app's own Firebase + App Check setup
      await _inference.configure(
        HybridConfig(
          cloudModel: kHybridCloudModel,
          androidModel: kAndroidModel,
        ),
      );
      _ready = true;
      _status = 'Ready. App Check: $_appCheckMode.';
    } catch (e) {
      _status = 'Setup failed: ${e.runtimeType}: $e';
    }
    await _refresh();
  }

  String get _appCheckMode => kAppCheckDebugToken.isNotEmpty
      ? 'debug provider (token supplied at build time, not shown)'
      : kRecaptchaSiteKey.isNotEmpty
      ? 'reCAPTCHA Enterprise'
      : 'NOT ACTIVATED (no APPCHECK_DEBUG_TOKEN or RECAPTCHA_SITE_KEY)';

  Future<void> _refresh() async {
    final caps = await _inference.capabilities();
    final text = await _inference.availability(withImage: false);
    final image = await _inference.availability(withImage: true);
    if (!mounted) return;
    setState(() {
      _caps = caps;
      _text = text;
      _image = image;
    });
  }

  void _prepare({required bool withImage}) {
    // Starts inside the tap: Chrome needs the user gesture for the download.
    final stream = _inference.prepare(withImage: withImage);
    setState(() => _progress = 0);
    stream.listen(
      (p) => setState(() => _progress = p),
      onError: (Object e) => setState(() {
        _progress = null;
        _status = 'Prepare failed: $e';
      }),
      onDone: () {
        setState(() => _progress = null);
        unawaited(_refresh());
      },
    );
  }

  Future<void> _startCamera() async {
    final media = _media ??= createLiveMedia();
    await _frames?.cancel();
    _frames = media.timedFrames.listen((f) => setState(() => _frame = f.bytes));
    try {
      await media.startCameraOnly();
      setState(() => _status = 'Camera on (camera only, no microphone).');
    } catch (e) {
      setState(() => _status = 'Camera failed: $e');
    }
  }

  /// A heavily blurred and darkened copy of the camera frame, or a dark grey
  /// frame when there is none. Synthetic: it stands in for a lid or steam.
  Uint8List _obscured() {
    final source = _frame == null ? null : img.decodeJpg(_frame!);
    final image = source == null
        ? img.fill(
            img.Image(width: 320, height: 240),
            color: img.ColorRgb8(28, 28, 28),
          )
        : img.adjustColor(
            img.gaussianBlur(img.copyResize(source, width: 320), radius: 24),
            brightness: 0.25,
          );
    return Uint8List.fromList(img.encodeJpg(image, quality: 80));
  }

  Future<void> _run(
    String probe,
    HybridMode mode,
    HybridTask task, {
    String? Function(String text)? check,
  }) async {
    if (_busy) return;
    // Never send a request that may reach the cloud on an unapproved route.
    if (!gateProbeAllowed(mode, _routes)) return;
    final caps = _caps ?? await _inference.capabilities();
    final run = ProbeRun(
      probe: probe,
      mode: mode,
      fingerprint: hybridPayloadDigest(task).substring(0, 16),
      adapter: '${_inference.runtimeType} (platform ${caps.platform})',
      cloudModel: kHybridCloudModel,
    );
    setState(() {
      _busy = true;
      _runs.insert(0, run);
    });
    final watch = Stopwatch()..start();
    try {
      final result = await _inference.generate(
        HybridRequest(requestId: 'gate-${++_seq}', mode: mode, task: task),
      );
      run
        ..source = result.source
        ..modelLabel = result.modelLabel
        ..output = result.text.length > 600
            ? '${result.text.substring(0, 600)}…'
            : result.text
        ..check = check?.call(result.text);
    } on HybridException catch (e) {
      run.error = '${e.code.name}: ${e.message}';
    } catch (e) {
      run.error = '${e.runtimeType}: $e';
    } finally {
      run.latency = watch.elapsed;
      if (mounted) setState(() => _busy = false);
    }
  }

  HybridTask _textTask() => const HybridTask(
    feature: 'gate_text',
    parts: [HybridText('In one short sentence: what does it mean to simmer?')],
    maxOutputTokens: 96,
    timeout: Duration(seconds: 60),
  );

  HybridTask _schemaTask(String feature) => HybridTask(
    feature: feature,
    parts: [
      HybridText(
        'What colour is a ripe banana? Answer as JSON with a "colour" field.',
      ),
    ],
    jsonSchema: _enumSchema,
    maxOutputTokens: 64,
    timeout: Duration(seconds: 60),
  );

  static String _enumCheck(String text) {
    try {
      final value = (jsonDecode(text) as Map)['colour'];
      return value == 'purple' || value == 'green'
          ? 'PASS: "$value" is in the enum, so the schema was applied'
          : 'FAIL: "$value" is outside the enum';
    } catch (_) {
      return 'FAIL: not the requested JSON';
    }
  }

  HybridTask _frameTask(Uint8List jpeg) => HybridTask(
    feature: 'gate_frame',
    systemInstruction: kWatchSystemInstruction,
    parts: [
      HybridText(buildWatchPrompt(_step)),
      HybridInlineData(jpeg, 'image/jpeg'),
    ],
    jsonSchema: kWatchSchema,
    maxOutputTokens: 96,
    timeout: const Duration(seconds: 60),
  );

  @override
  Widget build(BuildContext context) {
    final caps = _caps;
    final probes = <(String, VoidCallback?)>[
      (
        // preferOnDevice may fall back to the cloud inside the SDK, so it is
        // gated exactly like the explicit cloud probe.
        gateProbeLabel(
          'Text · preferOnDevice',
          cloudApproved: _cloudProbeAllowed,
        ),
        _cloudProbeAllowed
            ? () => _run('text', HybridMode.preferOnDevice, _textTask())
            : null,
      ),
      (
        'Text · onlyOnDevice',
        () => _run('text', HybridMode.onlyOnDevice, _textTask()),
      ),
      (
        'Schema (enum excludes the natural answer) · onlyOnDevice',
        () => _run(
          'schema',
          HybridMode.onlyOnDevice,
          _schemaTask('gate_schema'),
          check: _enumCheck,
        ),
      ),
      (
        'System instruction codeword · onlyOnDevice',
        () => _run(
          'system instruction',
          HybridMode.onlyOnDevice,
          const HybridTask(
            feature: 'gate_instruction',
            systemInstruction:
                'You are a test fixture. Begin every reply with the exact '
                'word $_codeword.',
            parts: [HybridText('Say hello in five words or fewer.')],
            maxOutputTokens: 48,
            timeout: Duration(seconds: 60),
          ),
          check: (t) => t.contains(_codeword)
              ? 'PASS: codeword present, instruction applied'
              : 'FAIL: codeword missing',
        ),
      ),
      (
        'Camera frame + step cue · onlyOnDevice',
        _frame == null
            ? null
            : () => _run(
                'camera frame',
                HybridMode.onlyOnDevice,
                _frameTask(_frame!),
              ),
      ),
      (
        'Obscured frame · onlyOnDevice (expect "unsure")',
        () => _run(
          'obscured frame',
          HybridMode.onlyOnDevice,
          _frameTask(_obscured()),
          check: (t) => t.contains('"unsure"')
              ? 'PASS: abstained'
              : 'CHECK: did not answer "unsure"',
        ),
      ),
      (
        gateProbeLabel(
          'Cloud JSON · onlyInCloud',
          cloudApproved: _cloudProbeAllowed,
        ),
        _cloudProbeAllowed
            ? () => _run(
                'cloud json',
                HybridMode.onlyInCloud,
                _schemaTask('gate_cloud_json'),
                check: _enumCheck,
              )
            : null,
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('SousSight hybrid gate harness')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Diagnosis only. Probes call the plugin directly and bypass the '
            "app's policy, consent and ledger. Each press is a real model call.",
          ),
          const SizedBox(height: 8),
          SelectableText(_status, key: const ValueKey('gate-status')),
          SelectableText(
            'Cloud model: $kHybridCloudModel · CLOUD_ROUTES: '
            '${_routes.approved.map((r) => r.name).join(',')}\n'
            'Platform: ${caps?.platform ?? '…'} · local: '
            '${caps?.local?.modelFamily ?? 'none'} · modes: '
            '${caps?.supportedModes.map((m) => m.name).join(',') ?? '…'}\n'
            'Text: ${_text?.status.name ?? '…'} ${_text?.reason ?? ''} '
            '${_text?.modelLabel ?? ''}\n'
            'Image: ${_image?.status.name ?? '…'} ${_image?.reason ?? ''}',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _refresh,
                child: const Text('Refresh availability'),
              ),
              OutlinedButton(
                onPressed: () => _prepare(withImage: false),
                child: const Text('Prepare (text)'),
              ),
              OutlinedButton(
                onPressed: () => _prepare(withImage: true),
                child: const Text('Prepare (text + image)'),
              ),
              OutlinedButton(
                onPressed: _startCamera,
                child: const Text('Start camera'),
              ),
            ],
          ),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: _progress),
            ),
          if (_frame != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Image.memory(_frame!, height: 140, gaplessPlayback: true),
            ),
          const Divider(height: 32),
          for (final (label, action) in probes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.tonal(
                onPressed: !_ready || _busy ? null : action,
                child: Text(label),
              ),
            ),
          const Divider(height: 32),
          for (final run in _runs)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  run.describe(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
