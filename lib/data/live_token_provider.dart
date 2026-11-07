import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../live/ephemeral_live_transport.dart';

/// Only a one-use, short-lived token crosses this boundary. The Gemini API key
/// stays in Cloud Secret Manager and is never included in a web build.
Future<LiveEphemeralToken> fetchLiveToken() async {
  const configured = String.fromEnvironment('LIVE_TOKEN_URL');
  final endpoint = configured.isEmpty
      ? Uri.base.resolve('/api/live-token')
      : Uri.parse(configured);
  final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
  final appCheck = await FirebaseAppCheck.instance.getToken();
  if (idToken == null || appCheck == null || appCheck.isEmpty) {
    throw StateError('Sign in and configure App Check before starting Live.');
  }
  final response = await http
      .post(
        endpoint,
        headers: {
          'Authorization': 'Bearer $idToken',
          'X-Firebase-AppCheck': appCheck,
          'Content-Type': 'application/json',
        },
        body: '{}',
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    // Do not surface service response bodies that could contain credentials.
    throw StateError('Live access is unavailable (${response.statusCode}).');
  }
  return LiveEphemeralToken.fromJson(
    jsonDecode(response.body) as Map<String, dynamic>,
  );
}
