import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class DinnerMessageResult {
  const DinnerMessageResult(this.status, this.channel);
  final String status;
  final String channel;
  String get explanation => switch (status) {
    'submitted' =>
      'Vonage accepted the message. Delivery is not yet confirmed.',
    'skipped' => 'Rehearsal only: no message was sent.',
    'unknown' =>
      'The delivery state is uncertain. We will not resend automatically.',
    _ =>
      'The message was not accepted. Check the configured contact and channel.',
  };
}

/// A known validation rejection that occurs before the backend claims a send.
class DinnerValidationException implements Exception {
  const DinnerValidationException(this.explanation);
  final String explanation;
}

DinnerMessageResult parseDinnerMessageResponse(http.Response response) {
  if (response.statusCode != 200) {
    // Match both status and code. Unknown/malformed responses remain ambiguous;
    // never expose arbitrary server text or unlock retries after a claimed send.
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      // Keep the conservative unavailable result below.
    }
    final error = body is Map ? body['error'] : null;
    final code = error is Map ? error['code'] : null;
    final explanation = switch ((response.statusCode, code)) {
      (400, 'invalid-recipient') =>
        'Use a phone number with its country code. No message was sent.',
      (400, 'invalid-request') => 'Review the recipient and message (up to 320 characters). No message was sent.',
      (403, 'recipient-not-allowed') => 'Choose your configured household contact. This recipient is not enabled. No message was sent.',
      _ => null,
    };
    if (explanation != null) throw DinnerValidationException(explanation);
    throw StateError('Message request unavailable (${response.statusCode}).');
  }
  final json = jsonDecode(response.body) as Map<String, dynamic>;
  return DinnerMessageResult(
    json['status'] as String,
    json['channel'] as String? ?? 'Vonage',
  );
}

Future<DinnerMessageResult> sendDinnerMessage({
  required String sessionId,
  required String notificationId,
  required String recipient,
  required String message,
  bool demo = false,
}) async {
  if (demo) return const DinnerMessageResult('skipped', 'demo');
  const configured = String.fromEnvironment('DINNER_MESSAGE_URL');
  final endpoint = configured.isEmpty
      ? Uri.base.resolve('/api/dinner-ready')
      : Uri.parse(configured);
  final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
  final appCheck = await FirebaseAppCheck.instance.getToken();
  if (idToken == null || appCheck == null) {
    throw StateError('Sign-in required.');
  }
  final response = await http
      .post(
        endpoint,
        headers: {
          'Authorization': 'Bearer $idToken',
          'X-Firebase-AppCheck': appCheck,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'sessionId': sessionId,
          'notificationId': notificationId,
          'recipient': recipient,
          'message': message,
        }),
      )
      .timeout(const Duration(seconds: 25));
  return parseDinnerMessageResponse(response);
}
