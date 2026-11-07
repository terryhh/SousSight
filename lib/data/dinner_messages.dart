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
  if (idToken == null || appCheck == null)
    throw StateError('Sign-in required.');
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
  if (response.statusCode != 200)
    throw StateError('Message request unavailable (${response.statusCode}).');
  final json = jsonDecode(response.body) as Map<String, dynamic>;
  return DinnerMessageResult(
    json['status'] as String,
    json['channel'] as String? ?? 'Vonage',
  );
}
