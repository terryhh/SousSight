// On-demand "Show me what it should look like" for AI-drafted recipes
// (SS-098). One controller per cooking session.
//
// Image generation exists only in the cloud, so every request is a cloud
// send: it needs the `images` cloud route, the cook's local-only settings
// off, a connection, a consent grant for that exact prompt, and room under
// the per-session cap. Everything is re-read immediately before the send,
// after the consent prompt. Each send is one ledger leg (cloud, text in,
// image out). A result that arrives after the step, recipe or session
// changed, or after dispose, is dropped.

import 'dart:convert';
import 'dart:math' as math;

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show HybridErrorCode;
import 'package:flutter/foundation.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart' show localOnlyFor;
import '../ai/hybrid/payload_digest.dart' show sha256Hex;
import '../core/cloud_send.dart';
import '../core/models.dart';
import 'illustration_generator.dart';
import 'illustration_prompts.dart';

/// Why no illustration was made.
enum IllustrationBlock {
  /// This build does not approve the `images` cloud route.
  cloudNotApproved,

  /// The cook keeps recipe drafting or illustrations on this device.
  localOnly,
  offline,
  consentDeclined,

  /// This session's on-demand illustrations are used up.
  capReached,

  /// This target never gets a picture (meat, poultry, fish or eggs, or no
  /// visible cue).
  noPicture,
}

/// Cook-facing sentence for each block.
String illustrationBlockText(IllustrationBlock block) => switch (block) {
  IllustrationBlock.cloudNotApproved =>
    'Illustrations need the cloud, and cloud images are off in this build.',
  IllustrationBlock.localOnly =>
    'Illustrations need the cloud. You have chosen to keep recipe help on '
        'this device, so nothing was sent.',
  IllustrationBlock.offline =>
    "You're offline. Illustrations need the cloud; try again when you're "
        'connected.',
  IllustrationBlock.consentDeclined => 'Nothing was sent.',
  IllustrationBlock.capReached =>
    "You've used this cook's illustrations. Check the step text and your "
        'own eyes instead.',
  IllustrationBlock.noPicture => kIllustrationNoDonenessCopy,
};

sealed class IllustrationState {
  const IllustrationState();
}

class IllustrationIdle extends IllustrationState {
  const IllustrationIdle();
}

class IllustrationLoading extends IllustrationState {
  const IllustrationLoading({this.sending = false});

  /// False while the consent prompt is open: nothing has been sent yet.
  final bool sending;
}

class IllustrationReady extends IllustrationState {
  const IllustrationReady(this.image);
  final GeneratedIllustration image;
}

class IllustrationBlocked extends IllustrationState {
  const IllustrationBlocked(this.reason);
  final IllustrationBlock reason;
}

class IllustrationFailed extends IllustrationState {
  const IllustrationFailed(this.code);
  final HybridErrorCode code;
}

class IllustrationController extends ChangeNotifier {
  IllustrationController({
    required CloudRoutes cloudRoutes,
    required this._privacy,
    required this._isOnline,
    required this._consent,
    required this._recorder,
    required this._generator,
    this.cap = kIllustrationSessionCap,
  }) : _routes = cloudRoutes;

  final CloudRoutes _routes;
  final PrivacySettings _privacy;
  final bool Function() _isOnline;
  final ConsentGate _consent;
  final CloudSendRecorder _recorder;
  final IllustrationGenerator _generator;

  /// On-demand illustrations per session.
  final int cap;

  String? _sessionId;
  String? _recipeId;
  String? _stepId;
  int _epoch = 0;
  int _used = 0;
  bool _disposed = false;

  /// This session's images, by target key.
  final Map<String, GeneratedIllustration> _cache = {};

  /// Loading, blocked and failed states for the current step.
  final Map<String, IllustrationState> _states = {};

  String get model => _generator.model;
  int get used => _used;
  int get remaining => math.max(0, cap - _used);

