// Fakes for the Firebase Auth and App Check token reads that guard the
// app's own HTTPS endpoints. No Firebase app, plugin channel or network.

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class FakeIdUser implements User {
  FakeIdUser(this.idToken);
  final String? idToken;

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => idToken;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTokenAuth implements FirebaseAuth {
  FakeTokenAuth([this.currentUser]);

  /// Signed in with an ID token.
  FakeTokenAuth.signedIn(String idToken) : currentUser = FakeIdUser(idToken);

  @override
  User? currentUser;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAppCheck implements FirebaseAppCheck {
  FakeAppCheck(this.token);
  final String? token;

  @override
  Future<String?> getToken([bool? forceRefresh]) async => token;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records each POST and answers with [respond].
class RecordingPost {
  RecordingPost(this.respond);
  final Future<http.Response> Function() respond;
  final urls = <Uri>[];
  final headers = <Map<String, String>?>[];
  final bodies = <Object?>[];

  Future<http.Response> call(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) {
    urls.add(url);
    this.headers.add(headers);
    bodies.add(body);
    return respond();
  }
}
