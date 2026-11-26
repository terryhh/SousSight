// sendDinnerMessage with faked Auth, App Check and HTTP: proves what the app
// sends to its own /api/dinner-ready endpoint. Vonage is never contacted;
// the server side is covered by functions/test.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:soussight/data/dinner_messages.dart';

import 'firebase_token_fakes.dart';

void main() {
  const started = DinnerMessageRequest(
    sessionId: 'session-1',
    notificationId: 'notice-1',
    recipient: '+14075550100',
    kind: DinnerKind.started,
    recipeTitle: 'Chickpea wraps',
    minutes: 25,
    cookName: '  Sam  ',
    simulate: DinnerSimulation.delivered,
  );

  test('posts slots with both tokens and parses the accepted result', () async {
    final post = RecordingPost(
      () async => http.Response(
        jsonEncode({
          'status': 'submitted',
          'message': started.preview,
          'simulated': true,
        }),
        200,
      ),
    );

    final result = await sendDinnerMessage(
      started,
      auth: FakeTokenAuth.signedIn('id-token'),
      appCheck: FakeAppCheck('app-check'),
      post: post.call,
    );

    expect(post.urls.single.path, '/api/dinner-ready');
    expect(post.headers.single, {
      'Authorization': 'Bearer id-token',
      'X-Firebase-AppCheck': 'app-check',
      'Content-Type': 'application/json',
    });
    expect(jsonDecode(post.bodies.single! as String), {
      'sessionId': 'session-1',
      'notificationId': 'notice-1',
      'recipient': '+14075550100',
      'kind': 'started',
      'recipeTitle': 'Chickpea wraps',
      'minutes': 25,
      'cookName': 'Sam',
      'simulateOutcome': 'delivered',
    });
    expect(result.status, 'submitted');
    expect(result.channel, 'Vonage', reason: 'missing channel defaults');
    expect(result.simulated, isTrue);
    expect(
      result.message,
      'SousSight: Sam started Chickpea wraps. Dinner in about 25 min.',
    );
  });

  for (final (label, auth, appCheck) in [
    ('signed out', FakeTokenAuth(), FakeAppCheck('ac')),
    ('no ID token', FakeTokenAuth(FakeIdUser(null)), FakeAppCheck('ac')),
    ('no App Check token', FakeTokenAuth.signedIn('id'), FakeAppCheck(null)),
  ]) {
    test('$label: nothing is sent', () async {
      final post = RecordingPost(() async => http.Response('{}', 200));
      await expectLater(
        sendDinnerMessage(
          started,
          auth: auth,
          appCheck: appCheck,
          post: post.call,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Sign-in required.',
          ),
        ),
      );
      expect(post.urls, isEmpty);
    });
  }

  test('a server rejection flows through the safe parser', () async {
    final post = RecordingPost(
      () async => http.Response(
        jsonEncode({
          'error': {'code': 'rate-limited', 'message': 'raw detail'},
        }),
        429,
      ),
    );
    await expectLater(
      sendDinnerMessage(
        started,
        auth: FakeTokenAuth.signedIn('id'),
        appCheck: FakeAppCheck('ac'),
        post: post.call,
      ),
      throwsA(isA<DinnerValidationException>()),
    );
  });

  test('a hung request times out after 25 seconds, so the cook is not left '
      'waiting', () {
    fakeAsync((async) {
      Object? failure;
      sendDinnerMessage(
        started,
        auth: FakeTokenAuth.signedIn('id'),
        appCheck: FakeAppCheck('ac'),
        post: RecordingPost(() => Completer<http.Response>().future).call,
      ).then<void>((_) {}, onError: (Object e) => failure = e);
      async.elapse(const Duration(seconds: 24));
      expect(failure, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(failure, isA<TimeoutException>());
    });
  });

  test('a ready message omits minutes, cook name and simulation', () {
    const ready = DinnerMessageRequest(
      sessionId: 's',
      notificationId: 'n',
      recipient: '+14075550100',
      kind: DinnerKind.ready,
      recipeTitle: 'Soup',
      minutes: 9,
      cookName: 'Sam',
    );
    expect(ready.toJson().keys, isNot(contains('minutes')));
    expect(ready.toJson().keys, isNot(contains('cookName')));
    expect(ready.toJson().keys, isNot(contains('simulateOutcome')));
    expect(ready.preview, 'SousSight: Dinner is ready! Soup is on the table.');
  });

  test('a blank cook name is neither sent nor previewed', () {
    const blank = DinnerMessageRequest(
      sessionId: 's',
      notificationId: 'n',
      recipient: '+1',
      kind: DinnerKind.started,
      recipeTitle: 'Soup',
      minutes: 5,
      cookName: '   ',
    );
    expect(blank.toJson().keys, isNot(contains('cookName')));
    expect(blank.preview, startsWith('SousSight: Your cook started Soup.'));
  });

  test('result explanations never claim delivery that was not confirmed', () {
    String explain(String status) =>
        DinnerMessageResult(status, 'sms').explanation;
    expect(explain('submitted'), contains('Delivery is not yet confirmed'));
    expect(explain('skipped'), contains('no message was sent'));
    expect(explain('unknown'), contains('will not resend automatically'));
    expect(explain('failed'), contains('not accepted'));
    expect(explain('anything-else'), contains('not accepted'));
  });
}
