import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/data/dinner_messages.dart';
import 'package:soussight/data/dinner_status.dart';
import 'package:soussight/learner/cooking_app.dart';
import 'package:soussight/learner/cooking_coordinator.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/live/live_types.dart';

class _DraftTransport extends DemoLiveTransport {
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
  late _DraftTransport transport;
  late CookingCoordinator cook;
  late List<DinnerMessageRequest> submissions;
  late Completer<DinnerMessageResult> response;
  late FakeDinnerBackend status;

  String readyText() =>
      'SousSight: Dinner is ready! ${cook.recipe.title} is on the table.';

  Future<void> pumpScreen(WidgetTester tester) async {
    final services = (await tester.runAsync(fakeServices))!;
    transport = _DraftTransport();
    submissions = [];
    response = Completer<DinnerMessageResult>();
    status = FakeDinnerBackend();
    cook = CookingCoordinator(
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
          dinnerStatus: status,
          sendDinner: (request) {
            submissions.add(request);
            return response.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String label) async {
    final button = find.text(label).evaluate().isEmpty
        ? find.byTooltip(label)
        : find.text(label);
    await tester.ensureVisible(button.first);
    await tester.pumpAndSettle();
    await tester.tap(button.first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  Future<void> openDraft(WidgetTester tester) async {
    await pumpScreen(tester);
    await cook.connect();
    transport.source.add(
      const LiveToolCall(
        id: 'draft-dinner',
        name: 'dinner_ready',
        arguments: {'message': 'Model draft: wraps are ready.'},
      ),
    );
    await tester.pumpAndSettle();
    expect(cook.dinnerDraft, 'Model draft: wraps are ready.');
    expect(submissions, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    await open(tester, 'Review dinner message');
  }

  Finder field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );
  Finder getConfirm() => find.widgetWithText(FilledButton, 'Rehearse send');
  Finder simulate() =>
      find.widgetWithText(OutlinedButton, 'Simulate failed delivery (demo)');
  Finder simulateDelivery() =>
      find.widgetWithText(OutlinedButton, 'Simulate delivery (demo)');
  String statusText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('dinner-status'))).data!;

  Future<void> emit(WidgetTester tester, DinnerDeliveryStatus value) async {
    status.emit(cook.session!.id, submissions.last.notificationId, value);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'model draft never submits and the preview is the server template',
    (tester) async {
      await openDraft(tester);
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text(readyText())),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Model draft: wraps are ready.'),
        ),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(submissions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('confirmed send shows live Vonage status without resending', (
    tester,
  ) async {
    await openDraft(tester);
    await tester.enterText(field('Recipient'), '+14075550123');
    await tester.tap(getConfirm());
    await tester.pump();
    expect(submissions, hasLength(1));
    final sent = submissions.single;
    expect(sent.sessionId, cook.session!.id);
    expect(sent.kind, DinnerKind.ready);
    expect(sent.recipeTitle, cook.recipe.title);
    expect(sent.simulate, isNull);
    expect(sent.toJson().containsKey('simulateOutcome'), isFalse);
    expect(sent.toJson().containsKey('message'), isFalse);
    expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
    response.complete(
      DinnerMessageResult('submitted', 'sms', message: readyText()),
    );
    await tester.pumpAndSettle();
    expect(statusText(tester), contains('Sent to Vonage'));
    for (final (value, expected) in [
      ('delivered', 'Delivered ✓'),
      ('read', 'Read'),
    ]) {
      await emit(tester, DinnerDeliveryStatus(status: value));
      expect(statusText(tester), expected);
    }
    expect(find.text('Edit and send as new message'), findsNothing);
    expect(submissions, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('duplicate confirmation before rebuild cannot send twice', (
    tester,
  ) async {
    await openDraft(tester);
    await tester.enterText(field('Recipient'), '+14075550123');
    final confirm = tester.widget<FilledButton>(getConfirm()).onPressed!;
    confirm();
    confirm();
    await tester.pump();
    expect(submissions, hasLength(1));
    response.complete(const DinnerMessageResult('submitted', 'whatsapp'));
    await tester.pumpAndSettle();
    confirm();
    await tester.pump();
    expect(submissions, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pre-send rejection permits correction with the same ID', (
    tester,
  ) async {
    await openDraft(tester);
    await tester.enterText(field('Recipient'), '+14075550123');
    await tester.tap(getConfirm());
    await tester.pump();
    response.completeError(
      const DinnerValidationException(
        'Choose your configured household contact. No message was sent.',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No message was sent.'), findsOneWidget);
    expect(tester.widget<TextField>(field('Recipient')).enabled, isTrue);
    response = Completer<DinnerMessageResult>();
    await tester.enterText(field('Recipient'), '+14075550124');
    await tester.tap(getConfirm());
    await tester.pump();
    expect(submissions, hasLength(2));
    expect(submissions.last.recipient, '+14075550124');
    expect(submissions.last.notificationId, submissions.first.notificationId);
    response.complete(const DinnerMessageResult('submitted', 'sms'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('delivery failure offers recovery as a NEW notification ID', (
    tester,
  ) async {
    await openDraft(tester);
    await tester.enterText(field('Recipient'), '+14075550123');
    await tester.tap(getConfirm());
    await tester.pump();
    response.complete(const DinnerMessageResult('submitted', 'sms'));
    await tester.pumpAndSettle();
    await emit(
      tester,
      const DinnerDeliveryStatus(
        status: 'undeliverable',
        errorTitle: 'Unreachable',
        errorCode: '1340',
      ),
    );
    expect(statusText(tester), 'Not delivered: Unreachable (error 1340)');
    await tester.pump(const Duration(minutes: 2));
    expect(submissions, hasLength(1), reason: 'never auto-retry');
    expect(find.text('Copy message'), findsOneWidget);
    await tester.tap(find.text('Edit and send as new message'));
    await tester.pumpAndSettle();
    expect(submissions, hasLength(1), reason: 'recovery needs a new confirm');
    expect(tester.widget<TextField>(field('Recipient')).enabled, isTrue);
    response = Completer<DinnerMessageResult>();
    await tester.enterText(field('Recipient'), '+14075550124');
    await tester.tap(getConfirm());
    await tester.pump();
    expect(submissions, hasLength(2));
    expect(
      submissions.last.notificationId,
      isNot(submissions.first.notificationId),
    );
    expect(submissions.last.recipient, '+14075550124');
    response.complete(const DinnerMessageResult('submitted', 'sms'));
    await tester.pumpAndSettle();
    expect(statusText(tester), contains('Sent to Vonage'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('simulated failure is labelled as a demo and asks the server', (
    tester,
  ) async {
    await openDraft(tester);
    await tester.enterText(field('Recipient'), '+14075550123');
    await tester.tap(simulate());
    await tester.pump();
    expect(submissions.single.simulate, DinnerSimulation.rejected);
    expect(submissions.single.toJson()['simulateOutcome'], 'rejected');
    response.complete(
      const DinnerMessageResult(
        'submitted',
        'sms',
        deliveryStatus: 'rejected',
        simulated: true,
      ),
    );
    await tester.pumpAndSettle();
    await emit(
      tester,
      const DinnerDeliveryStatus(
        status: 'rejected',
        errorTitle: 'Illegal Sender Address',
        errorCode: '1120',
        simulated: true,
      ),
    );
    expect(
      statusText(tester),
      'Simulated — no SMS sent. Not delivered: Illegal Sender Address (error 1120)',
    );
    expect(simulate(), findsNothing);
    expect(simulateDelivery(), findsNothing);
    expect(find.text('Edit and send as new message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('simulated delivery is labelled, never a real send, and locks', (
    tester,
  ) async {
    await openDraft(tester);
    await tester.enterText(field('Recipient'), '+14075550123');
    expect(simulateDelivery(), findsOneWidget);
    expect(simulate(), findsOneWidget);
    await tester.tap(simulateDelivery());
    await tester.pump();
    expect(submissions.single.simulate, DinnerSimulation.delivered);
    expect(submissions.single.toJson()['simulateOutcome'], 'delivered');
    expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
    response.complete(
      const DinnerMessageResult(
        'submitted',
        'sms',
        deliveryStatus: 'delivered',
        simulated: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(statusText(tester), 'Simulated — no SMS sent. Delivered ✓');
    await emit(
      tester,
      const DinnerDeliveryStatus(status: 'submitted', simulated: true),
    );
    expect(statusText(tester), startsWith('Simulated — no SMS sent. Sent to'));
    await emit(
      tester,
      const DinnerDeliveryStatus(status: 'delivered', simulated: true),
    );
    expect(statusText(tester), 'Simulated — no SMS sent. Delivered ✓');
    expect(simulateDelivery(), findsNothing);
    expect(simulate(), findsNothing);
    expect(find.text('Edit and send as new message'), findsNothing);
    expect(submissions, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('started-cooking dialog offers simulated delivery', (
    tester,
  ) async {
    await pumpScreen(tester);
    await open(tester, 'Text household: started cooking');
    await tester.enterText(field('Recipient'), '+14075550123');
    await tester.enterText(field('Minutes until dinner'), '20');
    expect(simulate(), findsOneWidget);
    await tester.tap(simulateDelivery());
    await tester.pump();
    final sent = submissions.single;
    expect(sent.kind, DinnerKind.started);
    expect(sent.toJson(), containsPair('simulateOutcome', 'delivered'));
    response.complete(
      const DinnerMessageResult(
        'submitted',
        'sms',
        deliveryStatus: 'delivered',
        simulated: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(statusText(tester), 'Simulated — no SMS sent. Delivered ✓');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a 409 conflict is shown and keeps the attempt locked', (
    tester,
  ) async {
    await openDraft(tester);
    await tester.enterText(field('Recipient'), '+14075550123');
    await tester.tap(getConfirm());
    await tester.pump();
    response.completeError(
      const DinnerConflictException(
        'A message of this kind already exists for this meal.',
      ),
    );
    await tester.pumpAndSettle();
    expect(statusText(tester), contains('already exists'));
    expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final timeout in [false, true]) {
    testWidgets(
      '${timeout ? 'timeout' : 'unknown result'} never retries automatically',
      (tester) async {
        await openDraft(tester);
        await tester.enterText(field('Recipient'), '+14075550123');
        await tester.tap(getConfirm());
        await tester.pump();
        if (timeout) {
          response.completeError(TimeoutException('Controlled test timeout'));
        } else {
          response.complete(const DinnerMessageResult('unknown', 'whatsapp'));
        }
        await tester.pumpAndSettle();
        await tester.pump(const Duration(minutes: 2));
        expect(submissions, hasLength(1));
        expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
        expect(
          find.textContaining(
            timeout
                ? 'No automatic resend will occur.'
                : 'We will not resend automatically.',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'started-cooking text is opt-in, previewed and keeps its ID on reopen',
    (tester) async {
      await pumpScreen(tester);
      await open(tester, 'Text household: started cooking');
      expect(find.text('Text household: started cooking'), findsWidgets);
      await tester.enterText(field('Recipient'), '+14075550123');
      await tester.enterText(field('Minutes until dinner'), '25');
      await tester.enterText(field('Your name (optional)'), 'Terry');
      await tester.pump();
      expect(
        find.text(
          'SousSight: Terry started ${cook.recipe.title}. Dinner in about 25 min.',
        ),
        findsOneWidget,
      );
      expect(submissions, isEmpty);
      await tester.enterText(field('Minutes until dinner'), '500');
      await tester.tap(getConfirm());
      await tester.pump();
      expect(submissions, isEmpty);
      expect(find.textContaining('1–120 minutes'), findsOneWidget);
      await tester.enterText(field('Minutes until dinner'), '25');
      await tester.tap(getConfirm());
      await tester.pump();
      expect(submissions.single.kind, DinnerKind.started);
      expect(submissions.single.toJson(), containsPair('minutes', 25));
      expect(submissions.single.toJson(), containsPair('cookName', 'Terry'));
      response.complete(const DinnerMessageResult('submitted', 'sms'));
      await tester.pumpAndSettle();
      await emit(tester, const DinnerDeliveryStatus(status: 'delivered'));
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      await open(tester, 'Text household: started cooking');
      expect(statusText(tester), 'Delivered ✓');
      expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
      expect(submissions, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
