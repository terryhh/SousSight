// Codex review of #221 at 3be7d3a: readiness honours pantry local-only live,
// rehearsal watch never claims Gemini Live, the checklist survives a model
// "ingredients" component, practice storage wording, camera errors don't
// show a match source line, and How it works follows Live availability.
// Fakes only.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/how_it_works.dart';
import 'package:soussight/app/hybrid_controls.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/app/rehearsal_runtime.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/data/dinner_mode.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/live/live_backend.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/trust/ledger_source.dart';
import 'package:soussight/trust/ledger_view.dart';
import 'package:soussight/watch/local_watch_controller.dart';
import 'package:soussight/watch/capture_owner.dart';
import 'package:soussight/watch/watch_service.dart';

const _unavailable = HybridAvailability(
  status: OnDeviceStatus.unavailable,
  reason: 'device_not_eligible',
);

class _NoCloud implements CloudFallbackSender {
  @override
  Future<HybridResult> send(HybridRequest request) =>
      throw const HybridException(HybridErrorCode.failed, 'not in tests');
  @override
  Future<void> cancel(String requestId) async {}
}

/// Camera and microphone access is refused.
class _DeniedMedia extends DemoLiveMedia {
  @override
  Future<void> start() async => throw StateError('NotAllowedError');
  @override
  Future<void> startCameraOnly() async =>
      throw StateError('NotAllowedError');
}

void main() {
  group('readiness line follows the pantry local-only setting (P2)', () {
    testWidgets('cloud path: says "sent online" only while pantry may go '
        'online, and updates live', (tester) async {
      final hybrid = HybridRuntime.create(
        inference: FakeHybridInference(
          textAvailability: _unavailable,
          imageAvailability: _unavailable,
        ),
        cloudRoutes: CloudRoutes.parse('hybridFallback'),
        cloudFallback: _NoCloud(),
        isOnline: () => true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HybridReadinessCard(hybrid: hybrid)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining("sent online to Google's AI"), findsOneWidget);
      hybrid.privacy.setLocalOnly('pantry_scan', true);
      await tester.pump();
      expect(find.textContaining("sent online to Google's AI"), findsNothing);
      expect(
        find.textContaining('You chose to keep pantry scans on this device'),
        findsOneWidget,
      );
    });
  });

  group('rehearsal watch never claims Gemini Live (P2)', () {
    test(
      'Watch my food during the pretend Live session asks to stop it',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final services = await fakeServices();
        final hybrid = RehearsalHybridRuntime.create(
          inference: RehearsalHybridInference(answerDelay: Duration.zero),
        );
        final cook = CookingCoordinator(
          services: services,
          isDemo: true,
          research: const FakeCookingResearchClient(),
          transportFactory: DemoLiveTransport.new,
          media: RehearsalLiveMedia(),
          watchServiceFactory: (live) =>
              buildWatchService(hybrid, live, simulated: true),
        );
        await cook.initialize();
        await cook.connect();
        expect(cook.live.isActive, isTrue);
        await cook.startWatch();
        expect(cook.alert, startsWith('Practice mode: tap Stop'));
        expect(cook.watchService!.statusText ?? '', isNot(contains('Gemini')));
        cook.dispose();
      },
    );

    test('a simulated Live watch status never mentions streaming', () {
      final service = WatchService(
        local: LocalWatchController(
          dispatcher: FakeHybridDispatcher(),
          capture: CaptureOwner(DemoLiveMedia()),
        ),
        startLiveWatch: (_) => 'live-1',
        stopLiveWatch: () {},
        simulated: true,
      );
      service.liveWatchStarted('live-1');
      expect(service.statusText, contains('Nothing is streamed'));
      expect(service.statusText, isNot(contains('Gemini Live')));
    });
  });

  test(
    'the counter checklist survives a model "ingredients" component (P2)',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final services = await fakeServices();
      final dispatcher = FakeHybridDispatcher()
        ..enqueue(
          '{"components":[{"id":"root","component":"CookingColumn",'
          '"children":["ingredients"]},{"id":"ingredients",'
          '"component":"stepCue","title":"Tip","body":"Stir gently."}]}',
        );
      final cook = CookingCoordinator(
        services: services,
        research: const FakeCookingResearchClient(),
        transportFactory: null,
        media: DemoLiveMedia(),
        coachLite: CoachLite(
          dispatcher: dispatcher,
          privacy: _NoPrivacy(),
          cloudRoutes: const CloudRoutes({}),
          isOnline: () => true,
        ),
      );
      await cook.initialize();
      expect(await cook.say('Any tip?'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cook.coachLiteAnswer?.status, CoachLiteStatus.answered);
      final ids = cook.ui.components.map((c) => c['id']).toSet();
      expect(ids, containsAll(['ingredients', 'app_ingredients']));
      cook.dispose();
    },
  );

  testWidgets('practice "What we sent" describes in-memory storage (P3)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LedgerView(ledger: ListLedgerSource(), practice: true),
        ),
      ),
    );
    expect(find.text(practiceStorageNote), findsOneWidget);
    expect(find.textContaining('Firestore'), findsNothing);
    expect(find.byKey(const ValueKey('ledger-details')), findsNothing);
  });

  testWidgets('a camera error never shows the match source line (P3)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recipes = (await tester.runAsync(loadRecipeCatalog))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: PantryScreen(
          recipes: recipes,
          client: const FakePantryClient(delay: Duration.zero),
          onChooseRecipe: (_, _) {},
          mediaFactory: _DeniedMedia.new,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mode-scan')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Camera or microphone is blocked'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('pantry-no-answer-source')), findsNothing);
  });

  testWidgets('How it works follows Live availability, not only the '
      'backend (P3)', (tester) async {
    Future<void> pump(CloudRoutes routes) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HowItWorksSheet(
            liveBackend: LiveBackend.aiLogic,
            cloudRoutes: routes,
            dinnerMode: DinnerMode.simulated,
          ),
        ),
      ),
    );
    await pump(const CloudRoutes({}));
    expect(
      find.textContaining('Cook with a live coach', findRichText: true),
      findsNothing,
    );
    expect(find.textContaining('Gemini Live API'), findsNothing);
    await pump(CloudRoutes.parse('live'));
    expect(
      find.textContaining('Cook with a live coach', findRichText: true),
      findsOneWidget,
    );
  });
}

class _NoPrivacy implements PrivacySettings {
  @override
  bool localOnly(String feature) => false;
}
