import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../live/ephemeral_live_transport.dart';

/// The HTTP POST used by [fetchLiveToken]; [http.post] in production.
typedef LiveTokenPost = Future<http.Response> Function(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
});

/// Only a one-use, short-lived token crosses this boundary. The Gemini API key
/// stays in Cloud Secret Manager and is never included in a web build.
///
/// [auth], [appCheck] and [post] are test seams; production passes none of
/// them and uses the Firebase singletons and [http.post].
Future<LiveEphemeralToken> fetchLiveToken({
  @visibleForTesting FirebaseAuth? auth,
  @visibleForTesting FirebaseAppCheck? appCheck,
  @visibleForTesting LiveTokenPost? post,
}) async {
  const configured = String.fromEnvironment('LIVE_TOKEN_URL');
  final endpoint = configured.isEmpty
      ? Uri.base.resolve('/api/live-token')
      : Uri.parse(configured);
  final idToken = await (auth ?? FirebaseAuth.instance).currentUser
      ?.getIdToken();
  final appCheckToken = await (appCheck ?? FirebaseAppCheck.instance)
      .getToken();
  if (idToken == null || appCheckToken == null || appCheckToken.isEmpty) {
    throw StateError('Sign in and configure App Check before starting Live.');
  }
  final response = await (post ?? http.post)(
    endpoint,
    headers: {
      'Authorization': 'Bearer $idToken',
      'X-Firebase-AppCheck': appCheckToken,
      'Content-Type': 'application/json',
    },
    body: '{}',
  ).timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    // Do not surface service response bodies that could contain credentials.
    throw StateError('Live access is unavailable (${response.statusCode}).');
  }
  return LiveEphemeralToken.fromJson(
    jsonDecode(response.body) as Map<String, dynamic>,
  );
}
