import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:soussight/data/dinner_messages.dart';

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

  for (final entry in [
    (409, 'idempotency-conflict'),
    (409, 'meal-already-notified'),
    (403, 'session-not-owned'),
    (500, 'invalid-request'),
    (400, 'unknown'),
  ]) {
    test('${entry.$1}/${entry.$2} never unlocks correction', () {
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

  test('accepted and uncertain results retain their status', () {
    for (final status in ['submitted', 'unknown', 'skipped', 'failed']) {
      expect(
        parseDinnerMessageResponse(
          http.Response(jsonEncode({'status': status, 'channel': 'sms'}), 200),
        ).status,
        status,
      );
    }
  });
}
