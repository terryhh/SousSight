// The "On-device AI" sheet (SS-070 / SS-071): availability per modality,
// one-tap setup with progress, per-feature "keep on this device" switches and
// per-platform enable steps.

import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

import 'privacy_preferences.dart';

/// Wraps `HybridInference.prepare`. Must start work when called (the web
/// download needs the user gesture), not when the stream is listened to.
typedef PrepareOnDevice = Stream<double?> Function({required bool withImage});

/// Wraps `HybridInference.availability`.
typedef CheckAvailability = Future<HybridAvailability> Function({
  required bool withImage,
});

/// Loads capabilities and availability, then opens the sheet.
Future<void> showOnDeviceAiSheet(
  BuildContext context, {
  required HybridInference inference,
  required PrivacyPreferences privacy,
  VoidCallback? onReady,
}) async {
  final capabilities = await inference.capabilities();
  final text = await inference.availability(withImage: false);
  final image = await inference.availability(withImage: true);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => OnDeviceAiSheet(
        capabilities: capabilities,
        textAvailability: text,
        imageAvailability: image,
        prepare: inference.prepare,
        checkAvailability: inference.availability,
        privacy: privacy,
        onReady: onReady,
        controller: controller,
      ),
    ),
  );
}

/// Cook-facing status for one modality.
String onDeviceStatusText(
  HybridAvailability availability, {
  required bool image,
  LocalModelLimits? local,
}) {
  if (image && local != null && !local.supportsImage) {
    return '${local.modelFamily} reads text only on this device.';
  }
  return switch (availability.status) {
    OnDeviceStatus.available =>
      availability.modelLabel == null
          ? 'Ready on this device.'
          : 'Ready on this device (${availability.modelLabel}).',
    OnDeviceStatus.downloadable => 'Ready to set up.',
    OnDeviceStatus.downloading => 'Downloading.',
    OnDeviceStatus.unavailable => switch (availability.reason) {
      'unsupported_browser' => "This browser can't run it.",
      'bridge_unavailable' => "On-device AI didn't start in this build.",
      'device_not_eligible' => "This device isn't supported.",
      'apple_intelligence_off' => 'Turn on Apple Intelligence first.',
      'not_enrolled' => 'Needs the AICore developer preview.',
      'model_not_ready' => "The model isn't ready yet.",
      _ when image => 'Photo checks need a Chrome setting or a newer device.',
      _ => 'Not available here.',
    },
  };
}

enum _SetupPhase { idle, preparing, ready, failed }

class OnDeviceAiSheet extends StatefulWidget {
  const OnDeviceAiSheet({
    super.key,
    required this.capabilities,
    required this.textAvailability,
    required this.imageAvailability,
    required this.prepare,
    required this.privacy,
    this.checkAvailability,
    this.onReady,
    this.features = privacyFeatures,
    this.controller,
  });

  final HybridCapabilities capabilities;
  final HybridAvailability textAvailability;
  final HybridAvailability imageAvailability;
  final PrepareOnDevice prepare;
  final CheckAvailability? checkAvailability;
  final PrivacyPreferences privacy;

  /// Called once setup completes and availability was re-read.
  final VoidCallback? onReady;
  final List<({String feature, String label, String detail})> features;
  final ScrollController? controller;

  @override
  State<OnDeviceAiSheet> createState() => _OnDeviceAiSheetState();
}

class _OnDeviceAiSheetState extends State<OnDeviceAiSheet> {
  late HybridAvailability _text = widget.textAvailability;
  late HybridAvailability _image = widget.imageAvailability;
  _SetupPhase _phase = _SetupPhase.idle;
  double? _fraction;
  String? _error;
  StreamSubscription<double?>? _sub;

  static bool _needsSetup(HybridAvailability a) =>
      a.status == OnDeviceStatus.downloadable ||
      a.status == OnDeviceStatus.downloading;

  bool get _imageCapable => widget.capabilities.local?.supportsImage ?? false;

