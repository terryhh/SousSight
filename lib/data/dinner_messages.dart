import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

/// Household lifecycle messages. Text is composed by the server from fixed
/// templates; the client only supplies validated slots.
enum DinnerKind { started, ready }

/// Mirrors `cleanTemplateText` in functions/src/dinner-ready.js. The server is
/// authoritative; this only keeps the preview faithful.
String cleanTemplateText(String value, int maxLength) {
  var text = value
      .replaceAll(RegExp(r"[^\p{L}\p{N} '&,()!-]", unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.length > maxLength) text = text.substring(0, maxLength).trim();
  return text;
}

/// Mirrors `composeDinnerMessage` in functions/src/dinner-ready.js.
String composeDinnerMessage({
  required DinnerKind kind,
  required String recipeTitle,
  int? minutes,
  String? cookName,
}) {
  final title = cleanTemplateText(recipeTitle, 60);
  if (kind == DinnerKind.started) {
    final name = cleanTemplateText(cookName ?? '', 30);
    return 'SousSight: ${name.isEmpty ? 'Your cook' : name} started $title. '
        'Dinner in about $minutes min.';
  }
  return 'SousSight: Dinner is ready! $title is on the table.';
}

class DinnerMessageRequest {
  const DinnerMessageRequest({
    required this.sessionId,
    required this.notificationId,
    required this.recipient,
    required this.kind,
    required this.recipeTitle,
    this.minutes,
    this.cookName,
    this.simulateFailure = false,
  });
  final String sessionId;
  final String notificationId;
  final String recipient;
  final DinnerKind kind;
  final String recipeTitle;
  final int? minutes;
  final String? cookName;

  /// Demo only: the server skips Vonage and records a simulated rejection.
  final bool simulateFailure;

  String get preview => composeDinnerMessage(
    kind: kind,
    recipeTitle: recipeTitle,
    minutes: minutes,
    cookName: cookName,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'notificationId': notificationId,
    'recipient': recipient,
    'kind': kind.name,
    'recipeTitle': recipeTitle,
    if (kind == DinnerKind.started) 'minutes': minutes,
    if (kind == DinnerKind.started && (cookName?.trim().isNotEmpty ?? false))
      'cookName': cookName!.trim(),
    if (simulateFailure) 'simulateFailure': true,
  };
}

class DinnerMessageResult {
  const DinnerMessageResult(
    this.status,
    this.channel, {
    this.message,
    this.deliveryStatus,
    this.simulated = false,
  });
  final String status;
  final String channel;

  /// Exact text the server composed (null for older/fake responses).
  final String? message;
  final String? deliveryStatus;
  final bool simulated;
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

/// A known rejection that occurs before the backend claims a send, so the
/// cook may correct the input and confirm again with the same ID.
class DinnerValidationException implements Exception {
  const DinnerValidationException(this.explanation);
  final String explanation;
}

/// A 409: an attempt already exists. Never unlocks a same-ID retry.
class DinnerConflictException implements Exception {
  const DinnerConflictException(this.explanation);
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
    final conflict = switch ((response.statusCode, code)) {
      (409, 'idempotency-conflict') => 'This message ID was already used for different content. Start a new message instead.',
      (409, 'meal-already-notified') => 'A message of this kind already exists for this meal. Check its status instead of sending again.',
      _ => null,
    };
    if (conflict != null) throw DinnerConflictException(conflict);
    final explanation = switch ((response.statusCode, code)) {
      (400, 'invalid-recipient') =>
        'Use a phone number with its country code. No message was sent.',
      (400, 'invalid-request') =>
        'Review the recipient, recipe and minutes. No message was sent.',
      (403, 'recipient-not-allowed') => 'Choose your configured household contact. This recipient is not enabled. No message was sent.',
      (403, 'simulation-disabled') =>
        'Failure simulation is turned off on this server. No message was sent.',
      (429, 'rate-limited') =>
        'Too many household messages this hour. No message was sent.',
      (503, 'not-configured') =>
        'Household messaging is not configured yet. No message was sent.',
      _ => null,
    };
    if (explanation != null) throw DinnerValidationException(explanation);
    throw StateError('Message request unavailable (${response.statusCode}).');
  }
  final json = jsonDecode(response.body) as Map<String, dynamic>;
  return DinnerMessageResult(
    json['status'] as String,
    json['channel'] as String? ?? 'Vonage',
    message: json['message'] as String?,
    deliveryStatus: json['deliveryStatus'] as String?,
    simulated: json['simulated'] == true,
  );
}

typedef DinnerMessageSender = Future<DinnerMessageResult> Function(
  DinnerMessageRequest request,
);

Future<DinnerMessageResult> sendDinnerMessage(
  DinnerMessageRequest request,
) async {
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
        body: jsonEncode(request.toJson()),
      )
      .timeout(const Duration(seconds: 25));
  return parseDinnerMessageResponse(response);
}
