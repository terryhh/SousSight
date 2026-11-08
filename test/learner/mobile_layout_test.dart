import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/live/live_types.dart';
import 'package:soussight/live/live_controller.dart';

class _CaptionTransport extends DemoLiveTransport {
  final source = StreamController<LiveEvent>.broadcast();
  @override
  Stream<LiveEvent> get events => source.stream;
  @override
  Future<void> sendText(String text) async {}
  @override
  Future<void> close() async {
    await source.close();
    await super.close();
  }
}

class _PendingCapture extends DemoLiveMedia {
  final permission = Completer<void>();
  int stops = 0;
  @override
  Future<void> start() => permission.future;
  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  Future<void> openKitchen(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final services = await tester.runAsync(fakeServices);
    await tester.pumpWidget(CookingApp(services: services!, isDemo: true));
    await tester.pumpAndSettle();
  }

  testWidgets('pinned Stop cancels pending capture above the phone keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 740);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final services = (await tester.runAsync(fakeServices))!;
    final media = _PendingCapture();
    final cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: _CaptionTransport.new,
      media: media,
      isDemo: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(
          services: services,
          isDemo: true,
          createCoordinator: () => cook,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('live-session-toggle'));
    await tester.tap(toggle);
    await tester.pump();
    expect(cook.live.status, LiveCookingStatus.connecting);
    expect(
      find.descendant(of: toggle, matching: find.text('Stop')),
      findsOneWidget,
    );
    expect(toggle.hitTestable(), findsOneWidget);
    expect(tester.getRect(toggle).bottom, lessThanOrEqualTo(440));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(media.stops, greaterThan(0));
    expect(cook.live.isActive, isFalse);
    // A permission result arriving after Stop must not resurrect the session.
    media.permission.complete();
    await tester.pumpAndSettle();
    expect(cook.live.isActive, isFalse);
    expect(
      find.descendant(of: toggle, matching: find.text('Start')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [
    const Size(320, 640),
    const Size(360, 740),
    const Size(390, 844),
    const Size(430, 932),
    const Size(740, 360),
  ]) {
    testWidgets('cooking workspace fits ${size.width}x${size.height}', (
      tester,
    ) async {
      await openKitchen(tester, size);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton && widget.tooltip == 'Review dinner message',
        ),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == 'Review dinner message',
            )
            .hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'mobile keeps composer and session controls outside workspace scrolling',
    (tester) async {
      await openKitchen(tester, const Size(390, 844));
      final composer = find.byKey(const ValueKey('cooking-message-input'));
      final controls = find.byKey(const ValueKey('live-session-toggle'));
      expect(composer.hitTestable(), findsOneWidget);
      expect(controls.hitTestable(), findsOneWidget);
      final before = tester.getRect(composer);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.getRect(composer), before);
      expect(composer.hitTestable(), findsOneWidget);
      expect(controls.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [735.0, 1280.0]) {
    testWidgets('empty camera fills its preview at ${width}px', (tester) async {
      await openKitchen(tester, Size(width, 900));
      final placeholder = find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).gradient != null,
      );
      final preview = find
          .ancestor(of: placeholder, matching: find.byType(ClipRRect))
          .first;
      final backgroundBounds = tester.getRect(placeholder);
      final previewBounds = tester.getRect(preview);
      expect(backgroundBounds.left, previewBounds.left);
      expect(backgroundBounds.right, previewBounds.right);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'long captions scroll within a bounded height without moving live controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final services = (await tester.runAsync(fakeServices))!;
      final transport = _CaptionTransport();
      final cook = CookingCoordinator(
        services: services,
        research: FakeCookingResearchClient(),
        transportFactory: () => transport,
        media: DemoLiveMedia(),
        isDemo: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: cookingTheme,
          home: CookingScreen(
            services: services,
            isDemo: true,
            createCoordinator: () => cook,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await cook.connect();
      await tester.pumpAndSettle();
      final stopBefore = tester.getTopLeft(
        find.byKey(const ValueKey('live-session-toggle')),
      );
      transport.source.add(
        LiveTranscript(
          List.filled(100, 'Keep stirring slowly.').join(' '),
          isUser: false,
        ),
      );
      await tester.pumpAndSettle();
      final caption = find.byKey(const ValueKey('coach-caption-scroll'));
      expect(tester.getSize(caption).height, lessThanOrEqualTo(160));
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: caption, matching: find.byType(Scrollable)),
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('live-session-toggle'))),
        stopBefore,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('large text preserves mobile live controls and timer', (
    tester,
  ) async {
    await openKitchen(tester, const Size(320, 740), textScale: 1.5);
    expect(tester.takeException(), isNull);
    final start = find.byKey(const ValueKey('live-session-toggle'));
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Watch my bowl'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    for (final button in [
      find.byKey(const ValueKey('live-session-toggle')),
      find.byKey(const ValueKey('microphone-toggle')),
      find.ancestor(
        of: find.text('Watch my bowl'),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      ),
    ]) {
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    }
    await tester.scrollUntilVisible(
      find.text('Start 5-minute timer'),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start 5-minute timer'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('5:00'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Check my bowl').last,
      -250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check my bowl').last);
    await tester.pump();
    await tester.pump();
    expect(find.text('Rehearsal: a little more mashing'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets(
      'generated growth preserves focused input and reachable stop at ${width}px',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 740);
        tester.view.viewPadding = const FakeViewPadding(bottom: 20);
        tester.platformDispatcher.textScaleFactorTestValue = width == 320
            ? 1.5
            : 1;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetViewInsets);
        final services = (await tester.runAsync(fakeServices))!;
        final transport = _CaptionTransport();
        final cook = CookingCoordinator(
          services: services,
          research: FakeCookingResearchClient(),
          transportFactory: () => transport,
          media: DemoLiveMedia(),
          isDemo: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: cookingTheme,
            home: CookingScreen(
              services: services,
              isDemo: true,
              createCoordinator: () => cook,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await cook.connect();
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('cooking-message-input'));
        final stop = find.byKey(const ValueKey('live-session-toggle'));
        await tester.enterText(input, 'Can I add lemon?');
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        final inputBefore = tester.getRect(input);
        final stopBefore = tester.getRect(stop);
        final editable = tester.widget<EditableText>(
          find.descendant(of: input, matching: find.byType(EditableText)),
        );
        expect(editable.focusNode.hasFocus, isTrue);
        expect(inputBefore.bottom, lessThanOrEqualTo(440));
        expect(stopBefore.bottom, lessThanOrEqualTo(440));
        cook.ui.applyToolPayload({
          'components': [
            {
              'id': 'root',
              'component': 'CookingColumn',
              'children': [for (var i = 0; i < 10; i++) 'cue$i'],
            },
            for (var i = 0; i < 10; i++)
              {
                'id': 'cue$i',
                'component': 'stepCue',
                'title': 'Generated cue $i',
                'body': List.filled(10, 'Check the visible texture.').join(' '),
              },
          ],
        });
        await tester.pumpAndSettle();
        expect(tester.getRect(input), inputBefore);
        expect(tester.getRect(stop), stopBefore);
        expect(editable.focusNode.hasFocus, isTrue);
        expect(editable.controller.text, 'Can I add lemon?');
        expect(input.hitTestable(), findsOneWidget);
        expect(stop.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(stop);
        await tester.pumpAndSettle();
        expect(cook.live.isActive, isFalse);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('dinner review scrolls above the phone keyboard', (tester) async {
    await openKitchen(tester, const Size(360, 640));
    await tester.scrollUntilVisible(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton && widget.tooltip == 'Review dinner message',
      ),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton && widget.tooltip == 'Review dinner message',
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.widgetWithText(TextButton, 'Close').hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