  /// Points the controller at the cook's current session, recipe and step.
  /// A new session or recipe empties the cache and resets the cap; a new
  /// step drops in-flight work and clears its notices.
  void bind({
    required String sessionId,
    required String recipeId,
    required String stepId,
  }) {
    if (_disposed) return;
    if (sessionId == _sessionId && recipeId == _recipeId && stepId == _stepId) {
      return;
    }
    _epoch++;
    if (sessionId != _sessionId || recipeId != _recipeId) {
      _cache.clear();
      _used = 0;
    }
    _states.clear();
    _sessionId = sessionId;
    _recipeId = recipeId;
    _stepId = stepId;
    notifyListeners();
  }

  /// The session ended: forget everything and drop in-flight results.
  void endSession() {
    if (_disposed || _sessionId == null) return;
    _epoch++;
    _cache.clear();
    _states.clear();
    _used = 0;
    _sessionId = _recipeId = _stepId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }

  /// Why a request would be refused right now, read live; null if it may
  /// go ahead. The cap is checked last so a cloud block is what the cook
  /// sees first.
  IllustrationBlock? availability() {
    if (!_routes.allows(CloudRoute.images)) {
      return IllustrationBlock.cloudNotApproved;
    }
    // The prompt is built from the drafted recipe, so the recipe draft's
    // local-only switch covers it too.
    if (localOnlyFor(_privacy, kIllustrationFeature) ||
        localOnlyFor(_privacy, 'recipe_draft')) {
      return IllustrationBlock.localOnly;
    }
    if (!_isOnline()) return IllustrationBlock.offline;
    if (remaining <= 0) return IllustrationBlock.capReached;
    return null;
  }

  IllustrationState stateFor(IllustrationTarget target) {
    if (_cache[target.key] case final image?) return IllustrationReady(image);
    return _states[target.key] ?? const IllustrationIdle();
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;

  void _set(String key, IllustrationState state) {
    if (_disposed) return;
    _states[key] = state;
    notifyListeners();
  }

  /// Makes an illustration of [target] in [recipe]. A cached image is
  /// returned without a call; a request already in flight is not repeated.
  Future<void> request(Recipe recipe, IllustrationTarget target) async {
    final session = _sessionId;
    if (_disposed || session == null || recipe.id != _recipeId) return;
    final key = target.key;
    if (_cache.containsKey(key) || _states[key] is IllustrationLoading) return;
    final prompt = illustrationPrompt(recipe, target);
    if (prompt == null) {
      _set(key, const IllustrationBlocked(IllustrationBlock.noPicture));
      return;
    }
    if (availability() case final block?) {
      _set(key, IllustrationBlocked(block));
      return;
    }
    final epoch = _epoch;
    _set(key, const IllustrationLoading());
    final digest = sha256Hex(utf8.encode(prompt.text));
    final ConsentGrant? grant;
    try {
      grant = await _consent.request(
        ConsentAsk(
          feature: kIllustrationFeature,
          kinds: const {DataKind.text},
          payloadDigest: digest,
          sessionId: session,
        ),
      );
    } catch (_) {
      if (_current(epoch)) {
        _set(key, const IllustrationBlocked(IllustrationBlock.consentDeclined));
      }
      return;
    }
    if (!_current(epoch)) return;
    if (grant == null ||
        grant.ask.sessionId != session ||
        grant.ask.feature != kIllustrationFeature ||
        grant.ask.payloadDigest != digest) {
      _set(key, const IllustrationBlocked(IllustrationBlock.consentDeclined));
      return;
    }
    // Send time: read every setting again; the prompt may have been open
    // while the cook changed them.
    if (availability() case final block?) {
      _set(key, IllustrationBlocked(block));
      return;
    }
    _used++;
    _set(key, const IllustrationLoading(sending: true));
    final send = _recorder.begin(kIllustrationFeature, const {DataKind.text});
    try {
      final image = await _generator.generate(prompt.text);
      send.confirmed(modelLabel: illustrationModelLabel(image.model));
      if (!_current(epoch)) return;
      _cache[key] = image;
      _states.remove(key);
      notifyListeners();
    } on IllustrationException catch (e) {
      send.failed(e.code);
      if (_current(epoch)) _set(key, IllustrationFailed(e.code));
    } catch (_) {
      send.failed(HybridErrorCode.failed);
      if (_current(epoch)) {
        _set(key, const IllustrationFailed(HybridErrorCode.failed));
      }
    }
  }
}
