import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/coach_lite/coach_lite_answer_card.dart';
import 'package:soussight/coach_lite/timer_suggestion_card.dart';

CoachLiteAnswer answer({
  int sequence = 1,
  List<InferenceLeg> legs = const [],
  CoachLiteTimerSuggestion? timer,
  CoachLiteStatus status = CoachLiteStatus.answered,
  RouteReason? blocked,
}) => CoachLiteAnswer(
  stamp: CoachLiteStamp(
    sessionId: 's1',
    epoch: 1,
    stepId: 'a',
    sequence: sequence,
  ),
  status: status,
  blocked: blocked,
  kind: CoachLiteQuestionKind.stepHelp,
  components: const [],
  timerSuggestion: timer,
  legs: legs,
);

const onDeviceLeg = InferenceLeg(
  requestId: 'r1',
  feature: 'coach_lite',
  mode: HybridMode.onlyOnDevice,
  kinds: {DataKind.text},
  transferPermitted: false,
  provenance: Provenance.sdkOnDevice,
);

Future<void> pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('shows where the answer ran and a prominent Start timer', (
    tester,
  ) async {
    final started = <(String, int)>[];
    await pump(
      tester,
      CoachLiteAnswerFooter(
        answer: answer(
          legs: const [onDeviceLeg],
          timer: const CoachLiteTimerSuggestion(
            label: 'Simmer sauce',
            seconds: 600,
          ),
        ),
        localModelFamily: 'Gemini Nano',
        onStartTimer: (label, seconds) => started.add((label, seconds)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('coach-lite-source')), findsOneWidget);
    expect(find.text('On this device'), findsOneWidget);
    expect(find.textContaining('Gemini Nano'), findsNothing);
    expect(find.text('Simmer sauce'), findsOneWidget);
    expect(find.text('Suggested timer · 10 min'), findsOneWidget);

    // Full-width and at least 52 px tall: the main action on the card.
    final start = find.byKey(const ValueKey('timer-suggestion-start'));
    expect(tester.getSize(start).height, greaterThanOrEqualTo(52));
    expect(tester.getSize(start).width, greaterThan(300));

    await tester.tap(start);
    await tester.pump();
    expect(started, [('Simmer sauce', 600)]);
    expect(find.text('Timer started'), findsOneWidget);
    await tester.tap(start);
    await tester.pump();
    expect(started, hasLength(1), reason: 'one tap, one timer');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no legs and no timer renders nothing', (tester) async {
    await pump(
      tester,
      CoachLiteAnswerFooter(answer: answer(), onStartTimer: (_, _) {}),
    );
    expect(find.byKey(const ValueKey('coach-lite-footer')), findsNothing);
  });

  testWidgets('a new answer resets the Start timer control', (tester) async {
    Widget footer(int sequence) => CoachLiteAnswerFooter(
      answer: answer(
        sequence: sequence,
        timer: const CoachLiteTimerSuggestion(label: 'Rest', seconds: 120),
      ),
      onStartTimer: (_, _) {},
    );
    await pump(tester, footer(1));
    await tester.tap(find.byKey(const ValueKey('timer-suggestion-start')));
    await tester.pump();
    expect(find.text('Timer started'), findsOneWidget);
    await pump(tester, footer(2));
    await tester.pumpAndSettle();
    expect(find.text('Start timer'), findsOneWidget);
  });

  testWidgets('a new suggestion in the same card resets it', (tester) async {
    Widget card(CoachLiteTimerSuggestion s) =>
        TimerSuggestionCard(suggestion: s, onStart: (_, _) {});
    await pump(
      tester,
      card(const CoachLiteTimerSuggestion(label: 'Rest', seconds: 90)),
    );
    expect(find.text('Suggested timer · 1 min 30 s'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timer-suggestion-start')));
    await tester.pump();
    expect(find.text('Timer started'), findsOneWidget);
    await pump(
      tester,
      card(const CoachLiteTimerSuggestion(label: 'Rest', seconds: 120)),
    );
    expect(find.text('Start timer'), findsOneWidget);
    expect(find.text('Suggested timer · 2 min'), findsOneWidget);
  });

  group('SS-089: a typed question always gets a visible line', () {
    test('status line per outcome; none for answers and cancels', () {
      String? line(CoachLiteStatus status, [RouteReason? reason]) =>
          coachLiteStatusLine(answer(status: status, blocked: reason));
      expect(line(CoachLiteStatus.answered), isNull);
      expect(line(CoachLiteStatus.cancelled), isNull);
      expect(line(CoachLiteStatus.invalid), contains("couldn't show"));
      expect(
        line(CoachLiteStatus.failed),
        "I can't answer that right now — try the recipe step text below.",
      );
      expect(
        line(CoachLiteStatus.blocked, RouteReason.modelDownloading),
        contains('still downloading'),
      );
      for (final r in [RouteReason.modelNotReady, RouteReason.noLocalModel]) {
        expect(
          line(CoachLiteStatus.blocked, r),
          startsWith("I can't answer questions on this device right now."),
        );
      }
      expect(
        line(CoachLiteStatus.blocked, RouteReason.offline),
        startsWith("You're offline"),
      );
      expect(
        line(CoachLiteStatus.blocked, RouteReason.localOnlySetting),
        contains('keep questions on this device'),
      );
      expect(
        line(CoachLiteStatus.blocked, RouteReason.consentDeclined),
        startsWith('OK — nothing was sent.'),
      );
      expect(
        line(CoachLiteStatus.blocked, RouteReason.cloudNotApproved),
        contains('try the recipe step text below'),
      );
      // Plain words only.
      for (final status in CoachLiteStatus.values) {
        for (final reason in [null, ...RouteReason.values]) {
          final text = line(status, reason) ?? '';
          expect(text, isNot(contains('Coach Lite')));
          expect(text, isNot(contains('on-device coach')));
        }
      }
    });

    testWidgets('a blocked answer with no legs still shows the question and '
        'why', (tester) async {
      await pump(
        tester,
        CoachLiteAnswerFooter(
          answer: answer(
            status: CoachLiteStatus.blocked,
            blocked: RouteReason.noLocalModel,
          ),
          question: '  Jam or not?  ',
          onStartTimer: (_, _) {},
        ),
      );
      expect(find.text('You asked: “Jam or not?”'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-lite-status')), findsOneWidget);
      expect(
        find.textContaining("I can't answer questions on this device"),
        findsOneWidget,
      );
      expect(find.text('COACH LITE'), findsNothing);
    });

    testWidgets('a cancelled answer with nothing to say renders nothing', (
      tester,
    ) async {
      await pump(
        tester,
        CoachLiteAnswerFooter(
          answer: answer(status: CoachLiteStatus.cancelled),
          onStartTimer: (_, _) {},
        ),
      );
      expect(find.byKey(const ValueKey('coach-lite-footer')), findsNothing);
    });
  });

  // Regression (Codex review of #201): the header overflowed at large text.
  for (final scale in [2.0, 3.0]) {
    testWidgets(
      'readable at ${(scale * 100).round()}% text on a 320 px phone',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: CoachLiteAnswerFooter(
                    answer: answer(
                      legs: const [onDeviceLeg],
                      timer: const CoachLiteTimerSuggestion(
                        label: 'Simmer the sauce',
                        seconds: 600,
                      ),
                    ),
                    localModelFamily: 'Gemini Nano',
                    onStartTimer: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'no overflow');
        // The badge drops below the label rather than squeezing beside it.
        final label = tester.getRect(find.text('ANSWER'));
        final badge = tester.getRect(
          find.byKey(const ValueKey('coach-lite-source')),
        );
        expect(badge.top, greaterThanOrEqualTo(label.bottom));
        expect(badge.right, lessThanOrEqualTo(320 - 16 + 0.5));
        expect(find.text('Start timer'), findsOneWidget);
      },
    );
  }

  // Regression (Codex review of #201): toggling Reduce Motion must not
  // rebuild the card and re-enable Start timer.
  testWidgets('a started timer stays started when Reduce Motion changes', (
    tester,
  ) async {
    final started = <(String, int)>[];
    final footerAnswer = answer(
      legs: const [onDeviceLeg],
      timer: const CoachLiteTimerSuggestion(label: 'Rest', seconds: 120),
    );
    Widget app({required bool reduce}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 844),
          disableAnimations: reduce,
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            child: CoachLiteAnswerFooter(
              answer: footerAnswer,
              onStartTimer: (label, seconds) => started.add((label, seconds)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(reduce: false));
    await tester.pumpAndSettle();
    final start = find.byKey(const ValueKey('timer-suggestion-start'));
    await tester.tap(start);
    await tester.pump();
    expect(started, hasLength(1));

    for (final reduce in [true, false, true]) {
      await tester.pumpWidget(app(reduce: reduce));
      await tester.pumpAndSettle();
      expect(find.text('Timer started'), findsOneWidget, reason: '$reduce');
      await tester.tap(start, warnIfMissed: false);
      await tester.pump();
      expect(started, hasLength(1), reason: 'no duplicate timer');
    }
  });
}
