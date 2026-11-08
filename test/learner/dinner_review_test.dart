import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/cooking_research_client.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/data/dinner_messages.dart';
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
  late List<Map<String, Object?>> submissions;
  late Completer<DinnerMessageResult> response;

  Future<void> openDraft(WidgetTester tester) async {
    final services = (await tester.runAsync(fakeServices))!;
    transport = _DraftTransport();
    submissions = [];
    response = Completer<DinnerMessageResult>();
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
          sendDinner:
              ({
                required sessionId,
                required notificationId,
                required recipient,
                required message,
                demo = false,
              }) {
                submissions.add({
                  'sessionId': sessionId,
                  'notificationId': notificationId,
                  'recipient': recipient,
                  'message': message,
                  'demo': demo,
                });
                return response.future;
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
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
    final review = find.text('Review dinner message');
    await tester.ensureVisible(review);
    await tester.pumpAndSettle();
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  Finder field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );
  Finder getConfirm() => find.widgetWithText(FilledButton, 'Rehearse send');

  Future<void> fillReview(WidgetTester tester) async {
    await tester.enterText(field('Recipient'), '+14075550123');
    await tester.enterText(
      field('Message'),
      'The edited wraps are on the table.',
    );
  }

  testWidgets('model draft and cancelling review never submit', (tester) async {
    await openDraft(tester);
    expect(
      tester.widget<TextField>(field('Message')).controller!.text,
      'Model draft: wraps are ready.',
    );
    expect(submissions, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    expect(submissions, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('explicit review submits the exact edited payload once', (
    tester,
  ) async {
    await openDraft(tester);
    await fillReview(tester);
    expect(submissions, isEmpty);
    await tester.tap(getConfirm());
    await tester.pump();
    expect(submissions, hasLength(1));
    expect(submissions.single, {
      'sessionId': cook.session!.id,
      'notificationId': isNotEmpty,
      'recipient': '+14075550123',
      'message': 'The edited wraps are on the table.',
      'demo': true,
    });
    expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
    response.complete(const DinnerMessageResult('submitted', 'whatsapp'));
    await tester.pumpAndSettle();
    expect(
      find.text('Vonage accepted the message. Delivery is not yet confirmed.'),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
    expect(submissions, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('duplicate confirmation before rebuild cannot send twice', (
    tester,
  ) async {
    await openDraft(tester);
    await fillReview(tester);
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

  testWidgets(
    'pre-send rejection permits correction only after another review tap',
    (tester) async {
      await openDraft(tester);
      await fillReview(tester);
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
      expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNotNull);
      expect(submissions, hasLength(1));
      response = Completer<DinnerMessageResult>();
      await tester.enterText(field('Recipient'), '+14075550124');
      await tester.pump();
      expect(submissions, hasLength(1));
      await tester.tap(getConfirm());
      await tester.pump();
      expect(submissions, hasLength(2));
      expect(submissions.last['recipient'], '+14075550124');
      expect(
        submissions.last['notificationId'],
        submissions.first['notificationId'],
      );
      response.complete(const DinnerMessageResult('submitted', 'sms'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(getConfirm()).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final timeout in [false, true]) {
    testWidgets(
      '${timeout ? 'timeout' : 'unknown result'} never retries automatically',
      (tester) async {
        await openDraft(tester);
        await fillReview(tester);
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
}
