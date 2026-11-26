// On-demand "Show me what it should look like" for AI-drafted recipes
// (SS-098). One controller per cooking screen; the paid cap is kept per
// cooking-session id in an [IllustrationUsage] that outlives the screen.
//
// Image generation exists only in the cloud, so every request is a cloud
// send: it needs the `images` cloud route, the cook's local-only settings
// off, a connection, a consent grant for that exact prompt, and room under
// the per-session cap. Everything is re-read immediately before the send,
// after the consent prompt. Each send is one ledger leg (cloud, text in,
// image out). A result that arrives after the step, recipe or session
// changed, or after dispose, is dropped.

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show HybridErrorCode;
import 'package:flutter/foundation.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart' show localOnlyFor;
import '../ai/hybrid/payload_digest.dart' show sha256Hex;
import '../core/models.dart';
import 'illustration_generator.dart';
import 'illustration_ledger.dart';
import 'illustration_prompts.dart';
import 'on_demand_allowlist.dart';

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

  /// The cooking session has not started (or could not be opened).
  noSession,
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
  IllustrationBlock.noPicture => kIllustrationNotOfferedCopy,
  IllustrationBlock.noSession =>
    'Available once your cooking session has started.',
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
  const IllustrationReady(this.image, this.source);
  final GeneratedIllustration image;

  /// Where it came from, read back from its settled ledger leg.
  final IllustrationSource source;
}

/// The settled ledger leg behind an on-demand image, kept beside it so the
/// screen can say it came from the cloud (bundled images have none).
class IllustrationSource {
  const IllustrationSource({required this.receipt, required this.target});
  final IllustrationReceipt receipt;
  final IllustrationTarget target;

  /// Cook-facing, derived from the leg and the actual payload: only a cloud
  /// provenance says "sent". The SDK does not report which model answered,
  /// so the model is the configured one.
  String describe() {
    final from = switch (target) {
      PlateTarget() => "the dish's ingredient list",
      StepTarget() => "this step's cue and the ingredients it names",
    };
    return switch (receipt.provenance) {
      Provenance.sdkCloud || Provenance.cloudAdapter =>
        "Made just now in Google's cloud from $from, sent with your OK. "
            'Configured model: ${receipt.modelLabel}.',
      _ => 'Made by AI from $from (configured model: ${receipt.modelLabel}).',
    };
  }
}

class IllustrationBlocked extends IllustrationState {
  const IllustrationBlocked(this.reason);
  final IllustrationBlock reason;
}

class IllustrationFailed extends IllustrationState {
  const IllustrationFailed(this.code);
  final HybridErrorCode code;
}

/// Paid on-demand sends per cooking-session id. Lives as long as the app's
/// hybrid runtime, so leaving a cooking screen and re-entering the same
/// session (back to the pantry, "Cook this draft" again) keeps the count.
class IllustrationUsage {
  final Map<String, int> _used = {};
  int used(String sessionId) => _used[sessionId] ?? 0;
  void charge(String sessionId) => _used[sessionId] = used(sessionId) + 1;
}

class IllustrationController extends ChangeNotifier {
  IllustrationController({
    required CloudRoutes cloudRoutes,
    required this._privacy,
    required this._isOnline,
    required this._consent,
    required this._ledger,
    required this._generator,
    this.cap = kIllustrationSessionCap,
    Future<bool> Function(Uint8List bytes)? decodes,
    this._settingsChanges,
    IllustrationUsage? usage,
    this.connectivityKnown = true,
  }) : _routes = cloudRoutes,
       _decodes = decodes ?? imageDecodes,
       _usage = usage ?? IllustrationUsage() {
    _settingsChanges?.addListener(_onSettingsChanged);
  }

  /// The cook's privacy preferences, when they can be observed: a change
  /// re-renders the panel so a button follows the switch at once.
  final Listenable? _settingsChanges;

  void _onSettingsChanged() {
    if (!_disposed) notifyListeners();
  }

  final CloudRoutes _routes;
  final PrivacySettings _privacy;
  final bool Function() _isOnline;
  final ConsentGate _consent;
  final IllustrationLedger _ledger;
  final IllustrationGenerator _generator;
  final Future<bool> Function(Uint8List bytes) _decodes;
  final IllustrationUsage _usage;

  /// On-demand illustrations per cooking session.
  final int cap;

  /// Whether [_isOnline] can actually tell. On Android and iOS it cannot
  /// yet (it reports online until native connectivity lands, #224), so the
  /// panel says a failed try still counts instead of claiming a check.
  final bool connectivityKnown;

  /// The binding a button was built for. A callback built for an older
  /// binding (another step, recipe revision or session) starts nothing.
  int get bindingEpoch => _epoch;

  String? _sessionId;
  String? _revision;
  String? _stepId;
  int _epoch = 0;
  bool _disposed = false;

  /// Grants already spent on a dispatch. A grant is used once (DESIGN.md
  /// §5); a gate that hands the same grant back is refused.
  final Set<ConsentGrant> _spentGrants = HashSet.identity();

  /// This binding's images, by target key.
  final Map<String, IllustrationReady> _cache = {};

  /// Loading, blocked and failed states for the current step.
  final Map<String, IllustrationState> _states = {};

  String get model => _generator.model;
  bool get hasSession => _sessionId != null;
  int get used => _sessionId == null ? 0 : _usage.used(_sessionId!);
  int get remaining => math.max(0, cap - used);

