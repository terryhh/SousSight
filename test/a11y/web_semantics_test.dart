import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/a11y/web_semantics.dart';

// SS-118 (A11Y-06): on web the app turns the semantics tree on at startup, so
// assistive technology that never presses Flutter's hidden "Enable
// accessibility" placeholder still finds named controls. These are VM tests
// with the platform flag injected; the real web engine behaviour is checked
// in Chrome (see the PR).
//
// testWidgets turns semantics on by default; these tests start with it off,
// as a real web page does before any assistive technology acts. Each test
// releases the app-lifetime handle inside its body, because flutter_test
// checks for open handles before tearDown and addTearDown callbacks run.
void _test(String description, WidgetTesterCallback body) =>
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        debugResetWebSemantics();
      }
    }, semanticsEnabled: false);

void main() {
  _test('on web, it turns semantics on and builds the tree', (tester) async {
    final binding = tester.binding;
    final before = binding.debugOutstandingSemanticsHandles;
    expect(binding.semanticsEnabled, isFalse);

    final handle = enableWebSemantics(isWeb: true, binding: binding);

    expect(handle, isNotNull);
    expect(binding.semanticsEnabled, isTrue);
    expect(binding.debugOutstandingSemanticsHandles, before + 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Scan')),
        ),
      ),
    );
    expect(binding.rootPipelineOwner.semanticsOwner, isNotNull);
    expect(
      tester.getSemantics(find.text('Scan')),
      matchesSemantics(
        label: 'Scan',
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
      ),
    );

    debugResetWebSemantics();
    expect(binding.debugOutstandingSemanticsHandles, before);
    expect(binding.semanticsEnabled, isFalse);
  });

  _test('off web, it does nothing', (tester) async {
    final binding = tester.binding;
    final before = binding.debugOutstandingSemanticsHandles;

    expect(enableWebSemantics(isWeb: false, binding: binding), isNull);
    // The defaults read kIsWeb, which is false on the test VM.
    expect(enableWebSemantics(), isNull);

    expect(binding.semanticsEnabled, isFalse);
    expect(binding.debugOutstandingSemanticsHandles, before);
  });

  _test('a second call keeps the one app-lifetime handle', (tester) async {
    final binding = tester.binding;
    final before = binding.debugOutstandingSemanticsHandles;

    // No binding passed: it uses SemanticsBinding.instance.
    final first = enableWebSemantics(isWeb: true);
    final second = enableWebSemantics(isWeb: true, binding: binding);

    expect(identical(first, second), isTrue);
    expect(SemanticsBinding.instance, same(binding));
    expect(binding.debugOutstandingSemanticsHandles, before + 1);
  });

  _test('it stays on when the platform turns its own request off', (
    tester,
  ) async {
    final binding = tester.binding;
    enableWebSemantics(isWeb: true, binding: binding);

    // A screen reader starting and stopping must not switch the tree off,
    // because the app's own handle is still held.
    tester.platformDispatcher.semanticsEnabledTestValue = true;
    await tester.pump();
    tester.platformDispatcher.semanticsEnabledTestValue = false;
    await tester.pump();
    addTearDown(tester.platformDispatcher.clearSemanticsEnabledTestValue);

    expect(binding.semanticsEnabled, isTrue);
  });

  test('the hosted web entry point calls it before runApp', () {
    // tool/build_web.sh builds the hosted app; lib/main.dart only re-exports.
    final script = File('tool/build_web.sh').readAsStringSync();
    final target = RegExp(r'--target=(\S+)').firstMatch(script)!.group(1)!;
    final source = File(target).readAsStringSync();
    final body = RegExp(r'void main\(\)\s*\{([^}]*)\}')
        .firstMatch(source)!
        .group(1)!;

    expect(body, contains('enableWebSemantics();'));
    expect(
      body.indexOf('enableWebSemantics();'),
      lessThan(body.indexOf('runApp(')),
    );
    expect(
      body.indexOf('WidgetsFlutterBinding.ensureInitialized();'),
      lessThan(body.indexOf('enableWebSemantics();')),
    );
  });
}