  bool get _canSetUp =>
      _phase != _SetupPhase.preparing &&
      (_needsSetup(_text) || (_imageCapable && _needsSetup(_image)));

  /// Runs inside the tap. `prepare` is called before any await so the web
  /// download keeps the user gesture.
  void _setUp() {
    final withImage = _imageCapable && _needsSetup(_image);
    final Stream<double?> progress;
    try {
      progress = widget.prepare(withImage: withImage);
    } on HybridException catch (e) {
      _fail(e);
      return;
    }
    setState(() {
      _phase = _SetupPhase.preparing;
      _fraction = null;
      _error = null;
    });
    _sub = progress.listen(
      (fraction) {
        if (mounted) setState(() => _fraction = fraction);
      },
      onError: (Object e) => _fail(e),
      onDone: () => unawaited(_finish()),
      cancelOnError: true,
    );
  }

  void _fail(Object error) {
    if (!mounted) return;
    setState(() {
      _phase = _SetupPhase.failed;
      _error = switch (error) {
        HybridException(code: HybridErrorCode.network) =>
          'The download needs a connection. Try again on Wi-Fi.',
        HybridException(code: HybridErrorCode.unavailable) =>
          "This device can't run the on-device model.",
        HybridException(code: HybridErrorCode.busy) =>
          'Your device is busy. Try again in a minute.',
        _ => "Setup didn't finish. Try again.",
      };
    });
  }

  Future<void> _finish() async {
    final check = widget.checkAvailability;
    if (check != null) {
      final text = await check(withImage: false);
      final image = await check(withImage: true);
      if (!mounted) return;
      _text = text;
      _image = image;
    }
    if (!mounted) return;
    setState(() {
      _phase = _SetupPhase.ready;
      _fraction = 1;
    });
    widget.onReady?.call();
  }

  @override
  void dispose() {
    // The download itself cannot be cancelled; we only stop listening.
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final local = widget.capabilities.local;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );

    return ListView(
      key: const ValueKey('on-device-ai-sheet'),
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Semantics(
          header: true,
          child: Text(
            'On-device AI',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          local == null
              ? "This device doesn't have an on-device model SousSight can use."
              : 'SousSight can run some help on this device with '
                    '${local.modelFamily}, so your photos and notes stay here.',
        ),
        heading('On this device'),
        _StatusRow(
          key: const ValueKey('on-device-text-status'),
          icon: Icons.notes,
          label: 'Text',
          status: onDeviceStatusText(_text, image: false, local: local),
          ok: _text.status == OnDeviceStatus.available,
        ),
        _StatusRow(
          key: const ValueKey('on-device-image-status'),
          icon: Icons.photo_camera_outlined,
          label: 'Photos',
          status: onDeviceStatusText(_image, image: true, local: local),
          ok: _imageCapable && _image.status == OnDeviceStatus.available,
        ),
        const SizedBox(height: 12),
        _setupControls(theme),
        heading('Keep on this device'),
        Text(
          "When a switch is on, that feature never uses the cloud. If this "
          "device can't run it, SousSight tells you instead.",
          style: theme.textTheme.bodySmall,
        ),
        ListenableBuilder(
          listenable: widget.privacy,
          builder: (context, _) => Column(
            children: [
              for (final f in widget.features)
                SwitchListTile(
                  key: ValueKey('local-only-${f.feature}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('Keep ${f.label} on this device'),
                  subtitle: Text(f.detail),
                  value: widget.privacy.localOnly(f.feature),
                  onChanged: (v) => widget.privacy.setLocalOnly(f.feature, v),
                ),
            ],
          ),
        ),
        heading('How to turn it on'),
        for (final p in _platforms)
          _PlatformSteps(
            key: ValueKey('enable-steps-${p.id}'),
            title: p.title,
            steps: p.steps,
            current: widget.capabilities.platform == p.id,
          ),
      ],
    );
  }