  /// Points the controller at the cook's current session, recipe content
  /// and step. A new session or a recipe whose content changed (even under
  /// the same ids) drops the cache; a new step drops in-flight work and
  /// clears its notices. The cap belongs to the session id, not to this
  /// binding.
  void bind({
    required String sessionId,
    required Recipe recipe,
    required String stepId,
  }) {
    if (_disposed) return;
    final revision = illustrationRevision(recipe);
    if (sessionId == _sessionId && revision == _revision && stepId == _stepId) {
      return;
    }
    _epoch++;
    if (sessionId != _sessionId || revision != _revision) _cache.clear();
    _states.clear();
    _sessionId = sessionId;
    _revision = revision;
    _stepId = stepId;
    notifyListeners();
  }

  /// The session ended: forget this binding and drop in-flight results.
  void endSession() {
    if (_disposed || _sessionId == null) return;
    _epoch++;
    _cache.clear();
    _states.clear();
    _sessionId = _revision = _stepId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _settingsChanges?.removeListener(_onSettingsChanged);
    super.dispose();
  }

  /// Why a request would be refused right now, read live; null if it may
  /// go ahead. The cook's local-only choice comes first (DESIGN.md §5),
  /// then the build's route, connectivity, the session and the cap.
  IllustrationBlock? availability() {
    // The prompt is built from the drafted recipe, so the recipe draft's
    // local-only switch covers it too.
    if (localOnlyFor(_privacy, kIllustrationFeature) ||
        localOnlyFor(_privacy, 'recipe_draft')) {
      return IllustrationBlock.localOnly;
    }
    if (!_routes.allows(CloudRoute.images)) {
      return IllustrationBlock.cloudNotApproved;
    }
    if (!_isOnline()) return IllustrationBlock.offline;
    if (_sessionId == null) return IllustrationBlock.noSession;
    if (remaining <= 0) return IllustrationBlock.capReached;
    return null;
  }

  IllustrationState stateFor(IllustrationTarget target) {
    if (_cache[target.key] case final ready?) return ready;
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
  /// A request from a stale button (another step, an older recipe
  /// revision) is ignored.
  Future<void> request(
    Recipe recipe,
    IllustrationTarget target, {
    int? fromEpoch,
  }) async {
    final session = _sessionId;
    if (_disposed || session == null) return;
    // Any target, plate included: a callback from an older binding is stale.
    if (fromEpoch != null && fromEpoch != _epoch) return;
    if (illustrationRevision(recipe) != _revision) return;
    if (target case StepTarget(:final stepId) when stepId != _stepId) return;
    final key = target.key;
    if (_cache.containsKey(key) || _states[key] is IllustrationLoading) return;
    final prompt = onDemandIllustrationPrompt(recipe, target);
    if (prompt == null) {
      _set(key, const IllustrationBlocked(IllustrationBlock.noPicture));
      return;
    }
    if (availability() case final block?) {
      _set(key, IllustrationBlocked(block));
      return;
    }
    final epoch = _epoch;
    // The request belongs to the ledger it started under.
    final generation = _ledger.generation;
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
        grant.ask.payloadDigest != digest ||
        !setEquals(grant.ask.kinds, const {DataKind.text}) ||
        _spentGrants.contains(grant)) {
      _set(key, const IllustrationBlocked(IllustrationBlock.consentDeclined));
      return;
    }
    // A grant held across a ledger rotation is void: nothing is sent or
    // charged under a session the cook did not consent in.
    if (_ledger.generation != generation) {
      _set(key, const IllustrationFailed(HybridErrorCode.cancelled));
      return;
    }
    // Send time: read every setting again; the prompt may have been open
    // while the cook changed them.
    if (availability() case final block?) {
      _set(key, IllustrationBlocked(block));
      return;
    }
    // The leg is admitted before the generator is invoked (DESIGN.md §5).
    // The ledger tells its observers synchronously, and one of them may
    // change a setting or move the cook on, so everything is checked again
    // after admission. A send stopped here is withdrawn (recorded as not
    // sent) and costs nothing; the cap is charged only at dispatch.
    final send = _ledger.begin();
    // A listener may have rotated the ledger during admission: with no
    // pending leg in the active ledger there is no record to send under.
    if (!send.admitted) {
      if (_current(epoch)) {
        _set(key, const IllustrationFailed(HybridErrorCode.cancelled));
      }
      return;
    }
    final late = _current(epoch) ? availability() : null;
    if (!_current(epoch) || late != null) {
      send.withdrawn();
      if (late != null && _current(epoch)) _set(key, IllustrationBlocked(late));
      return;
    }
    _spentGrants.add(grant);
    _usage.charge(session);
    Future<GeneratedIllustration> pending;
    try {
      pending = _generator.generate(prompt.text);
    } catch (e) {
      pending = Future.error(e);
    }
    if (_current(epoch)) _set(key, const IllustrationLoading(sending: true));
    try {
      final image = await pending;
      final receipt = send.confirmed(illustrationModelLabel(image.model));
      // A valid signature over garbage must not show as a blank "ready".
      final decodes = await _decodes(image.bytes);
      if (!_current(epoch)) return;
      // No settled leg, or it left the active ledger while decoding (a new
      // session): nothing may claim this send, so the image is not shown.
      if (!decodes || receipt == null || !send.recorded) {
        _set(key, const IllustrationFailed(HybridErrorCode.failed));
        return;
      }
      _cache[key] = IllustrationReady(
        image,
        IllustrationSource(receipt: receipt, target: target),
      );
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
