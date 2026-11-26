// The cooking screen in practice mode (rehearsal) with its simulated hybrid
// runtime, at phone size (SS-089). Fakes only: no model, camera or network.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/watch/watch_verdict.dart';

/// Refuses every watch check, like a device whose model can't see photos.
class _RefusingInference extends RehearsalHybridInference {
  _RefusingInference() : super(answerDelay: Duration.zero);

  @override
  Future<HybridResult> generate(HybridRequest request) =>
      request.task.feature == kLocalWatchFeature
      ? Future.error(
          const HybridException(HybridErrorCode.unavailable, 'no vision'),
        )
      : super.generate(request);
}

void main() {
  late RehearsalHybridRuntime hybrid;

  Future<void> pumpPractice(
    WidgetTester tester, {
    RehearsalHybridInference? inference,
    Size size = const Size(412, 915),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(fakeServices))!;
    hybrid = RehearsalHybridRuntime.create(
      inference:
          inference ?? RehearsalHybridInference(answerDelay: Duration.zero),
    );
    await tester.pumpWidget(
      CookingApp(services: services, isDemo: true, hybrid: hybrid),
    );
    await tester.pumpAndSettle();
  }

  Rect rectOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey(key)));

  testWidgets('phone: compact header, labelled tools, watch above the dock '
      '(items 4, 5, 13)', (tester) async {
    await pumpPractice(tester);
    // The brand row is one compact line; the tools wrap below it. (Test
    // fonts are wider than Roboto, so real heights come from the browser
    // check: see the PR.)
    expect(
      rectOf(tester, 'cooking-header-tools').top -
          rectOf(tester, 'cooking-header').top,
      lessThanOrEqualTo(56),
    );
    expect(
      find.text('A little guidance. A lot more confidence.'),
      findsNothing,
    );
    for (final label in ['On this device', 'What we sent', 'Check a label']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('PRACTICE MODE'), findsOneWidget);
    expect(
      find.textContaining('Practice mode (pretend answers)'),
      findsWidgets,
    );
    expect(find.text('Practice mode ready'), findsOneWidget);
    expect(find.text('Your live cooking companion'), findsNothing);
  });

  testWidgets('desktop: the tools sit on one row (item 5)', (tester) async {
    await pumpPractice(tester, size: const Size(1280, 800));
    final tops = {
      for (final label in ['On this device', 'What we sent', 'Check a label'])
        tester.getRect(find.text(label)).top.round(),
    };
    expect(tops, hasLength(1));
    expect(find.text('Back to pantry'), findsNothing); // no pantry here
  });

  testWidgets('send button: one accessible name, outside the field (item 12)', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpPractice(tester);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('send-message'))),
      matchesSemantics(
        label: 'Send message',
        isButton: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    expect(find.bySemanticsLabel('Send message'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cooking-message-input')),
        matching: find.byIcon(Icons.arrow_upward_rounded),
      ),
      findsNothing,
    );
    semantics.dispose();
  });

  testWidgets('a typed question gets a visible practice reply (item 3)', (
    tester,
  ) async {
    await pumpPractice(
      tester,
      inference: RehearsalHybridInference(
        answerDelay: const Duration(milliseconds: 300),
      ),
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('cooking-message-input')),
          )
          .decoration!
          .hintText,
      'Ask a question…',
    );
    await tester.enterText(
      find.byKey(const ValueKey('cooking-message-input')),
      'How thick should I spread it?',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();
    expect(find.textContaining('Thinking about “How thick'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      find.text('You asked: “How thick should I spread it?”'),
      findsOneWidget,
    );
    expect(find.textContaining('Practice answer for'), findsOneWidget);
    expect(find.text('Practice mode (pretend answers)'), findsWidgets);
    expect(find.textContaining('On this device ·'), findsNothing);
    // Scrolled into view, above the dock.
    final footer = rectOf(tester, 'coach-lite-footer');
    final dock = rectOf(tester, 'cooking-control-dock');
    expect(footer.top, greaterThanOrEqualTo(0));
    expect(footer.top, lessThan(dock.top));
  });

  testWidgets('practice watch: drawn camera, pretend verdicts cycling to '
      'ready, then "Have a look" (items 1, 13)', (tester) async {
    await pumpPractice(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('watch-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('watch-toggle')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(find.byKey(const ValueKey('local-watch-overlay')), findsOneWidget);
    expect(
      find.text('Practice mode · pretend checks, nothing sent'),
      findsOneWidget,
    );
    expect(find.text('Practice camera on · microphone off'), findsOneWidget);
    expect(find.textContaining('Watching on this device'), findsNothing);
    expect(find.textContaining('Practice watch'), findsWidgets);
    // Two more checks: unsure, then ready (the watch stops itself).
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump();
    expect(find.byKey(const ValueKey('local-watch-overlay')), findsNothing);
    expect(find.text('Have a look'), findsOneWidget);
    expect(
      find.textContaining('(practice mode, pretend answer)'),
      findsWidgets,
    );
    expect(find.textContaining('Watching set out'), findsNothing);
    // Every leg in the ledger is pretend.
    expect(hybrid.ledger.legs, isNotEmpty);
    expect(hybrid.ledger.legs.map((l) => l.provenance.name).toSet(), {
      'simulated',
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a watch that is refused after it started never leaves '
      '"Watching" up (item 1)', (tester) async {
    await pumpPractice(tester, inference: _RefusingInference());
    await tester.ensureVisible(find.byKey(const ValueKey('watch-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('watch-toggle')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    await tester.pump();
    expect(find.text('Watch stopped'), findsOneWidget);
    expect(find.textContaining('Watching set out'), findsNothing);
    expect(find.text('Watch my food'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"What we sent" in practice mode lists pretend answers only', (
    tester,
  ) async {
    await pumpPractice(tester);
    await tester.enterText(
      find.byKey(const ValueKey('cooking-message-input')),
      'Jam or not?',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pumpAndSettle();
    // The reply scrolled the header away; scroll back up to it.
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('open-ledger')),
      find.byType(CustomScrollView),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-ledger')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ledger-view')), findsOneWidget);
    expect(find.textContaining('1 practice (pretend)'), findsOneWidget);
    expect(find.byKey(const ValueKey('ledger-local-empty')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ledger-simulated')),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('ledger-view')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Practice mode (pretend answers)'), findsWidgets);
  });

  testWidgets('"On this device" in practice mode says nothing real runs', (
    tester,
  ) async {
    await pumpPractice(tester);
    await tester.ensureVisible(find.text('On this device'));
    await tester.tap(find.text('On this device'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Practice mode (pretend answers): no AI runs here'),
      findsOneWidget,
    );
  });
}
