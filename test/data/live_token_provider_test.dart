import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:soussight/data/live_token_provider.dart';

import 'firebase_token_fakes.dart';

void main() {
  http.Response ok(Map<String, Object?> json) =>
      http.Response(jsonEncode(json), 200);

  test(
    'posts the ID and App Check tokens and returns a validated token',
    () async {
      final post = RecordingPost(
        () async => ok({
          'token': 'auth_tokens/abc',
          'model': 'gemini-live-test',
          'apiVersion': 'v1alpha',
        }),
      );

      final token = await fetchLiveToken(
        auth: FakeTokenAuth.signedIn('id-token'),
        appCheck: FakeAppCheck('app-check-token'),
        post: post.call,
      );

      expect(token.token, 'auth_tokens/abc');
      expect(token.model, 'gemini-live-test');
      expect(token.apiVersion, 'v1alpha');
      expect(post.urls.single.path, '/api/live-token');
      expect(post.headers.single, {
        'Authorization': 'Bearer id-token',
        'X-Firebase-AppCheck': 'app-check-token',
        'Content-Type': 'application/json',
      });
      expect(post.bodies.single, '{}');
    },
  );

  for (final (label, auth, appCheck) in [
    ('signed out', FakeTokenAuth(), FakeAppCheck('app-check')),
    ('no ID token', FakeTokenAuth(FakeIdUser(null)), FakeAppCheck('ac')),
    ('no App Check token', FakeTokenAuth.signedIn('id'), FakeAppCheck(null)),
    ('empty App Check token', FakeTokenAuth.signedIn('id'), FakeAppCheck('')),
  ]) {
    test('$label: refuses before any request is made', () async {
      final post = RecordingPost(() async => ok({}));
      await expectLater(
        fetchLiveToken(auth: auth, appCheck: appCheck, post: post.call),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Sign in and configure App Check before starting Live.',
          ),
        ),
      );
      expect(post.urls, isEmpty);
    });
  }

  test('a non-200 answer never surfaces the response body', () async {
    final post = RecordingPost(
      () async => http.Response('{"apiKey":"AIza-not-a-real-key"}', 503),
    );
    await expectLater(
      fetchLiveToken(
        auth: FakeTokenAuth.signedIn('id'),
        appCheck: FakeAppCheck('ac'),
        post: post.call,
      ),
      throwsA(
        isA<StateError>()
            .having((e) => e.message, 'message', contains('(503)'))
            .having((e) => e.message, 'message', isNot(contains('AIza'))),
      ),
    );
  });

  for (final (label, body) in [
    (
      'wrong token prefix',
      {'token': 'abc', 'model': 'gemini-x', 'apiVersion': 'v1beta'},
    ),
    (
      'unsafe model name',
      {'token': 'auth_tokens/a', 'model': 'evil/model', 'apiVersion': 'v1beta'},
    ),
    (
      'unknown API version',
      {'token': 'auth_tokens/a', 'model': 'gemini-x', 'apiVersion': 'v9'},
    ),
  ]) {
    test('malformed 200 answer ($label) is rejected', () async {
      final post = RecordingPost(() async => ok(body));
      await expectLater(
        fetchLiveToken(
          auth: FakeTokenAuth.signedIn('id'),
          appCheck: FakeAppCheck('ac'),
          post: post.call,
        ),
        throwsFormatException,
      );
    });
  }

  test('a hung endpoint times out after 20 seconds', () {
    fakeAsync((async) {
      Object? failure;
      fetchLiveToken(
        auth: FakeTokenAuth.signedIn('id'),
        appCheck: FakeAppCheck('ac'),
        post: RecordingPost(() => Completer<http.Response>().future).call,
      ).then<void>((_) {}, onError: (Object e) => failure = e);
      async.elapse(const Duration(seconds: 19));
      expect(failure, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(failure, isA<TimeoutException>());
    });
  });
}
