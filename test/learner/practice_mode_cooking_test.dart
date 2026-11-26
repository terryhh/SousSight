// The cooking screen in practice mode (rehearsal) with its simulated hybrid
// runtime, at phone size (SS-089). Fakes only: no model, camera or network.

import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/hybrid_controls.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/cooking_research.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/research/cooking_research_panel.dart';
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

class _SlowResearch implements CookingResearchClient {
  final pending = Completer<CookingResearchResult>();
  @override
  Future<CookingResearchResult> research(CookingResearchQuery query) =>
      pending.future;
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
    // The reply keeps the ingredients card (SS-089).
    expect(find.text('On your counter'), findsOneWidget);
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

  for (final still in [false, true]) {
    testWidgets('research: "Checking sources…" in the dock, then the panel '
        'scrolled into view (G2c, reduced motion: $still)', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = (await tester.runAsync(fakeServices))!;
      final research = _SlowResearch();
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(412, 915),
              disableAnimations: still,
            ),
            child: CookingScreen(
              services: services,
              isDemo: true,
              createCoordinator: () => CookingCoordinator(
                services: services,
                isDemo: true,
                research: research,
                transportFactory: null,
                media: RehearsalLiveMedia(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('cooking-message-input')),
        'Can I use almond butter?',
      );
      await tester.tap(find.byKey(const ValueKey('research-question')));
      await tester.pump();
      expect(find.byKey(const ValueKey('research-checking')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('research-checking')),
          matching: find.byType(CircularProgressIndicator),
        ),
        still ? findsNothing : findsOneWidget,
      );
      research.pending.complete(
        const CookingResearchResult(answer: 'Yes, almond butter works.'),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('research-checking')), findsNothing);
      final panel = tester.getRect(find.byType(CookingResearchPanel));
      final dock = tester.getRect(
        find.byKey(const ValueKey('cooking-control-dock')),
      );
      // The panel is on screen, above the dock.
      expect(panel.bottom, greaterThan(0));
      expect(panel.top, lessThan(dock.top));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a real build without Live: plain dock line, and "Check my '
      'food" still answers (items 2, Maya 5)', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(fakeServices))!;
    final runtime = HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: const CloudRoutes({}),
      cloudFallback: const NoCloudInPracticeMode(),
      isOnline: () => true,
    );
    await tester.pumpWidget(
      CookingApp(services: services, isDemo: false, hybrid: runtime),
    );
    await tester.pumpAndSettle();
    expect(find.text('Type a question below.'), findsOneWidget);
    expect(find.textContaining('Coach Lite'), findsNothing);
    // No Live coach: the camera card never asks to connect one.
    expect(
      find.text('Your camera stays off until you tap Watch my food.'),
      findsOneWidget,
    );
    expect(find.textContaining('so we can cook together'), findsNothing);
    // Nothing preselected.
    for (final chip in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip))) {
      expect(chip.selected, isFalse);
    }
    await tester.ensureVisible(find.text('Check my food'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ready'));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check my food'));
    await tester.pumpAndSettle();
    expect(find.textContaining('You said: Ready.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('readiness: one calm line whose Details opens the sheet', (
    tester,
  ) async {
    const unavailable = HybridAvailability(
      status: OnDeviceStatus.unavailable,
      reason: 'device_not_eligible',
    );
    final runtime = HybridRuntime.create(
      inference: FakeHybridInference(
        textAvailability: unavailable,
        imageAvailability: unavailable,
      ),
      cloudRoutes: const CloudRoutes({}),
      cloudFallback: const NoCloudInPracticeMode(),
      isOnline: () => true,
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: runtime.navigatorKey,
        home: Scaffold(body: HybridReadinessCard(hybrid: runtime)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('readiness-line')), findsOneWidget);
    expect(find.byKey(const ValueKey('readiness-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('readiness-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('on-device-intro')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('readiness-line')), findsOneWidget);
  });

  testWidgets('no photo model: the watch is refused up front, with one '
      'honest line and the cue (production QA 1)', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(fakeServices))!;
    final runtime = HybridRuntime.create(
      inference: FakeHybridInference(
        imageAvailability: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
        ),
      ),
      cloudRoutes: const CloudRoutes({}),
      cloudFallback: const NoCloudInPracticeMode(),
      isOnline: () => true,
    );
    await tester.pumpWidget(
      CookingApp(services: services, isDemo: false, hybrid: runtime),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('watch-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('watch-toggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining("can't check photos yet"), findsWidgets);
    expect(find.textContaining('Meanwhile, look for:'), findsWidgets);
    expect(find.text('WATCHING WITH YOU'), findsNothing);
    expect(find.textContaining('Connect the Live coach'), findsNothing);
    expect(find.text('CAMERA OFF'), findsOneWidget);
    expect(find.text('Watch my food'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
