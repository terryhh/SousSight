import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/kitchen/kitchen_mode.dart';
import 'package:soussight/kitchen/kitchen_preferences.dart';
import 'package:soussight/kitchen/kitchen_text.dart';
import 'package:soussight/kitchen/screen_wake_lock.dart';

/// Shrinks large fonts' scaling, like Android 14's nonlinear font scale.
class _Nonlinear extends TextScaler {
  const _Nonlinear();
  @override
  double scale(double fontSize) =>
      fontSize <= 20 ? fontSize * 2 : 40 + (fontSize - 20) * 1.2;
  @override
  double get textScaleFactor => 2;
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('taps $taps'),
  );
}

void main() {
  group('KitchenTextScaler', () {
    test('enlarges on top of no system scaling', () {
      const scaler = KitchenTextScaler(TextScaler.noScaling);
      expect(scaler.scale(14), 21);
      expect(scaler.scale(42), 63);
      expect(scaler.textScaleFactor, 1.5);
    });

    test('multiplies the system scale rather than replacing it', () {
      expect(const KitchenTextScaler(TextScaler.linear(1.3)).scale(10), 19.5);
      // 2x system: 1.5x more would be 3x, which is the cap.
      expect(const KitchenTextScaler(TextScaler.linear(2)).scale(14), 42);
      // 2.5x system: capped at 3x, still above the system's own size.
      expect(const KitchenTextScaler(TextScaler.linear(2.5)).scale(14), 42);
    });

    test('never shows text smaller than the system alone would', () {
      // A 3.5x system scale is above the cap: the system wins.
      expect(const KitchenTextScaler(TextScaler.linear(3.5)).scale(14), 49);
    });

    test('lets a nonlinear system scaler shape the result', () {
      const scaler = KitchenTextScaler(_Nonlinear());
      // System's scaling of 21 (= 14 * 1.5) is 41.2, under the 42 cap.
      expect(scaler.scale(14), closeTo(41.2, 1e-9));
    });

    test('equality, hash and description', () {
      const a = KitchenTextScaler(TextScaler.noScaling);
      const b = KitchenTextScaler(TextScaler.noScaling);
      const c = KitchenTextScaler(TextScaler.noScaling, factor: 2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a.toString(), contains('1.5x'));
    });
  });

  group('widgets', () {
    late KitchenMode mode;
    late InMemoryKitchenPreferences prefs;

    setUp(() {
      prefs = InMemoryKitchenPreferences();
      mode = KitchenMode(
        wakeLock: FakeScreenWakeLock(),
        preferences: prefs,
        observeLifecycle: false,
      );
    });
    tearDown(() => mode.dispose());

    Future<void> pump(WidgetTester tester, {double system = 1}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(system)),
              child: Scaffold(
                body: Column(
                  children: [
                    KitchenBigTextToggle(mode: mode),
                    KitchenBigText(mode: mode, child: const _Counter()),
                  ],
                ),
              ),
            ),
          ),
        );

    TextScaler scalerOf(WidgetTester tester) =>
        MediaQuery.textScalerOf(tester.element(find.byType(_Counter)));

    testWidgets('the toggle enlarges the wrapped text and saves the choice', (
      tester,
    ) async {
      await pump(tester);
      expect(scalerOf(tester), TextScaler.noScaling);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('kitchen-big-text'))),
        isSemantics(isSelected: false, label: 'Big text', isButton: true),
      );

      await tester.tap(find.byKey(const ValueKey('kitchen-big-text')));
      await tester.pumpAndSettle();
      expect(mode.bigText, isTrue);
      expect(prefs.bigText, isTrue);
      expect(scalerOf(tester), isA<KitchenTextScaler>());
      expect(scalerOf(tester).scale(14), 21);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('kitchen-big-text'))),
        isSemantics(isSelected: true, label: 'Big text', isButton: true),
      );

      await tester.tap(find.byKey(const ValueKey('kitchen-big-text')));
      await tester.pumpAndSettle();
      expect(prefs.bigText, isFalse);
      expect(scalerOf(tester), TextScaler.noScaling);
    });

    testWidgets('keeps the system text scale underneath', (tester) async {
      await pump(tester, system: 1.3);
      expect(scalerOf(tester), const TextScaler.linear(1.3));
      await mode.setBigText(true);
      await tester.pump();
      expect(scalerOf(tester).scale(10), 19.5);
    });

    testWidgets('turning it on and off keeps the state below', (tester) async {
      await pump(tester);
      await tester.tap(find.text('taps 0'));
      await tester.pump();
      await mode.setBigText(true);
      await tester.pump();
      expect(find.text('taps 1'), findsOneWidget);
      await mode.setBigText(false);
      await tester.pump();
      expect(find.text('taps 1'), findsOneWidget);
    });
  });
}
