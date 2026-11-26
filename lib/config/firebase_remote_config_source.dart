// The production RemoteConfigSource (SS-076). Call only after
// Firebase.initializeApp. Remote Config has no paid tier; a project that has
// never published a template simply returns the in-app defaults.

import 'package:firebase_remote_config/firebase_remote_config.dart';

import 'remote_policy.dart';

class FirebaseRemoteConfigSource implements RemoteConfigSource {
  FirebaseRemoteConfigSource([FirebaseRemoteConfig? config])
    : _config = config ?? FirebaseRemoteConfig.instance;

  final FirebaseRemoteConfig _config;

  @override
  Future<void> configure({
    required Duration fetchTimeout,
    required Duration minimumFetchInterval,
    required Map<String, Object> defaults,
  }) async {
    await _config.setConfigSettings(
      RemoteConfigSettings(
        fetchTimeout: fetchTimeout,
        minimumFetchInterval: minimumFetchInterval,
      ),
    );
    await _config.setDefaults(defaults);
  }

  @override
  Future<void> fetchAndActivate() => _config.fetchAndActivate();

  @override
  String getString(String key) => _config.getString(key);
}
