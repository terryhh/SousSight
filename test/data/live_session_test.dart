import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:soussight/data/live_session.dart';
import 'package:soussight/live/live_tools.dart';

LiveSessionReservation _parse(
  int status,
  Object? body, {
  Map<String, String> headers = const {},
}) => parseLiveSessionResponse(
  statusCode: status,
  headers: headers,
  body: body is String ? body : jsonEncode(body),
);

LiveSessionDenial? _denial(LiveSessionReservation r) =>
    r is LiveSessionDenied ? r.reason : null;

void main() {
  group('parseLiveSessionResponse', () {
    test('only ok:true with the pinned model admits', () {
      final granted = _parse(200, {'ok': true, 'model': kLiveModel});
      expect(granted, isA<LiveSessionGranted>());
      expect((granted as LiveSessionGranted).model, kLiveModel);
    });

    test('a different server model is a configuration denial', () {
      expect(
        _denial(_parse(200, {'ok': true, 'model': 'gemini-other-live'})),
        LiveSessionDenial.notConfigured,
      );
    });

    test('malformed 200 responses abstain', () {
      for (final body in <Object?>[
        'not json',
        [],
        {'model': kLiveModel},
        {'ok': 'true', 'model': kLiveModel},
        {'ok': true},
        {'ok': true, 'model': 3},
        {'ok': true, 'model': ''},
      ]) {
        expect(
          _denial(_parse(200, body)),
          LiveSessionDenial.unavailable,
          reason: '$body',
        );
      }
    });

    test('429 carries the retry time from the header or the body', () {
      final fromHeader = _parse(
        429,
        {'ok': false},
        headers: {'retry-after': '2'},
      );
      expect(_denial(fromHeader), LiveSessionDenial.rateLimited);
      final denied = fromHeader as LiveSessionDenied;
      expect(denied.retryAfter, const Duration(seconds: 2));
      expect(denied.message, contains('try again in 2 seconds'));
      expect(denied.message, contains('Coach Lite'));

      final fromBody = _parse(429, {
        'ok': false,
        'error': {'code': 'rate-limited', 'retryAfterSeconds': 3600},
      }) as LiveSessionDenied;
      expect(fromBody.retryAfter, const Duration(hours: 1));
      expect(fromBody.message, contains('60 minutes'));

      final nonsense = _parse(
        429,
        {'ok': false},
        headers: {'retry-after': '-4'},
      ) as LiveSessionDenied;
      expect(nonsense.retryAfter, isNull);
      expect(nonsense.message, isNot(contains('try again in')));
    });

    test('auth, configuration and server failures map to cook messages', () {
      expect(_denial(_parse(401, {})), LiveSessionDenial.unverified);
      expect(_denial(_parse(403, {})), LiveSessionDenial.unverified);
      expect(_denial(_parse(404, '')), LiveSessionDenial.notConfigured);
      expect(
        _denial(
          _parse(503, {
            'ok': false,
            'error': {'code': 'not-configured'},
          }),
        ),
        LiveSessionDenial.notConfigured,
      );
      expect(_denial(_parse(503, {})), LiveSessionDenial.unavailable);
      expect(_denial(_parse(500, 'boom')), LiveSessionDenial.unavailable);
      for (final reason in LiveSessionDenial.values) {
        expect(LiveSessionDenied(reason).message, contains('Coach Lite'));
      }
    });
  });

  group('liveSessionEndpoint', () {
    test('native needs an absolute https LIVE_SESSION_URL', () {
      final url = 'https://us-central1-example.cloudfunctions.net/liveSession';
      expect(
        liveSessionEndpoint(configured: url, isWeb: false),
        Uri.parse(url),
      );
      expect(liveSessionEndpoint(configured: '', isWeb: false), isNull);
      expect(
        liveSessionEndpoint(
          configured: 'http://insecure.example/x',
          isWeb: false,
        ),
        isNull,
      );
      expect(
        liveSessionEndpoint(configured: '/api/live-session', isWeb: false),
        isNull,
      );
    });

    test('web uses the Hosting rewrite on its own origin', () {
      expect(
        liveSessionEndpoint(
          configured: '',
          isWeb: true,
          base: Uri.parse('https://devfest-flutter-a59e8.web.app/cook/1'),
        ),
        Uri.parse('https://devfest-flutter-a59e8.web.app/api/live-session'),
      );
    });
  });

  group('reserveLiveSession', () {
    final endpoint = Uri.parse('https://example.test/api/live-session');

    test('sends both tokens and an empty body', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({'ok': true, 'model': kLiveModel}),
          200,
        );
      });
      final result = await reserveLiveSession(
        client: client,
        endpoint: endpoint,
        idToken: () async => 'id-token',
        appCheckToken: () async => 'app-check',
      );
      expect(result, isA<LiveSessionGranted>());
      expect(sent.method, 'POST');
      expect(sent.url, endpoint);
      expect(sent.headers['Authorization'], 'Bearer id-token');
      expect(sent.headers['X-Firebase-AppCheck'], 'app-check');
      expect(sent.body, '{}');
    });

    test('a missing token is denied without a request', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });
      for (final (id, check) in [
        (null, 'a'),
        ('i', null),
        ('', 'a'),
        ('i', ''),
      ]) {
        final result = await reserveLiveSession(
          client: client,
          endpoint: endpoint,
          idToken: () async => id,
          appCheckToken: () async => check,
        );
        expect(_denial(result), LiveSessionDenial.unverified);
      }
      expect(requests, 0);
    });

    test('network errors and timeouts are denials, never throws', () async {
      final failing = MockClient((_) async => throw http.ClientException('x'));
      expect(
        _denial(
          await reserveLiveSession(
            client: failing,
            endpoint: endpoint,
            idToken: () async => 'i',
            appCheckToken: () async => 'a',
          ),
        ),
        LiveSessionDenial.unavailable,
      );
      final slow = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{}', 200);
      });
      expect(
        _denial(
          await reserveLiveSession(
            client: slow,
            endpoint: endpoint,
            idToken: () async => 'i',
            appCheckToken: () async => 'a',
            timeout: const Duration(milliseconds: 1),
          ),
        ),
        LiveSessionDenial.unavailable,
      );
      final tokenFailure = await reserveLiveSession(
        client: failing,
        endpoint: endpoint,
        idToken: () async => throw StateError('signed out'),
        appCheckToken: () async => 'a',
      );
      expect(_denial(tokenFailure), LiveSessionDenial.unavailable);
    });
  });
}