  Widget _setupControls(ThemeData theme) {
    final fraction = _fraction;
    final percent = fraction == null ? null : (fraction * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_phase == _SetupPhase.preparing) ...[
          Semantics(
            liveRegion: true,
            label: percent == null
                ? 'Setting up on-device AI'
                : 'Setting up on-device AI, $percent percent',
            child: LinearProgressIndicator(
              key: const ValueKey('on-device-progress'),
              value: fraction,
              minHeight: 6,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            percent == null ? 'Setting up…' : 'Downloading… $percent%',
            key: const ValueKey('on-device-progress-text'),
          ),
          Text(
            'The download keeps going if you close this.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (_phase == _SetupPhase.ready)
          Semantics(
            liveRegion: true,
            child: const Text(
              'Setup finished.',
              key: ValueKey('on-device-ready'),
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        if (_error case final error?)
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              key: const ValueKey('on-device-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (_canSetUp) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('set-up-on-device'),
              onPressed: _setUp,
              icon: const Icon(Icons.download_outlined),
              label: Text(
                _phase == _SetupPhase.failed
                    ? 'Try again'
                    : 'Set up on-device AI',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    super.key,
    required this.icon,
    required this.label,
    required this.status,
    required this.ok,
  });

  final IconData icon;
  final String label;
  final String status;
  final bool ok;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label: $status',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ok ? const Color(0xffe4ebdf) : const Color(0xfff5f1e8),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              SizedBox(
                width: 64,
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(child: Text(status)),
              Icon(
                ok ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18,
                color: ok ? const Color(0xff285b43) : Colors.black45,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PlatformSteps extends StatelessWidget {
  const _PlatformSteps({
    super.key,
    required this.title,
    required this.steps,
    required this.current,
  });

  final String title;
  final List<String> steps;
  final bool current;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 12),
    initiallyExpanded: current,
    title: Text(
      current ? '$title (this device)' : title,
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < steps.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text('${i + 1}.')),
              Expanded(child: SelectableText(steps[i])),
            ],
          ),
        ),
    ],
  );
}

/// Per-platform enable steps. No version numbers: Firebase's and Chrome's
/// docs disagree on the minimum Chrome version, and the iOS version was not
/// verified. Disk and hardware figures are from
/// developer.chrome.com/docs/ai/prompt-api; the multimodal flag is from
/// Firebase's web hybrid get-started page.
const _platforms = [
  (
    id: 'web',
    title: 'Chrome on a computer',
    steps: [
      'Recent desktop Chrome on Windows, macOS, Linux or Chromebook Plus. '
          "Chrome on phones and tablets can't run it yet.",
      'Keep at least 22 GB free on the drive that holds your Chrome profile. '
          'Chrome removes the model if free space drops under 10 GB.',
      'Your computer needs a graphics card with more than 4 GB of memory, or '
          '16 GB of RAM and 4 CPU cores.',
      'For photo checks, open chrome://flags/#prompt-api-for-gemini-nano-multimodal-input, '
          'set it to Enabled, and relaunch Chrome.',
      'Come back here and tap "Set up on-device AI". The first download needs '
          'an unmetered connection.',
    ],
  ),
  (
    id: 'android',
    title: 'Android phone',
    steps: [
      'Use a phone that runs Gemini Nano through AICore, such as a recent '
          'Pixel or Galaxy flagship.',
      'Update AICore and Android System Intelligence from the Play Store.',
      'This build asks for the Gemini Nano preview model, which needs the '
          'phone enrolled in the AICore developer preview.',
      'Tap "Set up on-device AI" and keep SousSight open while it downloads.',
    ],
  ),
  (
    id: 'ios',
    title: 'iPhone',
    steps: [
      'An iPhone with Apple Intelligence turned on '
          '(Settings → Apple Intelligence & Siri).',
      "Apple's on-device model reads text only, so photo features need the "
          'cloud on iPhone.',
    ],
  ),
];
