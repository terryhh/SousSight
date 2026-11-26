// SS-100: the household message says "started" or "ready" from the cook's
// step, with a "minutes to go" estimate from the remaining step and timer
// durations. The cook reviews and edits it; simulated mode never sends an SMS.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/data/dinner_messages.dart';
import 'package:soussight/data/dinner_mode.dart';
import 'package:soussight/data/dinner_status.dart';
import 'package:soussight/genui/cooking_ui_controller.dart';
import 'package:soussight/learner/dinner_review.dart';

RecipeStep _step(String id, [int? seconds]) => RecipeStep(
  id: id,
  title: id,
  instruction: 'Do $id.',
  cue: 'Done.',
  timerSeconds: seconds,
);

final _now = DateTime(2026, 11, 26, 18);

CookingTimerState _timer(String id, Duration left) => CookingTimerState(
  id: id,
  label: id,
  startedAt: _now.subtract(const Duration(minutes: 1)),
  deadline: _now.add(left),
);

void main() {
  // prep (no timer) → simmer 20 min → rest 5 min → serve (final step).
  final steps = [
    _step('prep'),
    _step('simmer', 20 * 60),
    _step('rest', 5 * 60),
    _step('serve'),
  ];

  DinnerDraft draft(
    String? stepId, {
    bool complete = false,
    List<CookingTimerState> timers = const [],
    List<RecipeStep>? recipe,
  }) => dinnerDraftFor(
    steps: recipe ?? steps,
    currentStepId: stepId,
    complete: complete,
    now: _now,
    timers: timers,
  );

  group('dinnerDraftFor', () {
    test('before the final step it is "started" with the time to go', () {
      final first = draft('prep');
      expect(first.kind, DinnerKind.started);
      expect(first.minutes, 25);
      expect(draft('simmer').minutes, 25);
      expect(draft('rest').minutes, 5);
    });

    test('on the final step or after it is "ready"', () {
      expect(draft('serve').kind, DinnerKind.ready);
      expect(draft('serve').minutes, isNull);
      expect(draft('prep', complete: true).kind, DinnerKind.ready);
      expect(draft(null, recipe: const []).kind, DinnerKind.ready);
    });

    test('an unknown step is never "ready" and gives no time', () {
      final unknown = draft('gone');
      expect(unknown.kind, DinnerKind.started);
      expect(unknown.minutes, isNull);
      expect(draft(null).kind, DinnerKind.started);
    });

    test('no known durations leaves the time out', () {
      final untimed = [_step('a'), _step('b'), _step('c')];
      final result = draft('a', recipe: untimed);
      expect(result.kind, DinnerKind.started);
      expect(result.minutes, isNull);
    });

    test('a running step timer replaces the step duration', () {
      final result = draft(
        'simmer',
        timers: [_timer('step-simmer-1-0', const Duration(minutes: 8))],
      );
      // 8 left on simmer + 5 rest.
      expect(result.minutes, 13);
    });

    test('a finished step timer means that step has no time left', () {
      final result = draft(
        'simmer',
        timers: [_timer('step-simmer', const Duration(minutes: -1))],
      );
      expect(result.minutes, 5);
    });

    test('the longest running timer bounds the current step', () {
      // Prep has no duration, but a 12-minute oven timer is running.
      final result = draft(
        'prep',
        timers: [
          _timer('lite-1-0', const Duration(minutes: 12)),
          _timer('lite-2-1', const Duration(minutes: 3)),
        ],
      );
      expect(result.minutes, 12 + 25);
      // A step timer shorter than another running timer: the longer wins.
      final longer = draft(
        'simmer',
        timers: [
          _timer('step-simmer-1', const Duration(minutes: 2)),
          _timer('lite-9', const Duration(minutes: 10)),
        ],
      );
      expect(longer.minutes, 10 + 5);
    });

    test('a timer for another step does not count as this step\'s', () {
      final result = draft(
        'rest',
        timers: [_timer('step-simmer-1', Duration.zero)],
      );
      expect(result.minutes, 5);
    });

    test('partial minutes round up; beyond the template limit is unknown', () {
      final odd = [_step('a', 61), _step('b')];
      expect(draft('a', recipe: odd).minutes, 2);
      final long = [_step('a', 3 * 60 * 60), _step('b')];
      final result = draft('a', recipe: long);
      expect(result.kind, DinnerKind.started);
      expect(result.minutes, isNull);
    });

    test('zero or negative step durations are ignored', () {
      final odd = [_step('a', 0), _step('b', -30), _step('c')];
      expect(draft('a', recipe: odd).minutes, isNull);
    });
  });

  group('review dialog', () {
    late FakeDinnerBackend fake;

    Finder minutesField() => find.byWidgetPredicate(
      (w) =>
          w is TextField && w.decoration?.labelText == 'Minutes until dinner',
    );
    String preview(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('dinner-preview'))).data!;

    Future<void> pumpDialog(
      WidgetTester tester, {
      required DinnerKind kind,
      int? initialMinutes,
    }) async {
      fake = FakeDinnerBackend();
      addTearDown(fake.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDinnerReview(
                    context,
                    kind: kind,
                    sessionId: 'session-1',
                    recipeTitle: 'Chickpea wrap',
                    send: dinnerSenderFor(
                      DinnerMode.simulated,
                      isDemo: false,
                      fake: fake,
                      real: (_) => fail('a real SMS must never be sent'),
                    ),
                    statusSource: fake,
                    memory: DinnerAttemptMemory(),
                    isDemo: false,
                    mode: DinnerMode.simulated,
                    initialMinutes: initialMinutes,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirm simulated send'),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('started: prefilled estimate, previewed, editable', (
      tester,
    ) async {
      await pumpDialog(tester, kind: DinnerKind.started, initialMinutes: 25);
      expect(
        preview(tester),
        "SousSight: Dinner's started — about 25 minutes to go. "
        'Your cook is making Chickpea wrap.',
      );
      expect(fake.sent, isEmpty);
      await tester.enterText(minutesField(), '40');
      await tester.pump();
      expect(preview(tester), contains('about 40 minutes to go'));
      await confirm(tester);
      expect(fake.sent.single.kind, DinnerKind.started);
      expect(fake.sent.single.minutes, 40);
      expect(fake.sent.single.recipient, simulatedDinnerRecipient);
      expect(fake.sent.single.simulate, DinnerSimulation.delivered);
    });

    testWidgets('started with no estimate leaves the time out', (tester) async {
      await pumpDialog(tester, kind: DinnerKind.started);
      expect(
        tester.widget<TextField>(minutesField()).controller!.text,
        isEmpty,
      );
      expect(find.text("Leave blank if you're not sure."), findsOneWidget);
      expect(
        preview(tester),
        "SousSight: Dinner's started. Your cook is making Chickpea wrap.",
      );
      await confirm(tester);
      expect(fake.sent.single.minutes, isNull);
      expect(fake.sent.single.toJson().containsKey('minutes'), isFalse);
    });

    testWidgets('the cook can clear the estimate; bad values are refused', (
      tester,
    ) async {
      await pumpDialog(tester, kind: DinnerKind.started, initialMinutes: 25);
      await tester.enterText(minutesField(), 'soon');
      await confirm(tester);
      expect(fake.sent, isEmpty);
      expect(
        find.text('Enter 1–120 minutes, or leave it blank.'),
        findsOneWidget,
      );
      await tester.enterText(minutesField(), '  ');
      await tester.pump();
      expect(preview(tester), isNot(contains('minutes to go')));
      await confirm(tester);
      expect(fake.sent.single.minutes, isNull);
    });

    testWidgets('ready says "Dinner is ready!" and has no minutes', (
      tester,
    ) async {
      await pumpDialog(tester, kind: DinnerKind.ready, initialMinutes: 25);
      expect(minutesField(), findsNothing);
      expect(
        preview(tester),
        'SousSight: Dinner is ready! Chickpea wrap is on the table.',
      );
      await confirm(tester);
      expect(fake.sent.single.kind, DinnerKind.ready);
      expect(fake.sent.single.minutes, isNull);
    });
  });

  group('real mode', () {
    testWidgets('a blank estimate needs only a valid phone number', (
      tester,
    ) async {
      final sent = <DinnerMessageRequest>[];
      final fake = FakeDinnerBackend();
      addTearDown(fake.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DinnerReviewDialog(
              kind: DinnerKind.started,
              sessionId: 'session-1',
              recipeTitle: 'Chickpea wrap',
              // A fake standing in for the endpoint: nothing leaves the test.
              send: (request) async {
                sent.add(request);
                return const DinnerMessageResult('skipped', 'demo');
              },
              statusSource: fake,
              memory: DinnerAttemptMemory(),
              isDemo: true,
            ),
          ),
        ),
      );
      final recipient = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Recipient',
      );
      final minutes = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.labelText == 'Minutes until dinner',
      );
      await tester.enterText(recipient, '+14075550123');
      await tester.enterText(minutes, '500');
      await tester.tap(find.widgetWithText(FilledButton, 'Rehearse send'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(find.textContaining('or leave minutes blank'), findsOneWidget);
      await tester.enterText(minutes, '');
      await tester.tap(find.widgetWithText(FilledButton, 'Rehearse send'));
      await tester.pumpAndSettle();
      expect(sent.single.minutes, isNull);
      expect(sent.single.toJson().containsKey('minutes'), isFalse);
    });
  });
}
