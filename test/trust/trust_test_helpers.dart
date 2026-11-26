import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';

InferenceLeg leg(
  Provenance provenance, {
  String feature = 'pantry_scan',
  Set<DataKind> kinds = const {DataKind.text},
  bool? transferPermitted,
  String? modelLabel,
  HybridErrorCode? error,
  HybridMode? mode,
}) => InferenceLeg(
  requestId: 'r-${provenance.name}-$feature',
  feature: feature,
  mode:
      mode ??
      (provenance == Provenance.sdkOnDevice
          ? HybridMode.onlyOnDevice
          : HybridMode.onlyInCloud),
  kinds: kinds,
  transferPermitted: transferPermitted ?? provenance != Provenance.sdkOnDevice,
  provenance: provenance,
  modelLabel: modelLabel,
  error: error,
);

/// Phone-sized surface so layout problems show up as overflow errors.
Future<void> pumpPhone(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}
