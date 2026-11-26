// Remote Config routing policy (SS-076, DESIGN.md §5 and §6).
//
// Remote Config supplies only what the policy already accepts: per-feature
// RemoteRouting modes, a kill switch for hybrid cloud fallback, and the cloud
// model id. Defaults ship in the app. Nothing here can loosen `localOnly` or
// CloudRoutes:
// - modes go through RemoteRouting.modeFor, which ignores cloud-primary
//   values, and are applied after localOnly, cloud approval, hard limits and
//   availability (decideRoute);
// - the kill switch can only remove the compiled-in hybridFallback route;
// - a remote cloud model id is used only when the build allowlists it.
//
// A fetch that fails or takes longer than [RemotePolicy.load]'s timeout
// leaves the in-app defaults (or the last activated values) in force and
// never blocks startup for longer than that timeout.

import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart';

/// Remote Config parameter names.
abstract final class RemoteKeys {
  /// Bool. False turns hybrid cloud fallback off for this app run (and live,
  /// if it changes mid-run). True defers to the compiled `CLOUD_ROUTES`.
  static const hybridEnabled = 'hybrid_enabled';

  /// String. Cloud model id for hybrid fallback; empty = the compiled one.
  static const cloudModel = 'hybrid_cloud_model';

  /// String per feature, e.g. `hybrid_mode_pantry_scan`: a [HybridMode] name,
  /// or empty for the feature default.
  static const modePrefix = 'hybrid_mode_';

  static String mode(String feature) => '$modePrefix$feature';
}

/// The in-app defaults: no overrides, hybrid fallback as compiled, the
/// compiled cloud model.
Map<String, Object> remoteConfigDefaults() => {
  RemoteKeys.hybridEnabled: true,
  RemoteKeys.cloudModel: '',
  for (final feature in featureRoutes.keys) RemoteKeys.mode(feature): '',
};

/// The slice of Remote Config this policy uses, so tests can use a fake.
/// The production implementation is `FirebaseRemoteConfigSource`.
abstract class RemoteConfigSource {
  Future<void> configure({
    required Duration fetchTimeout,
    required Duration minimumFetchInterval,
    required Map<String, Object> defaults,
  });

  /// Fetches and activates. May be slow or fail.
  Future<void> fetchAndActivate();

  /// Active value (fetched, else default). May throw if the backend is not
  /// initialized.
  String getString(String key);
}

/// Cloud model ids the build accepts from Remote Config, besides the
/// compiled one: `--dart-define=HYBRID_CLOUD_MODEL_ALLOWLIST=a,b`. Default
/// empty, so Remote Config cannot switch models until a build allows it
/// (DESIGN.md §7: a model is used only after G1 confirms it is free here).
const kHybridCloudModelAllowlist = String.fromEnvironment(
  'HYBRID_CLOUD_MODEL_ALLOWLIST',
);

Set<String> parseModelAllowlist(String value) => {
  for (final id in value.split(','))
    if (id.trim().isNotEmpty) id.trim(),
};

final _modelId = RegExp(r'^[a-z0-9][a-z0-9._\-]{0,79}$');

/// The routing policy for one app run.
class RemotePolicy {
  RemotePolicy._(
    this._source, {
    required this.compiledCloudModel,
    required Set<String> allowedCloudModels,
    required this.fetched,
  }) : cloudModel = _chooseCloudModel(
         _readFrom(_source, RemoteKeys.cloudModel),
         compiled: compiledCloudModel,
         allowed: allowedCloudModels,
       );

  /// Defaults only; nothing is fetched.
  RemotePolicy.defaults({required this.compiledCloudModel})
    : _source = null,
      fetched = false,
      cloudModel = compiledCloudModel;

