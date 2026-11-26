// The Remote Config adapter against a fake FirebaseRemoteConfig. No Firebase
// app or network is involved.

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/config/firebase_remote_config_source.dart';

class _FakeRemoteConfig extends Fake implements FirebaseRemoteConfig {
  RemoteConfigSettings? applied;
  Map<String, dynamic>? defaults;
  int fetches = 0;

  @override
  Future<void> setConfigSettings(
    RemoteConfigSettings remoteConfigSettings,
  ) async => applied = remoteConfigSettings;

  @override
  Future<void> setDefaults(Map<String, dynamic> defaultParameters) async =>
      defaults = defaultParameters;

  @override
  Future<bool> fetchAndActivate() async {
    fetches++;
    return true;
  }

  @override
  String getString(String key) => 'value-of-$key';
}

void main() {
  test('passes settings, defaults, fetch and reads through', () async {
    final rc = _FakeRemoteConfig();
    final source = FirebaseRemoteConfigSource(rc);
    await source.configure(
      fetchTimeout: const Duration(seconds: 2),
      minimumFetchInterval: const Duration(hours: 1),
      defaults: const {'hybrid_enabled': true},
    );
    expect(rc.applied?.fetchTimeout, const Duration(seconds: 2));
    expect(rc.applied?.minimumFetchInterval, const Duration(hours: 1));
    expect(rc.defaults, {'hybrid_enabled': true});
    await source.fetchAndActivate();
    expect(rc.fetches, 1);
    expect(
      source.getString('hybrid_cloud_model'),
      'value-of-hybrid_cloud_model',
    );
  });
}
