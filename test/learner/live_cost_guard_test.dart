import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/live/live_controller.dart';
import 'package:soussight/live/live_types.dart';

class _QuietTransport extends DemoLiveTransport {
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

void main() {
  testWidgets('cost warning offers one-tap extend, then pauses with a notice', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = (await tester.runAsync(fakeServices))!;
    final transport = _QuietTransport();
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
    await tester.pump();
    expect(cook.live.isActive, isTrue);
    Future<void> elapseSpeaking(int minutes) async {
      for (var i = 0; i < minutes; i++) {
        transport.source.add(
          const LiveTranscript('still cooking', isUser: true, finished: true),
        );
        await tester.pump(const Duration(minutes: 1));
      }
    }

    final extend = find.byKey(const ValueKey('extend-live-session'));
    await elapseSpeaking(6);
    expect(extend, findsNothing);
    await elapseSpeaking(1);
    expect(find.textContaining('pauses in 1 minute'), findsOneWidget);
    expect(find.text('Keep going (+5 min)'), findsOneWidget);
    await tester.tap(extend);
    await tester.pump();
    expect(extend, findsNothing);
    expect(cook.live.isActive, isTrue);
    // Three quiet minutes stop the session before the extended cap.
    await tester.pump(const Duration(minutes: 3));
    expect(cook.live.isActive, isFalse);
    // Shown in the pinned dock as well as the camera notices.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cooking-control-dock')),
        matching: find.text(liveCostPauseMessage),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
