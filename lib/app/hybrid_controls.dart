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

Future<void> openOnDeviceAi(BuildContext context, HybridRuntime hybrid) =>
    showOnDeviceAiSheet(
      context,
      inference: hybrid.inference,
      privacy: hybrid.privacy,
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

/// Header actions: "On-device AI", "What was sent" and, when given,
/// "Check a label".
class HybridHeaderButtons extends StatelessWidget {
  const HybridHeaderButtons({super.key, required this.hybrid, this.onLabel});

  final HybridRuntime hybrid;
  final VoidCallback? onLabel;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        key: const ValueKey('open-on-device-ai'),
        tooltip: 'On-device AI',
        icon: const Icon(Icons.memory_outlined),
        onPressed: () => unawaited(openOnDeviceAi(context, hybrid)),
      ),
      IconButton(
        key: const ValueKey('open-ledger'),
        tooltip: 'What was sent',
        icon: const Icon(Icons.receipt_long_outlined),
        onPressed: () => unawaited(openLedger(context, hybrid)),
      ),
      if (onLabel != null)
        IconButton(
          key: const ValueKey('open-label-check'),
          tooltip: 'Check a label',
          icon: const Icon(Icons.document_scanner_outlined),
          onPressed: onLabel,
        ),
    ],
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ReadinessPanel(
        readiness: readiness,
        onAction: (action) => unawaited(_onAction(action)),
      ),
    );
  }
}
