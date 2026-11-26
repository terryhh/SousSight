import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/data/dinner_messages.dart';
import 'package:soussight/data/dinner_mode.dart';
import 'package:soussight/data/dinner_status.dart';
import 'package:soussight/learner/dinner_review.dart';

void main() {
  late FakeDinnerBackend fake;
  late DinnerAttemptMemory memory;

  Finder recipientField() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == 'Recipient',
  );
  Finder minutesField() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == 'Minutes until dinner',
  );
  String statusText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('dinner-status'))).data!;

  Future<void> pumpDialog(
    WidgetTester tester, {
    required DinnerMode mode,
    required DinnerKind kind,
    DinnerMessageSender? send,
  }) async {
    fake = FakeDinnerBackend();
    memory = DinnerAttemptMemory();
    addTearDown(fake.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DinnerReviewDialog(
            kind: kind,
            sessionId: 'session-1',
            recipeTitle: 'Chickpea wrap',
            send:
                send ??
                dinnerSenderFor(
                  mode,
                  isDemo: false,
                  fake: fake,
                  real: (_) => fail('real endpoint must not be called'),
                ),
            statusSource: dinnerStatusFor(
              mode,
              isDemo: false,
              fake: fake,
              real: () => fake,
            ),
            memory: memory,
            isDemo: false,
            mode: mode,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('simulated mode', () {
    testWidgets(
      'shows the fictional recipient, no phone field, and completes the '
      'cook-confirmed review with a labelled delivery',
      (tester) async {
        await pumpDialog(
          tester,
          mode: DinnerMode.simulated,
          kind: DinnerKind.ready,
        );
        expect(recipientField(), findsNothing);
        expect(
          find.text('Recipient: Demo household (fictional)'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('dinner-simulated-notice')))
              .data,
          startsWith(simulatedLabel),
        );
        // The redundant demo button is gone; the failure demo stays.
        expect(find.text('Simulate delivery (demo)'), findsNothing);
        expect(find.text('Simulate failed delivery (demo)'), findsOneWidget);
        expect(
          find.text(
            'SousSight: Dinner is ready! Chickpea wrap is on the table.',
          ),
          findsOneWidget,
        );
        // Nothing is sent before the cook confirms.
        expect(fake.sent, isEmpty);

        await tester.tap(
          find.widgetWithText(FilledButton, 'Confirm simulated send'),
        );
        await tester.pumpAndSettle();

        final sent = fake.sent.single;
        expect(sent.recipient, simulatedDinnerRecipient);
        expect(sent.simulate, DinnerSimulation.delivered);
        expect(statusText(tester), '$simulatedLabel Delivered ✓');
        expect(memory.lastRecipient, isEmpty);
        // Claimed: no second send is offered.
        expect(find.text('Simulate failed delivery (demo)'), findsNothing);
        final confirm = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Confirm simulated send'),
        );
        expect(confirm.onPressed, isNull);
      },
    );

    testWidgets('a submitted status before delivery is labelled too', (
      tester,
    ) async {
      await pumpDialog(
        tester,
        mode: DinnerMode.simulated,
        kind: DinnerKind.ready,
        send: (request) async {
          fake.sent.add(request);
          return const DinnerMessageResult(
            'submitted',
            'demo',
            simulated: true,
          );
        },
      );
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirm simulated send'),
      );
      await tester.pumpAndSettle();
      expect(
        statusText(tester),
        '$simulatedLabel Sent to Vonage. Waiting for a delivery report.',
      );
      fake.emit(
        'session-1',
        fake.sent.single.notificationId,
        const DinnerDeliveryStatus(status: 'delivered', simulated: true),
      );
      await tester.pumpAndSettle();
      expect(statusText(tester), '$simulatedLabel Delivered ✓');
    });

    testWidgets('started message checks minutes but never a phone number', (
      tester,
    ) async {
      await pumpDialog(
        tester,
        mode: DinnerMode.simulated,
        kind: DinnerKind.started,
      );
      expect(recipientField(), findsNothing);
      await tester.enterText(minutesField(), '0');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirm simulated send'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Enter 1–120 minutes.'), findsOneWidget);
      expect(fake.sent, isEmpty);

      await tester.enterText(minutesField(), '25');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirm simulated send'),
      );
      await tester.pumpAndSettle();
      expect(fake.sent.single.minutes, 25);
      expect(fake.sent.single.recipient, simulatedDinnerRecipient);
      expect(statusText(tester), '$simulatedLabel Delivered ✓');
    });

    testWidgets('simulated failure is labelled and offers a new message', (
      tester,
    ) async {
      await pumpDialog(
        tester,
        mode: DinnerMode.simulated,
        kind: DinnerKind.ready,
      );
      await tester.tap(find.text('Simulate failed delivery (demo)'));
      await tester.pumpAndSettle();
      expect(statusText(tester), startsWith('$simulatedLabel Not delivered'));
      expect(find.text('Edit and send as new message'), findsOneWidget);
    });
  });

  group('real mode', () {
    testWidgets('still requires a phone number before sending', (tester) async {
      final calls = <DinnerMessageRequest>[];
      await pumpDialog(
        tester,
        mode: DinnerMode.real,
        kind: DinnerKind.ready,
        send: (request) async {
          calls.add(request);
          return const DinnerMessageResult('submitted', 'sms');
        },
      );
      expect(recipientField(), findsOneWidget);
      expect(find.text('Recipient: Demo household (fictional)'), findsNothing);
      expect(find.text('Simulate delivery (demo)'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Confirm and send'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a full international phone number.'), findsOne);
      expect(calls, isEmpty);

      await tester.enterText(recipientField(), '+14075550123');
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm and send'));
      await tester.pumpAndSettle();
      expect(calls.single.recipient, '+14075550123');
      expect(calls.single.simulate, isNull);
      expect(memory.lastRecipient, '+14075550123');
      expect(statusText(tester), isNot(startsWith(simulatedLabel)));
    });

    testWidgets('defaults to real when no mode is passed', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DinnerReviewDialog(
              kind: DinnerKind.ready,
              sessionId: 's',
              recipeTitle: 'Chickpea wrap',
              send: (_) => fail('no send expected'),
              statusSource: FakeDinnerBackend(),
              memory: DinnerAttemptMemory(),
              isDemo: false,
            ),
          ),
        ),
      );
      expect(recipientField(), findsOneWidget);
    });
  });
}
