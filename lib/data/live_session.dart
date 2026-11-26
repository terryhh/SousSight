// Live session reservation (DESIGN.md §6 SS-074). Before the Firebase AI
// Logic Live socket opens, the client asks the `liveSession` function to admit
// the attempt. The function verifies Firebase Auth and App Check and reserves
// the cook's quota with the server clock. It is called before `connect`, never
// on resume. Nothing secret crosses this boundary: no key, no Live token.

import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../live/live_tools.dart';

/// Absolute reservation endpoint for native builds, which have no Hosting
/// origin. Web builds leave it empty and use `/api/live-session`.
const kLiveSessionUrl = String.fromEnvironment('LIVE_SESSION_URL');

enum LiveSessionDenial {
  /// A per-cook or project-wide limit; [LiveSessionDenied.retryAfter] says when.
  rateLimited,

  /// Auth or App Check was missing or did not verify.
  unverified,

  /// The endpoint or the pinned model is not configured for this build.
  notConfigured,

  /// Network, timeout, server error or a response that did not validate.
  unavailable,
}

sealed class LiveSessionReservation {
  const LiveSessionReservation();
}

class LiveSessionGranted extends LiveSessionReservation {
  const LiveSessionGranted({required this.model});
  final String model;
}

class LiveSessionDenied extends LiveSessionReservation {
  const LiveSessionDenied(this.reason, {this.retryAfter});
  final LiveSessionDenial reason;
  final Duration? retryAfter;

  /// One cook-facing sentence; never a service response body.
  String get message => switch (reason) {
    LiveSessionDenial.rateLimited =>
      'Live coaching is taking a short break'
          '${retryAfter == null ? '' : ' — try again in ${_wait(retryAfter!)}'}. '
          'You can type a question for Coach Lite meanwhile.',
    LiveSessionDenial.unverified =>
      'Live coaching could not verify this app. Reload and try again; '
          'Coach Lite still answers typed questions.',
    LiveSessionDenial.notConfigured =>
      'Live coaching is not set up for this version of the app. '
          'Type a question for Coach Lite instead.',
    LiveSessionDenial.unavailable =>
      'Live coaching is unavailable right now. Try again shortly, or type a '
          'question for Coach Lite.',
  };

  static String _wait(Duration d) {
    final seconds = d.inSeconds;
    if (seconds < 90) return seconds == 1 ? '1 second' : '$seconds seconds';
    final minutes = (seconds / 60).ceil();
    if (minutes < 120) return '$minutes minutes';
    return '${(minutes / 60).ceil()} hours';
  }
}

typedef LiveSessionReserver = Future<LiveSessionReservation> Function();

/// Reads a `liveSession` response. Anything that does not validate is a
/// denial: only `200` with `{ok: true, model: <the pinned model>}` admits.
LiveSessionReservation parseLiveSessionResponse({
  required int statusCode,
  required Map<String, String> headers,
  required String body,
  String expectedModel = kLiveModel,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    decoded = null;
  }
  final json = decoded is Map<String, dynamic> ? decoded : null;
  switch (statusCode) {
    case 200:
      final model = json?['model'];
      if (json?['ok'] != true || model is! String || model.isEmpty) {
        return const LiveSessionDenied(LiveSessionDenial.unavailable);
      }
      // One pinned model (DESIGN.md §7): server and client must agree.
      if (model != expectedModel) {
        return const LiveSessionDenied(LiveSessionDenial.notConfigured);
      }
      return LiveSessionGranted(model: model);
    case 429:
      return LiveSessionDenied(
        LiveSessionDenial.rateLimited,
        retryAfter: _retryAfter(headers, json),
      );
    case 401 || 403:
      return const LiveSessionDenied(LiveSessionDenial.unverified);
    case 503:
      final error = json?['error'];
      return LiveSessionDenied(
        error is Map && error['code'] == 'not-configured'
            ? LiveSessionDenial.notConfigured
            : LiveSessionDenial.unavailable,
      );
    case 404:
      return const LiveSessionDenied(LiveSessionDenial.notConfigured);
    default:
      return const LiveSessionDenied(LiveSessionDenial.unavailable);
  }
}

Duration? _retryAfter(Map<String, String> headers, Map<String, dynamic>? json) {
  int? seconds = int.tryParse(
    (headers['retry-after'] ?? headers['Retry-After'] ?? '').trim(),
  );
  if (seconds == null) {
    final error = json?['error'];
    final value = error is Map ? error['retryAfterSeconds'] : null;
    if (value is int) seconds = value;
  }
  // Ignore nonsense rather than show it to the cook.
  if (seconds == null || seconds < 1 || seconds > 2 * 24 * 60 * 60) return null;
  return Duration(seconds: seconds);
}

/// Where the reservation is sent: [kLiveSessionUrl] when set, otherwise the
/// Hosting rewrite on web. Null on native without a configured URL.
Uri? liveSessionEndpoint({
  String configured = kLiveSessionUrl,
  bool isWeb = kIsWeb,
  Uri? base,
}) {
  if (configured.isNotEmpty) {
    final uri = Uri.tryParse(configured);
    return uri != null && uri.isScheme('https') && uri.hasAuthority
        ? uri
        : null;
  }
  return isWeb ? (base ?? Uri.base).resolve('/api/live-session') : null;
}

/// Reserves one Live session for the signed-in cook. Never throws; failures
/// are [LiveSessionDenied].
Future<LiveSessionReservation> reserveLiveSession({
  http.Client? client,
  Uri? endpoint,
  Future<String?> Function()? idToken,
  Future<String?> Function()? appCheckToken,
  String expectedModel = kLiveModel,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final target = endpoint ?? liveSessionEndpoint();
  if (target == null) {
    return const LiveSessionDenied(LiveSessionDenial.notConfigured);
  }
  final owned = client == null;
  final http.Client httpClient = client ?? http.Client();
  try {
    final id = await (idToken ?? _firebaseIdToken)();
    final attestation = await (appCheckToken ?? _firebaseAppCheckToken)();
    if (id == null ||
        id.isEmpty ||
        attestation == null ||
        attestation.isEmpty) {
      return const LiveSessionDenied(LiveSessionDenial.unverified);
    }
    final response = await httpClient
        .post(
          target,
          headers: {
            'Authorization': 'Bearer $id',
            'X-Firebase-AppCheck': attestation,
            'Content-Type': 'application/json',
          },
          body: '{}',
        )
        .timeout(timeout);
    return parseLiveSessionResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: response.body,
      expectedModel: expectedModel,
    );
  } catch (_) {
    // Network errors, timeouts and token failures; details are not shown.
    return const LiveSessionDenied(LiveSessionDenial.unavailable);
  } finally {
    if (owned) httpClient.close();
  }
}

Future<String?> _firebaseIdToken() async =>
    FirebaseAuth.instance.currentUser?.getIdToken();

Future<String?> _firebaseAppCheckToken() =>
    FirebaseAppCheck.instance.getToken();
