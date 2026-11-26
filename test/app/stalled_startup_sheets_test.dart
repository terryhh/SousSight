// Codex P2 on #224: when hybrid startup outlives configureWait (or a backend
// throws during discovery), "On-device AI", "What was sent" and the
// readiness panel still open, with the local model shown as unavailable.
// Fakes only; no model, network or device is used.

import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_controls.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/trust/on_device_ai_sheet.dart';

/// Startup that never finishes (a stalled web SDK import).
class _Stalled extends FakeHybridInference {
  @override
  Future<void> configure(HybridConfig config) => Completer<void>().future;
}

/// Startup finishes, but every discovery call throws.
class _Throwing extends FakeHybridInference {
  @override
  Future<HybridCapabilities> capabilities() =>
      Future.error(StateError('bridge broke'));

  @override
  Future<HybridAvailability> availability({required bool withImage}) =>
      Future.error(StateError('bridge broke'));
}

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

HybridRuntime _runtime(HybridInference inner) => HybridRuntime.create(
  inference: inner,
  cloudRoutes: const CloudRoutes({}),
  cloudFallback: _NoCloud(),
  isOnline: () => true,
  cloudModel: 'test-model',
);

Future<void> _pumpButtons(WidgetTester tester, HybridRuntime hybrid) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: hybrid.navigatorKey,
      home: Scaffold(
        body: Column(
          children: [
            HybridHeaderButtons(hybrid: hybrid),
            Expanded(child: HybridReadinessCard(hybrid: hybrid)),
          ],
        ),
      ),
    ),
  );
}

/// Past the 10s default configureWait.
Future<void> _outlastStartup(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pumpAndSettle();
}

void main() {
  for (final (name, make) in [
    ('startup outlives configureWait', _Stalled.new),
    ('discovery throws', _Throwing.new),
  ]) {
    group(name, () {
      testWidgets('"On-device AI" opens with the model unavailable and the '
          'privacy switches usable', (tester) async {
        final hybrid = _runtime(make());
        await _pumpButtons(tester, hybrid);
        await tester.tap(find.byKey(const ValueKey('open-on-device-ai')));
        await _outlastStartup(tester);
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('on-device-ai-sheet')),
          findsOneWidget,
        );
        final status = find.byKey(const ValueKey('on-device-text-status'));
        expect(
          find.descendant(
            of: status,
            matching: find.text(
              onDeviceStatusText(
                const HybridAvailability(
                  status: OnDeviceStatus.unavailable,
                  reason: 'bridge_unavailable',
                ),
                image: false,
              ),
            ),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('local-only-pantry_scan')), findsOne);
      });

      testWidgets('"What was sent" opens the ledger', (tester) async {
        final hybrid = _runtime(make());
        await _pumpButtons(tester, hybrid);
        await tester.tap(find.byKey(const ValueKey('open-ledger')));
        await _outlastStartup(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('ledger-view')), findsOneWidget);
      });

      testWidgets('the readiness panel renders instead of failing', (
        tester,
      ) async {
        final hybrid = _runtime(make());
        await _pumpButtons(tester, hybrid);
        await _outlastStartup(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('readiness-panel')), findsOneWidget);
      });
    });
  }

  test('discoverOnDevice turns every failure into "no local model"', () async {
    final d = await discoverOnDevice(_Throwing());
    expect(d.capabilities.platform, 'none');
    expect(d.text.status, OnDeviceStatus.unavailable);
    expect(d.image.status, OnDeviceStatus.unavailable);
    final ok = await discoverOnDevice(FakeHybridInference());
    expect(ok.capabilities.platform, isNot('none'));
    expect(ok.text.status, OnDeviceStatus.available);
  });
}
