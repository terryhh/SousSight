// Small widgets that put the hybrid runtime on the pantry and cooking
// screens: the On-device AI and "what was sent" sheets, the label check, and
// the first-run readiness panel.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../label/label_check_sheet.dart';
import '../trust/app_readiness.dart';
import '../trust/ledger_view.dart';
import '../trust/on_device_ai_sheet.dart';
import 'hybrid_runtime.dart';
import 'rehearsal_runtime.dart';

Future<void> openOnDeviceAi(BuildContext context, HybridRuntime hybrid) =>
    showOnDeviceAiSheet(
      context,
      inference: hybrid.inference,
      privacy: hybrid.privacy,
      practice: isPracticeRuntime(hybrid),
    );

Future<void> openLedger(BuildContext context, HybridRuntime hybrid) async {
  final caps = await hybrid.inference.capabilities();
  if (!context.mounted) return;
  await showLedgerSheet(
    context,
    ledger: hybrid.ledgerSource,
    localModelFamily: caps.local?.modelFamily,
  );
}

Future<void> openLabelCheck(
  BuildContext context,
  HybridRuntime hybrid, {
  required String sessionId,
  Future<Uint8List?> Function()? takePhoto,
}) => showLabelCheckSheet(
  context,
  controller: hybrid.labelCheck(sessionId),
  takePhoto: takePhoto,
);

/// Why AI help can't run here, as one plain sentence, or null when the
/// readiness check says it can (SS-089). Read live, when it is needed.
Future<String?> hybridUnavailableReason(HybridRuntime hybrid) async {
  final inference = hybrid.inference;
  final caps = await inference.capabilities();
  final text = await inference.availability(withImage: false);
  final image = await inference.availability(withImage: true);
  final online = hybrid.isOnline();
  final cloudApproved = hybrid.cloudRoutes.allows(CloudRoute.hybridFallback);
  final readiness = AppReadiness.evaluate(
    ReadinessInput(
      capabilities: caps,
      text: text,
      image: image,
      camera: CameraAccess.notAsked,
      online: online,
      cloudApproved: cloudApproved,
    ),
  );
  if (readiness.canUseAi) return null;
  if (!online) return "You're offline, and this device can't do it on its own.";
  return cloudApproved
      ? "This device can't do it on its own, and online help isn't reachable "
            'right now.'
      : "This device can't do it on its own, and sending online is off in "
            'this build.';
}

/// Header actions, each with a visible label (SS-089): "On this device",
/// "What we sent" and, when given, "Check a label". They wrap as a group.
class HybridHeaderButtons extends StatelessWidget {
  const HybridHeaderButtons({super.key, required this.hybrid, this.onLabel});

  final HybridRuntime hybrid;
  final VoidCallback? onLabel;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      HeaderAction(
        key: const ValueKey('open-on-device-ai'),
        icon: Icons.memory_outlined,
        label: 'On this device',
        onPressed: () => unawaited(openOnDeviceAi(context, hybrid)),
      ),
      HeaderAction(
        key: const ValueKey('open-ledger'),
        icon: Icons.receipt_long_outlined,
        label: 'What we sent',
        onPressed: () => unawaited(openLedger(context, hybrid)),
      ),
      if (onLabel case final onLabel?)
        HeaderAction(
          key: const ValueKey('open-label-check'),
          icon: Icons.document_scanner_outlined,
          label: 'Check a label',
          onPressed: onLabel,
        ),
    ],
  );
}

/// A compact labelled header button: icon plus text, 48 px tall. Its
/// accessible name is the label, once.
class HeaderAction extends StatelessWidget {
  const HeaderAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      foregroundColor: const Color(0xff285b43),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      shape: const StadiumBorder(side: BorderSide(color: Color(0x33285b43))),
    ),
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
}

/// First-run readiness (SS-071): what the plugin reports plus connectivity,
/// the route approval and the latest cloud error in the session ledger.
class HybridReadinessCard extends StatefulWidget {
  const HybridReadinessCard({super.key, required this.hybrid});
  final HybridRuntime hybrid;

  @override
  State<HybridReadinessCard> createState() => _HybridReadinessCardState();
}

class _HybridReadinessCardState extends State<HybridReadinessCard> {
  ReadinessInput? _input;
  bool _dismissed = false;
  int _load = 0;

  @override
  void initState() {
    super.initState();
    widget.hybrid.ledger.addListener(_onLedger);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    widget.hybrid.ledger.removeListener(_onLedger);
    super.dispose();
  }

  void _onLedger() {
    if (mounted && _input != null) setState(() {});
  }

  Future<void> _refresh() async {
    final load = ++_load;
    final inference = widget.hybrid.inference;
    final caps = await inference.capabilities();
    final text = await inference.availability(withImage: false);
    final image = await inference.availability(withImage: true);
    if (!mounted || load != _load) return;
    setState(() {
      _input = ReadinessInput(
        capabilities: caps,
        text: text,
        image: image,
        camera: CameraAccess.notAsked,
        online: widget.hybrid.isOnline(),
        cloudApproved: widget.hybrid.cloudRoutes.allows(
          CloudRoute.hybridFallback,
        ),
      );
    });
  }

  /// The latest cloud leg's error, never an older one.
  HybridErrorCode? get _latestCloudError {
    for (final leg in widget.hybrid.ledger.legs.reversed) {
      if (leg.transferPermitted) return leg.error;
    }
    return null;
  }

  Future<void> _onAction(ReadinessAction action) async {
    switch (action) {
      case ReadinessAction.openOnDeviceSetup ||
          ReadinessAction.showDownloadProgress ||
          ReadinessAction.showEnableSteps:
        await openOnDeviceAi(context, widget.hybrid);
        await _refresh();
      case ReadinessAction.reload || ReadinessAction.checkConnection:
        await _refresh();
      default:
        setState(() => _dismissed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = _input;
    if (input == null || _dismissed) return const SizedBox.shrink();
    final readiness = AppReadiness.evaluate(
      input.withCloudError(_latestCloudError),
    );
    // One calm line (SS-089); the details live in the "On this device"
    // sheet behind "Details".
    if (readinessCalmLine(readiness) == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ReadinessLine(
        readiness: readiness,
        onDetails: () => unawaited(_onAction(ReadinessAction.showEnableSteps)),
      ),
    );
  }
}
