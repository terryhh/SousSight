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
      "SousSight: Dinner's started, about 25 minutes to go. "
      'Your cook is making Chickpea wraps.',
    );
    expect(
      composeDinnerMessage(
        kind: DinnerKind.started,
        recipeTitle: 'Chickpea wraps',
      ),
      "SousSight: Dinner's started. Your cook is making Chickpea wraps.",
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

  test(
    'the fixed template text is GSM-7 only; ASCII slots fit one segment',
    () {
      // The GSM 03.38 basic character set (no extension table, no em dash or
      // curly quotes, which would force UCS-2 and 70-character segments).
      const gsm7 =
          '@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?'
          '¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
      final messages = [
        composeDinnerMessage(kind: DinnerKind.ready, recipeTitle: 'Soup'),
        for (final minutes in [null, 1, 25, 120])
          for (final cookName in [null, 'Terry'])
            composeDinnerMessage(
              kind: DinnerKind.started,
              recipeTitle: 'Chickpea wraps',
              minutes: minutes,
              cookName: cookName,
            ),
      ];
      for (final message in messages) {
        final outside = message.runes
            .map(String.fromCharCode)
            .where((c) => !gsm7.contains(c))
            .toList();
        expect(outside, isEmpty, reason: message);
        expect(message.length, lessThanOrEqualTo(160), reason: message);
      }
    },
  );

  test('Unicode names and titles pass through; only fixed text is GSM-7', () {
    // Same fixture as functions/test/dinner-ready.test.js.
    const gsm7 =
        '@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?'
        '¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
    List<String> outside(String text) => text.runes
        .map(String.fromCharCode)
        .where((c) => !gsm7.contains(c))
        .toList();
    final cookName = '豆腐' * 15;
    final message = composeDinnerMessage(
      kind: DinnerKind.started,
      recipeTitle: '豆腐汤',
      minutes: 120,
      cookName: cookName,
    );
    expect(
      message,
      "SousSight: Dinner's started, about 120 minutes to go. "
      '$cookName is making 豆腐汤.',
    );
    final fixed = message.replaceFirst(cookName, '').replaceFirst('豆腐汤', '');
    expect(outside(fixed), isEmpty);
    // A Unicode slot makes the SMS UCS-2 (70 characters a segment): the
    // one-segment claim covers only the fixed text and ASCII slots.
    expect(outside(message), isNotEmpty);
    expect(message.length, greaterThan(70));
  });

  test('a started request without an estimate leaves minutes out', () {
    const request = DinnerMessageRequest(
      sessionId: 's',
      notificationId: 'notice-123',
      recipient: '+14075550100',
      kind: DinnerKind.started,
      recipeTitle: 'Soup',
    );
    expect(request.toJson().containsKey('minutes'), isFalse);
    expect(
      request.preview,
      "SousSight: Dinner's started. Your cook is making Soup.",
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
      startsWith('Simulated — no SMS sent. Not delivered'),
    );
    expect(
      label('delivered', simulated: true),
      'Simulated — no SMS sent. Delivered ✓',
    );
    expect(
      DinnerDeliveryStatus.fromMap({'status': 'undeliverable'}).isFailure,
      isTrue,
    );
  });
}