  /// Configures [source] with the in-app defaults and fetches, giving up
  /// after [timeout] (the whole sequence, not just the network call). A
  /// failure or timeout leaves the defaults or the last activated values in
  /// force. Never throws.
  static Future<RemotePolicy> load(
    RemoteConfigSource source, {
    required String compiledCloudModel,
    Set<String>? allowedCloudModels,
    Duration timeout = const Duration(seconds: 2),
    Duration minimumFetchInterval = const Duration(hours: 1),
  }) async {
    var fetched = false;
    try {
      await () async {
        await source.configure(
          fetchTimeout: timeout,
          minimumFetchInterval: minimumFetchInterval,
          defaults: remoteConfigDefaults(),
        );
        await source.fetchAndActivate();
      }().timeout(timeout);
      fetched = true;
    } catch (e) {
      // Offline, blocked, slow or not set up: the defaults stand.
      debugPrint('Remote Config not applied (${e.runtimeType}); defaults.');
    }
    return RemotePolicy._(
      source,
      compiledCloudModel: compiledCloudModel,
      allowedCloudModels:
          allowedCloudModels ?? parseModelAllowlist(kHybridCloudModelAllowlist),
      fetched: fetched,
    );
  }

  final RemoteConfigSource? _source;

  /// The build's `HYBRID_CLOUD_MODEL`.
  final String compiledCloudModel;

  /// Whether the startup fetch completed in time. Diagnostic only.
  final bool fetched;

  /// Chosen once, at load: the backend, the Dart cloud adapter and the
  /// consent copy are configured with it at startup and must agree.
  final String cloudModel;

  String? _read(String key) => _readFrom(_source, key);

  static String? _readFrom(RemoteConfigSource? source, String key) {
    if (source == null) return null;
    try {
      return source.getString(key).trim();
    } catch (_) {
      return null;
    }
  }

  static String _chooseCloudModel(
    String? remote, {
    required String compiled,
    required Set<String> allowed,
  }) {
    if (remote == null || remote.isEmpty || remote == compiled) {
      return compiled;
    }
    if (_modelId.hasMatch(remote) && allowed.contains(remote)) return remote;
    debugPrint("Remote cloud model is not in this build's allowlist; ignored.");
    return compiled;
  }

  /// Read live. A missing or unreadable value means enabled (defer to the
  /// compiled routes); any value other than a recognised true is "off",
  /// which can only tighten.
  bool get hybridEnabled {
    final raw = _read(RemoteKeys.hybridEnabled);
    if (raw == null || raw.isEmpty) return true;
    return const {'true', '1', 'yes', 'on'}.contains(raw.toLowerCase());
  }

  /// Read live, at every routing decision. Unknown names are dropped;
  /// cloud-primary names are passed through and then ignored by
  /// [RemoteRouting.modeFor].
  RemoteRouting routing() {
    if (_source == null) return const RemoteRouting();
    final modes = <String, HybridMode>{};
    for (final feature in featureRoutes.keys) {
      final raw = _read(RemoteKeys.mode(feature));
      if (raw == null || raw.isEmpty) continue;
      for (final mode in HybridMode.values) {
        if (mode.name == raw) modes[feature] = mode;
      }
    }
    return RemoteRouting(modes: modes);
  }

  /// [base] with the kill switch applied.
  CloudRoutes gate(CloudRoutes base) =>
      RemoteGatedCloudRoutes(base, () => hybridEnabled);
}

/// The compiled [CloudRoutes], minus [CloudRoute.hybridFallback] while the
/// kill switch is off. Read live at every `allows` call, so a mid-run change
/// applies to the next send (and to every fallback and retry). It never
/// allows a route the compiled set does not.
class RemoteGatedCloudRoutes extends CloudRoutes {
  RemoteGatedCloudRoutes(CloudRoutes base, this._hybridEnabled)
    : _base = base,
      super(base.approved);

  final CloudRoutes _base;
  final bool Function() _hybridEnabled;

  @override
  bool allows(CloudRoute route) {
    if (!_base.allows(route)) return false;
    if (route != CloudRoute.hybridFallback) return true;
    try {
      return _hybridEnabled();
    } catch (_) {
      return false;
    }
  }
}
