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
}) => CoachLiteAnswer(
  stamp: CoachLiteStamp(
    sessionId: 's1',
    epoch: 1,
    stepId: 'a',
    sequence: sequence,
  ),
  status: CoachLiteStatus.answered,
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
    expect(find.text('On this device · Gemini Nano'), findsOneWidget);
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
}
