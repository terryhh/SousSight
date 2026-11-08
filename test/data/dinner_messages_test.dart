import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:soussight/data/dinner_messages.dart';
import 'package:soussight/data/dinner_status.dart';

void main() {
  http.Response rejection(int status, String code) => http.Response(
    jsonEncode({
      'error': {'code': code, 'message': 'Untrusted server detail'},
    }),
    status,
  );

  for (final entry in [
    (400, 'invalid-recipient'),
    (400, 'invalid-request'),
    (403, 'recipient-not-allowed'),
    (403, 'simulation-disabled'),
    (429, 'rate-limited'),
    (503, 'not-configured'),
  ]) {
    test('${entry.$2} permits explicit correction without server text', () {
      expect(
        () => parseDinnerMessageResponse(rejection(entry.$1, entry.$2)),
        throwsA(
          isA<DinnerValidationException>().having(
            (error) => error.explanation,
            'safe explanation',
            allOf(
              contains('No message was sent.'),
              isNot(contains('Untrusted')),
            ),
          ),
        ),
      );
    });
  }

  for (final code in ['idempotency-conflict', 'meal-already-notified']) {
    test('409/$code has its own message and never unlocks correction', () {
      expect(
        () => parseDinnerMessageResponse(rejection(409, code)),
        throwsA(
          isA<DinnerConflictException>().having(
            (error) => error.explanation,
            'explanation',
            isNot(contains('Untrusted')),
          ),
        ),
      );
    });
  }

  for (final entry in [
    (403, 'session-not-owned'),
    (500, 'invalid-request'),
    (400, 'unknown'),
    (409, 'other'),
  ]) {
    test('${entry.$1}/${entry.$2} stays ambiguous', () {
      expect(
        () => parseDinnerMessageResponse(rejection(entry.$1, entry.$2)),
        throwsStateError,
      );
    });
  }

  test('malformed rejection stays ambiguous', () {
    for (final body in ['not JSON', '[]', '{"error":"invalid-request"}']) {
      expect(
        () => parseDinnerMessageResponse(http.Response(body, 400)),
        throwsStateError,
      );
    }
  });

  test('accepted results retain status, server text and simulation flag', () {
    for (final status in ['submitted', 'unknown', 'skipped', 'failed']) {
      expect(
        parseDinnerMessageResponse(
          http.Response(jsonEncode({'status': status, 'channel': 'sms'}), 200),
        ).status,
        status,
      );
    }
    final simulated = parseDinnerMessageResponse(
      http.Response(
        jsonEncode({
          'status': 'submitted',
          'channel': 'sms',
          'message': 'SousSight: Dinner is ready! Soup is on the table.',
          'deliveryStatus': 'rejected',
          'simulated': true,
        }),
        200,
      ),
    );
    expect(simulated.simulated, isTrue);
    expect(simulated.deliveryStatus, 'rejected');
  });

  // Same fixtures as functions/test/dinner-ready.test.js.
  test('preview templates match the server templates', () {
    expect(
      composeDinnerMessage(
        kind: DinnerKind.ready,
        recipeTitle: 'Chickpea wraps',
      ),
      'SousSight: Dinner is ready! Chickpea wraps is on the table.',
    );
    expect(
      composeDinnerMessage(
        kind: DinnerKind.started,
        recipeTitle: 'Chickpea wraps',
        minutes: 25,
      ),
      'SousSight: Your cook started Chickpea wraps. Dinner in about 25 min.',
    );
    expect(
      cleanTemplateText(' <b>Pad\u0007 Thai</b> http://x.co/y ', 60),
      'b Pad Thai b http x co y',
    );
    expect(
      cleanTemplateText('Mac & cheese!\nvisit evil.example', 60),
      'Mac & cheese! visit evil example',
    );
  });

  test('request JSON carries slots only, never free-form text', () {
    const request = DinnerMessageRequest(
      sessionId: 's',
      notificationId: 'notice-123',
      recipient: '+14075550100',
      kind: DinnerKind.ready,
      recipeTitle: 'Soup',
      minutes: 9,
    );
    expect(request.toJson(), {
      'sessionId': 's',
      'notificationId': 'notice-123',
      'recipient': '+14075550100',
      'kind': 'ready',
      'recipeTitle': 'Soup',
    });
  });

  test('status labels cover delivery states and simulated failures', () {
    String label(String status, {bool simulated = false}) =>
        DinnerDeliveryStatus(
          status: status,
          errorTitle: 'Illegal Sender Address',
          errorCode: '1120',
          simulated: simulated,
        ).label;
    expect(label('submitted'), contains('Sent to Vonage'));
    expect(label('delivered'), 'Delivered ✓');
    expect(label('read'), 'Read');
    expect(
      label('rejected'),
      'Not delivered: Illegal Sender Address (error 1120)',
    );
    expect(
      label('rejected', simulated: true),
      startsWith('Simulated failure (demo).'),
    );
    expect(
      DinnerDeliveryStatus.fromMap({'status': 'undeliverable'}).isFailure,
      isTrue,
    );
  });
}
