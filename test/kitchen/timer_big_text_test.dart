// The GenUI timer under Big text on a narrow phone (SS-107, Codex #245): the
// countdown stays on one line and Cancel moves beneath it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/genui/cooking_ui.dart';
import 'package:soussight/kitchen/kitchen_text.dart';

void main() {
  Future<CookingUiController> pumpTimer(
    WidgetTester tester, {
    required double width,
    required TextScaler scaler,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.utc(2026, 11, 26, 18);
    final controller = CookingUiController(clock: () => now);
    // The longest timer allowed: two hours.
    controller.startTimer(id: 'braise', label: 'Braise', seconds: 7200);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(size: Size(width, 900), textScaler: scaler),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: CookingSurface(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  final countdown = find.byKey(const ValueKey('timer-countdown-braise'));

  testWidgets('a long countdown stays on one line under Big text at 320 px', (
    tester,
  ) async {
    const scaler = KitchenTextScaler(TextScaler.noScaling);
    final controller = await pumpTimer(tester, width: 320, scaler: scaler);
    expect(find.text('120:00'), findsOneWidget);
    final line = scaler.scale(42);
    final box = tester.getRect(countdown);
    expect(box.height, lessThan(line * 1.6), reason: 'one line, not two');
    final cancel = tester.getRect(find.text('Cancel'));
    expect(cancel.top, greaterThanOrEqualTo(box.bottom - 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('with room, Cancel stays beside the countdown', (tester) async {
    final controller = await pumpTimer(
      tester,
      width: 800,
      scaler: TextScaler.noScaling,
    );
    final box = tester.getRect(countdown);
    final cancel = tester.getRect(find.text('Cancel'));
    expect(cancel.left, greaterThan(box.right));
    expect(cancel.center.dy, closeTo(box.center.dy, 4));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
