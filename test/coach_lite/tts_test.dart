// Coach Lite read-aloud (SS-077) against a fake voice only. No platform
// text-to-speech runs; these tests do not show how a device or browser voice
// sounds or where it runs.

import 'dart:async';
import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/coach_lite/tts.dart';
import 'package:soussight/coach_lite/tts_toggle.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/live/live_types.dart';

class FakeTts implements TextToSpeech {
  FakeTts({
    this.support = const TtsSupport(
      available: true,
      locality: VoiceLocality.deviceEngine,
    ),
  });

  TtsSupport support;
  final List<String> spoken = [];
  int stops = 0;

  /// When set, `stop` waits for it (a slow platform channel).
  Completer<void>? stopGate;

  @override
  Future<TtsSupport> probe() async => support;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {
    stops++;
    final gate = stopGate;
    if (gate != null) await gate.future;
  }
}

CoachLiteAnswer _answer({
  int sequence = 1,
  String stepId = 'simmer',
  CoachLiteStatus status = CoachLiteStatus.answered,
  List<Map<String, dynamic>>? components,
}) => CoachLiteAnswer(
  stamp: CoachLiteStamp(
    sessionId: 's',
    epoch: 0,
    stepId: stepId,
    sequence: sequence,
  ),
  status: status,
  kind: CoachLiteQuestionKind.stepHelp,
  components:
      components ??
      [
        {
          'id': 'root',
          'component': 'CookingColumn',
          'children': ['tip'],
        },
        {
          'id': 'tip',
          'component': 'stepCue',
          'title': 'Low and slow $sequence',
          'body': 'Stir often',
        },
      ],
);

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('spoken text', () {
    test('reads components in display order', () {
      final text = coachLiteSpokenText(
        _answer(
          components: [
            {
              'id': 'root',
              'component': 'CookingColumn',
              'children': ['cmp', 'tip'],
            },
            {
              'id': 'tip',
              'component': 'stepCue',
              'title': 'Then',
              'body': 'Lower the heat',
            },
            {
              'id': 'cmp',
              'component': 'comparison',
              'title': 'Sauce',
              'observed': 'thin and watery',
              'target': 'coats a spoon',
              'cue': 'Draw a line on the spoon.',
            },
          ],
        ),
      );
      expect(
        text,
        'Sauce. You said: thin and watery. Aim for: coats a spoon. '
        'Draw a line on the spoon. Then. Lower the heat.',
      );
    });

    test('never speaks a sentence that certifies doneness or safety', () {
      // Model answers are already rejected for this; the read-aloud path
      // checks every sentence again, whatever built the components.
      final text = coachLiteSpokenText(
        _answer(
          components: [
            {
              'id': 'root',
              'component': 'CookingColumn',
              'children': ['a'],
            },
            {
              'id': 'a',
              'component': 'stepCue',
              'title': 'Chicken',
              'body':
                  'The chicken is done. It is safe to eat! '
                  'Check the thickest part with a thermometer.',
            },
          ],
        ),
      );
      expect(text, 'Chicken. Check the thickest part with a thermometer.');
      expect(coachLiteCertifies(text), isFalse);
    });

    test('the app safety notice is spoken: it certifies nothing', () {
      expect(coachLiteCertifies(coachLiteSafetyNotice), isFalse);
    });

    test('a cancelled answer says nothing', () {
      expect(
        coachLiteSpokenText(_answer(status: CoachLiteStatus.cancelled)),
        isEmpty,
      );
    });

    test('long answers are cut at a sentence end', () {
      final text = coachLiteSpokenText(
        _answer(
          components: [
            {
              'id': 'root',
              'component': 'CookingColumn',
              'children': ['a'],
            },
            {
              'id': 'a',
              'component': 'stepCue',
              'title': 'Tip',
              'body': List.filled(100, 'Stir the pot gently.').join(' '),
            },
          ],
        ),
        maxChars: 100,
      );
      expect(text.length, lessThanOrEqualTo(100));
      expect(text, endsWith('.'));
    });
  });

  group('speaker', () {
    late FakeTts tts;
    late CoachLiteSpeaker speaker;

    void sync(
      CoachLiteAnswer? answer, {
      bool busy = false,
      bool live = false,
      String step = 'simmer',
    }) => speaker.sync(
      answer: answer,
      busy: busy,
      liveActive: live,
      stepId: step,
    );

    setUp(() async {
      tts = FakeTts();
      speaker = CoachLiteSpeaker(tts);
      await speaker.init();
    });

    var disposed = false;
    tearDown(() {
      if (!disposed) speaker.dispose();
      disposed = false;
    });

    test('is off by default: answers are not read', () async {
      sync(_answer());
      await _settle();
      expect(speaker.enabled, isFalse);
      expect(tts.spoken, isEmpty);
    });

    test('turning it on reads the answer on screen, once', () async {
      sync(_answer());
      speaker.setEnabled(true);
      await _settle();
      expect(tts.spoken, ['Low and slow 1. Stir often.']);
      // Unrelated coordinator updates do not repeat it.
      sync(_answer());
      sync(_answer());
      await _settle();
      expect(tts.spoken, hasLength(1));
    });

    test('a new answer is read when it arrives', () async {
      speaker.setEnabled(true);
      sync(_answer());
      await _settle();
      sync(_answer(sequence: 2));
      await _settle();
      expect(tts.spoken, [
        'Low and slow 1. Stir often.',
        'Low and slow 2. Stir often.',
      ]);
    });

    test('asking again stops speech; a failed re-ask does not re-read the '
        'old answer', () async {
      speaker.setEnabled(true);
      final first = _answer();
      sync(first);
      await _settle();
      final stopsBefore = tts.stops;
      sync(first, busy: true);
      expect(tts.stops, stopsBefore + 1);
      // The new question failed: the coordinator still shows the old answer.
      sync(first);
      await _settle();
      expect(tts.spoken, hasLength(1));
    });

    test('a step change stops speech', () async {
      speaker.setEnabled(true);
      sync(_answer());
      await _settle();
      final stopsBefore = tts.stops;
      sync(null, step: 'serve');
      expect(tts.stops, stopsBefore + 1);
      // An answer stamped for another step is never read.
      sync(_answer(sequence: 3), step: 'serve');
      await _settle();
      expect(tts.spoken, hasLength(1));
    });

    test(
      'Live connecting stops speech and nothing is read while it is on',
      () async {
        speaker.setEnabled(true);
        sync(_answer());
        await _settle();
        final stopsBefore = tts.stops;
        sync(_answer(), live: true);
        expect(tts.stops, stopsBefore + 1);
        sync(_answer(sequence: 2), live: true);
        await _settle();
        expect(tts.spoken, hasLength(1));
      },
    );

    test('a stop while the platform is still stopping cancels the pending '
        'speak', () async {
      speaker.setEnabled(true);
      tts.stopGate = Completer<void>();
      sync(_answer());
      await _settle();
      // speak() is waiting for the platform stop; the cook asks again.
      sync(_answer(), busy: true);
      tts.stopGate!.complete();
      tts.stopGate = null;
      await _settle();
      expect(tts.spoken, isEmpty);
    });

    test('a newer answer while starting replaces the older one', () async {
      speaker.setEnabled(true);
      tts.stopGate = Completer<void>();
      sync(_answer());
      await _settle();
      sync(_answer(sequence: 2));
      tts.stopGate!.complete();
      tts.stopGate = null;
      await _settle();
      expect(tts.spoken, ['Low and slow 2. Stir often.']);
    });

    test('turning it off stops speech and later answers stay silent', () async {
      speaker.setEnabled(true);
      sync(_answer());
      await _settle();
      final stopsBefore = tts.stops;
      speaker.setEnabled(false);
      expect(tts.stops, stopsBefore + 1);
      sync(_answer(sequence: 2));
      await _settle();
      expect(tts.spoken, hasLength(1));
    });

    test('disposal stops speech and cancels a pending speak', () async {
      speaker.setEnabled(true);
      tts.stopGate = Completer<void>();
      sync(_answer());
      await _settle();
      speaker.dispose();
      tts.stopGate!.complete();
      await _settle();
      expect(tts.spoken, isEmpty);
      expect(tts.stops, greaterThanOrEqualTo(2));
      disposed = true;
    });

    test('stays off where the platform cannot speak', () async {
      final none = CoachLiteSpeaker(FakeTts(support: TtsSupport.unavailable));
      await none.init();
      none.setEnabled(true);
      expect(none.enabled, isFalse);
      none.dispose();
    });
  });

  group('toggle', () {
    testWidgets('hidden when the platform cannot speak', (tester) async {
      final speaker = CoachLiteSpeaker(
        FakeTts(support: TtsSupport.unavailable),
      );
      await speaker.init();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CoachLiteSpeakerToggle(speaker: speaker)),
        ),
      );
      expect(find.byKey(const ValueKey('coach-lite-read-aloud')), findsNothing);
      speaker.dispose();
    });

    testWidgets('says where the voice runs before it is turned on', (
      tester,
    ) async {
      final tts = FakeTts(
        support: const TtsSupport(
          available: true,
          locality: VoiceLocality.browserMayUseNetwork,
        ),
      );
      final speaker = CoachLiteSpeaker(tts);
      await speaker.init();
      speaker.sync(
        answer: _answer(),
        busy: false,
        liveActive: false,
        stepId: 'simmer',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CoachLiteSpeakerToggle(speaker: speaker)),
        ),
      );
      expect(find.textContaining('Read answers aloud: off.'), findsOneWidget);
      expect(find.textContaining('may use an online voice'), findsOneWidget);
      expect(find.byTooltip('Read answers aloud'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('coach-lite-read-aloud')));
      await tester.pump();
      expect(speaker.enabled, isTrue);
      expect(tts.spoken, ['Low and slow 1. Stir often.']);
      expect(find.byTooltip('Stop reading answers aloud'), findsOneWidget);
      speaker.dispose();
    });

    test('captions never claim on-device for a browser voice that is not '
        'reported local', () {
      expect(
        readAloudCaption(VoiceLocality.browserMayUseNetwork),
        isNot(contains('on this device')),
      );
      expect(readAloudCaption(VoiceLocality.browserLocal), contains('reports'));
    });
  });

  testWidgets('cooking screen: an answer is read once the cook turns the '
      'speaker on; asking again and Live connecting stop it', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = (await tester.runAsync(fakeServices))!;
    final dispatcher = _GatedDispatcher();
    final tts = FakeTts();
    final transport = _QuietTransport();
    final cook = CookingCoordinator(
      services: services,
      research: FakeCookingResearchClient(),
      transportFactory: () => transport,
      media: DemoLiveMedia(),
      isDemo: true,
      coachLite: CoachLite(
        dispatcher: dispatcher,
        privacy: _NoLocalOnly(),
        cloudRoutes: const CloudRoutes({}),
        isOnline: () => true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: cookingTheme,
        home: CookingScreen(
          services: services,
          isDemo: true,
          createCoordinator: () => cook,
          textToSpeech: () => tts,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('coach-lite-read-aloud'));
    expect(toggle, findsNothing, reason: 'no answer yet');
    expect(await cook.say('How hot?'), isTrue);
    await tester.pump();
    dispatcher.gates.last.complete(
      DispatchResult(text: _json('Keep the heat low.'), legs: const []),
    );
    await tester.pumpAndSettle();
    expect(tts.spoken, isEmpty, reason: 'off by default');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(tts.spoken.single, contains('Keep the heat low.'));

    // Asking again stops the voice before the new answer arrives.
    final stops = tts.stops;
    await cook.say('And now?');
    await tester.pump();
    expect(tts.stops, greaterThan(stops));
    dispatcher.gates.last.complete(
      DispatchResult(text: _json('Stir every minute.'), legs: const []),
    );
    await tester.pumpAndSettle();
    expect(tts.spoken.last, contains('Stir every minute.'));

    // Live takes over: speech stops.
    final beforeLive = tts.stops;
    await cook.connect();
    await tester.pump();
    expect(cook.live.isActive, isTrue);
    expect(tts.stops, greaterThan(beforeLive));
    await tester.pumpWidget(const SizedBox());
  });
}

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

class _GatedDispatcher implements HybridDispatcher {
  final List<Completer<DispatchResult>> gates = [];
  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    final gate = Completer<DispatchResult>();
    gates.add(gate);
    return HybridOperation('gated-${gates.length}', gate.future, () {});
  }
}

class _NoLocalOnly implements PrivacySettings {
  @override
  bool localOnly(String feature) => false;
}

String _json(String body) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['tip'],
    },
    {'id': 'tip', 'component': 'stepCue', 'title': 'Tip', 'body': body},
  ],
});
