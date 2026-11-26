import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/genui/cook_announcer.dart';

void main() {
  late List<String> sent;
  late CookAnnouncer announcer;

  setUp(() {
    sent = [];
    announcer = CookAnnouncer(send: (message) async => sent.add(message));
  });

  tearDown(() => announcer.dispose());

  void step(
    String id, {
    String session = 's1',
    int number = 2,
    String title = 'Chop the tomato and onion',
    String instruction = 'Dice them small.',
  }) => announcer.stepShown(
    sessionId: session,
    stepId: id,
    number: number,
    count: 5,
    title: title,
    instruction: instruction,
  );

  void timer(String id, {String session = 's1', int seconds = 300}) =>
      announcer.timerStarted(
        sessionId: session,
        timerId: id,
        label: 'Let the flavors meld',
        seconds: seconds,
      );

  /// Lets the zero-delay delivery timer fire.
  Future<void> deliver() => Future<void>.delayed(Duration.zero);

  testWidgets(
    'a step change reaches the screen reader as a polite announcement',
    (tester) async {
      final real = CookAnnouncer();
      addTearDown(real.dispose);
      real.stepShown(
        sessionId: 's1',
        stepId: 'chop',
        number: 2,
        count: 5,
        title: 'Chop the tomato and onion',
        instruction: 'Dice them small.\nLook for even pieces',
      );
      await tester.pump(Duration.zero);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement(
          'Step 2 of 5. Chop the tomato and onion. Dice them small. '
          'Look for even pieces.',
        ),
      ]);
    },
  );

  testWidgets('a timer start reaches the screen reader', (tester) async {
    final real = CookAnnouncer();
    addTearDown(real.dispose);
    real.timerStarted(
      sessionId: 's1',
      timerId: 't1',
      label: 'Let the flavors meld',
      seconds: 300,
    );
    await tester.pump(Duration.zero);
    expect(tester.takeAnnouncements(), [
      isAccessibilityAnnouncement(
        '5-minute timer started: Let the flavors meld.',
      ),
    ]);
  });

  test('nothing is sent before the turn ends', () async {
    step('chop');
    expect(sent, isEmpty);
    await deliver();
    expect(sent, hasLength(1));
  });

  test('the same step is announced once, however often it is shown', () async {
    step('chop');
    await deliver();
    step('chop');
    step('chop', title: 'A regenerated title for the same step');
    await deliver();
    expect(sent, ['Step 2 of 5. Chop the tomato and onion. Dice them small.']);
  });

  test(
    'two step changes before delivery read only the step on screen',
    () async {
      step('chop');
      step('mix', number: 3, title: 'Mix the salsa', instruction: '');
      await deliver();
      expect(sent, ['Step 3 of 5. Mix the salsa.']);
    },
  );

  test('going back to an earlier step announces it again', () async {
    step('chop');
    await deliver();
    step('mix', number: 3);
    await deliver();
    step('chop');
    await deliver();
    expect(sent, hasLength(3));
  });

  test('a step change and a timer start go out as one message', () async {
    step('rest', number: 4, title: 'Rest', instruction: 'Cover the bowl!');
    timer('t1');
    await deliver();
    expect(sent, [
      'Step 4 of 5. Rest. Cover the bowl! '
          '5-minute timer started: Let the flavors meld.',
    ]);
  });

  test('each timer is announced once; a repeated start is silent', () async {
    timer('t1');
    timer('t1');
    await deliver();
    timer('t1');
    timer('t2', seconds: 45);
    await deliver();
    expect(sent, [
      '5-minute timer started: Let the flavors meld.',
      '45-second timer started: Let the flavors meld.',
    ]);
  });

  test('a timer with a blank label still says it started', () async {
    announcer.timerStarted(
      sessionId: 's1',
      timerId: 't1',
      label: '  ',
      seconds: 60,
    );
    await deliver();
    expect(sent, ['1-minute timer started.']);
  });

  test('timer lengths match the timer button wording', () {
    expect(timerLength(300), '5-minute');
    expect(timerLength(60), '1-minute');
    expect(timerLength(90), '90-second');
    expect(timerLength(30), '30-second');
  });

  test(
    'a new session drops the old session\'s pending announcements',
    () async {
      step('chop');
      timer('t1');
      step('chop', session: 's2', number: 1, title: 'Gather', instruction: '');
      await deliver();
      expect(sent, ['Step 1 of 5. Gather.']);
    },
  );

  test('a new session starts fresh, so its steps and timers are new', () async {
    step('chop');
    timer('t1');
    await deliver();
    step('chop', session: 's2');
    timer('t1', session: 's2');
    await deliver();
    expect(sent, hasLength(2));
    expect(sent.last, contains('5-minute timer started'));
  });

  test('reset drops pending announcements and forgets what was read', () async {
    step('chop');
    announcer.reset();
    await deliver();
    expect(sent, isEmpty);
    step('chop');
    await deliver();
    expect(sent, hasLength(1));
  });

  test('a call without a session is ignored', () async {
    step('chop', session: '');
    timer('t1', session: '');
    await deliver();
    expect(sent, isEmpty);
  });

  test('nothing is announced after dispose', () async {
    step('chop');
    announcer.dispose();
    await deliver();
    step('mix');
    timer('t1');
    await deliver();
    expect(sent, isEmpty);
  });

  test(
    'a failed send is swallowed and later announcements still go out',
    () async {
      var calls = 0;
      final failing = CookAnnouncer(
        send: (message) {
          calls++;
          return calls == 1
              ? Future<void>.error(StateError('no screen reader'))
              : Future<void>.value();
        },
      );
      addTearDown(failing.dispose);
      final errors = <Object>[];
      await runZonedGuarded(() async {
        failing.stepShown(
          sessionId: 's1',
          stepId: 'chop',
          number: 1,
          count: 2,
          title: 'Chop',
        );
        await deliver();
        await deliver();
        failing.timerStarted(
          sessionId: 's1',
          timerId: 't1',
          label: 'Rest',
          seconds: 60,
        );
        await deliver();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
      expect(calls, 2);
    },
  );
}
