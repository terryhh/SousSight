// Runs one label check at a time through the HybridDispatcher (DESIGN.md §5,
// §6 SS-069).
//
// - A photo is sent without asking only when the local model can read images
//   and the request fits its budget, so the dispatcher runs it on this device.
// - Otherwise (iOS, no local model, too large) the cook chooses: type the
//   label (text, on this device) or send this one photo to the cloud. The
//   cloud path asks the ConsentGate for that exact payload and session, then
//   re-reads the privacy setting, approved routes and connectivity right
//   before the send.
// - Every result is bound to the check, the session and the sheet that
//   started it; anything late is dropped.

import 'dart:async';
import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../trust/route_reason_text.dart';
import 'household_allergens.dart';
import 'label_check.dart';
import 'label_payload_digest.dart';

enum LabelSource { photo, typed }

enum LabelCheckPhase {
  /// Nothing running.
  idle,

  /// Waiting for the camera to hand over a photo.
  capturing,

  /// Reading the device's capabilities.
  preparing,

  /// The local model can't read this photo: type it, or consent to the cloud.
  awaitingChoice,

  /// The consent prompt for the cloud photo is open.
  awaitingConsent,

  /// A request is with the dispatcher.
  checking,

  /// A reading, a block or a failure is on screen.
  done,
}

/// A validated reading and the legs that produced it.
class LabelCheckResult {
  const LabelCheckResult({
    required this.reading,
    required this.legs,
    required this.source,
  });

  final LabelReading reading;
  final List<InferenceLeg> legs;
  final LabelSource source;
}

class LabelCheckController extends ChangeNotifier {
  LabelCheckController({
    required this.dispatcher,
    required this.privacy,
    required this.household,
    required this._capabilities,
    required this._sessionId,
    this.consentGate,
    CloudRoutes? cloudRoutes,
    bool Function()? isOnline,
    this.requestTimeout = const Duration(seconds: 30),
  }) : cloudRoutes = cloudRoutes ?? CloudRoutes.fromEnvironment(),
       _isOnline = isOnline ?? _alwaysOnline {
    household.addListener(_notify);
    // Re-evaluate the cloud offer when the cook flips a privacy switch.
    final p = privacy;
    if (p is Listenable) (p as Listenable).addListener(_notify);
  }

  final HybridDispatcher dispatcher;

  /// Read live at every decision and immediately before a cloud send.
  final PrivacySettings privacy;
  final HouseholdAllergens household;

  /// Null: the cloud photo path is not offered.
  final ConsentGate? consentGate;
  final CloudRoutes cloudRoutes;
  final Duration requestTimeout;
  final Future<HybridCapabilities> Function() _capabilities;
  final bool Function() _isOnline;

  static bool _alwaysOnline() => true;

  String _sessionId;
  int _epoch = 0;
  bool _closed = false;
  bool _disposed = false;
  HybridOperation? _operation;

  LabelCheckPhase _phase = LabelCheckPhase.idle;
  LabelCheckResult? _result;
  List<InferenceLeg> _legs = const [];
  RouteReason? _blocked;
  String? _notice;
  Uint8List? _pendingPhoto;
  bool _typedRunsHere = false;
  String? _localModelFamily;

  String get sessionId => _sessionId;
  LabelCheckPhase get phase => _phase;
  bool get busy =>
      _phase == LabelCheckPhase.capturing ||
      _phase == LabelCheckPhase.preparing ||
      _phase == LabelCheckPhase.checking ||
      _phase == LabelCheckPhase.awaitingConsent;

  /// The validated reading of the latest check, if it produced one.
  LabelCheckResult? get result => _result;

  /// Every leg of the latest check, including blocked or failed attempts.
  List<InferenceLeg> get legs => _legs;

  /// Why the latest check did not run, if the dispatcher blocked it.
  RouteReason? get blockedReason => _blocked;

  /// A short message about the latest action, if any.
  String? get notice => _notice;

  /// For the badge: `HybridCapabilities.local?.modelFamily`.
  String? get localModelFamily => _localModelFamily;

  /// In [LabelCheckPhase.awaitingChoice]: whether the typed label can run on
  /// this device's model.
  bool get typedPathAvailable => _typedRunsHere;

  /// In [LabelCheckPhase.awaitingChoice]: whether the cook may be asked to
  /// send this one photo to the cloud. Read live.
  bool get cloudPhotoOffered =>
      _pendingPhoto != null &&
      consentGate != null &&
      _cloudBlockReason() == null;

  /// Household allergens the latest reading mentions, read live.
  List<String> get matches =>
      _result?.reading.matches(household.allergens) ?? const [];

  // ---- actions ----------------------------------------------------------------

  /// Takes a photo with [takePhoto] and checks it. The capture belongs to the
  /// check started here: if the sheet closes, the session changes or another
  /// check starts while the camera is busy, the photo is discarded unsent.
  Future<void> captureAndCheck(Future<Uint8List?> Function() takePhoto) async {
    if (_closed || busy) return;
    final token = _begin();
    _phase = LabelCheckPhase.capturing;
    _notify();
    Uint8List? jpeg;
    try {
      jpeg = await takePhoto();
    } catch (_) {
      jpeg = null;
    }
    if (!_isCurrent(token)) return;
    if (jpeg == null) {
      _finish(token, phase: LabelCheckPhase.idle);
      return;
    }
    await _checkPhoto(token, jpeg);
  }

  /// Checks a photographed label. [jpeg] must be a JPEG of at most 1 MB and
  /// 768 px on its longer side.
  Future<void> checkPhoto(Uint8List jpeg) async {
    if (_closed) return;
    final token = _begin();
    await _checkPhoto(token, jpeg);
  }

  Future<void> _checkPhoto(_Token token, Uint8List jpeg) async {
    final problem = labelPhotoProblem(jpeg);
    if (problem != null) {
      _finish(token, notice: problem, phase: LabelCheckPhase.idle);
      return;
    }
    final photo = Uint8List.fromList(jpeg);
    final caps = await _loadCapabilities(token);
    if (caps == null) return;
    final task = _photoTask(photo);
    if (_fitsLocalModel(caps, task)) {
      await _send(token, task, LabelSource.photo);
      return;
    }
    _pendingPhoto = photo;
    _typedRunsHere = _typedFitsLocalModel(caps);
    _phase = LabelCheckPhase.awaitingChoice;
    _notice = caps.local == null
        ? "This device doesn't have an on-device model that can read photos."
        : "This device's on-device model can't read this photo.";
    _notify();
  }

  /// Checks label text the cook typed or pasted. Runs only on this device's
  /// model; if it can't, nothing is sent.
  Future<void> checkTyped(String text) async {
    if (_closed) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      _notice = "Type or paste the label's ingredients or allergen statement.";
      _notify();
      return;
    }
    if (trimmed.length > kMaxTypedLabelLength) {
      _notice =
          'That is longer than I can check here. Paste just the allergen '
          'statement.';
      _notify();
      return;
    }
    final token = _begin();
    final caps = await _loadCapabilities(token);
    if (caps == null) return;
    final task = _typedTask(trimmed);
    if (!_fitsLocalModel(caps, task)) {
      _finish(
        token,
        notice:
            "This device's on-device model can't check typed labels, so "
            'nothing was sent. $kReadItYourselfWording',
      );
      return;
    }
    await _send(token, task, LabelSource.typed);
  }

  /// After [checkPhoto] offered the choice: asks the cook to let this one
  /// photo go to the cloud, then sends it only with a grant for that payload
  /// and session, and only if privacy and routing still allow it.
  Future<void> sendPhotoToCloud() async {
    final gate = consentGate;
    final photo = _pendingPhoto;
    if (_closed ||
        gate == null ||
        photo == null ||
        _phase != LabelCheckPhase.awaitingChoice) {
      return;
    }
    final token = _current();
    final blocked = _cloudBlockReason();
    if (blocked != null) {
      _notice = routeReasonSentence(blocked);
      _notify();
      return;
    }
    final task = _photoTask(photo);
    final digest = labelPayloadDigest(task);
    _phase = LabelCheckPhase.awaitingConsent;
    _notice = null;
    _notify();
    ConsentGrant? grant;
    try {
      grant = await gate.request(
        ConsentAsk(
          feature: kLabelCheckFeature,
          kinds: const {DataKind.image, DataKind.text},
          payloadDigest: digest,
          sessionId: token.sessionId,
        ),
      );
    } catch (_) {
      grant = null;
    }
    // Closed, session changed or another check started: nothing is sent.
    if (!_isCurrent(token)) return;
    if (grant == null) {
      _phase = LabelCheckPhase.awaitingChoice;
      _notice = 'OK — that photo stays on this device.';
      _notify();
      return;
    }
    final ask = grant.ask;
    if (ask.feature != kLabelCheckFeature ||
        ask.sessionId != token.sessionId ||
        ask.payloadDigest != digest ||
        !ask.kinds.contains(DataKind.image)) {
      _phase = LabelCheckPhase.awaitingChoice;
      _notice =
          'That permission was for a different photo, so nothing was sent.';
      _notify();
      return;
    }
    await _send(token, task, LabelSource.photo, grant: grant);
  }

  /// Forgets the photo waiting for a choice.
  void discardPhoto() {
    if (_closed || _phase != LabelCheckPhase.awaitingChoice) return;
    _begin();
    _notify();
  }

  /// The cooking or pantry session changed: drop everything from the old one.
  void setSession(String sessionId) {
    if (sessionId == _sessionId) return;
    _sessionId = sessionId;
    _begin();
    _notify();
  }

  /// The sheet closed. Cancels the running check; nothing after this is
  /// applied or sent.
  void close() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _operation?.cancel();
    _operation = null;
    _pendingPhoto = null;
  }

  @override
  void dispose() {
    close();
    _disposed = true;
    household.removeListener(_notify);
    final p = privacy;
    if (p is Listenable) (p as Listenable).removeListener(_notify);
    super.dispose();
  }

  // ---- internals --------------------------------------------------------------

  /// Starts a new check: cancels the previous one and clears its state.
  _Token _begin() {
    _operation?.cancel();
    _operation = null;
    _epoch++;
    _phase = LabelCheckPhase.idle;
    _result = null;
    _legs = const [];
    _blocked = null;
    _notice = null;
    _pendingPhoto = null;
    _typedRunsHere = false;
    return _current();
  }

  _Token _current() => _Token(_epoch, _sessionId);

  bool _isCurrent(_Token token) =>
      !_closed && token.epoch == _epoch && token.sessionId == _sessionId;

  Future<HybridCapabilities?> _loadCapabilities(_Token token) async {
    _phase = LabelCheckPhase.preparing;
    _notify();
    HybridCapabilities caps;
    try {
      caps = await _capabilities();
    } catch (_) {
      caps = const HybridCapabilities.none();
    }
    if (!_isCurrent(token)) return null;
    _localModelFamily = caps.local?.modelFamily;
    return caps;
  }

  /// Uploads are blocked by, in the dispatcher's order: the cook's setting for
  /// this feature, the build's approved routes, connectivity.
  RouteReason? _cloudBlockReason() {
    if (privacy.localOnly(kLabelCheckFeature)) {
      return RouteReason.localOnlySetting;
    }
    if (!cloudRoutes.allows(CloudRoute.hybridFallback)) {
      return RouteReason.cloudNotApproved;
    }
    if (!_isOnline()) return RouteReason.offline;
    return null;
  }

  Future<void> _send(
    _Token token,
    HybridTask task,
    LabelSource source, {
    ConsentGrant? grant,
  }) async {
    if (!_isCurrent(token)) return;
    if (grant != null) {
      // Privacy, routes and connectivity are read again, immediately before
      // the upload, never from a value captured before the prompt.
      final blocked = _cloudBlockReason();
      if (blocked != null) {
        _finish(
          token,
          notice: '${routeReasonSentence(blocked)} Nothing was sent.',
          phase: LabelCheckPhase.awaitingChoice,
        );
        return;
      }
    }
    final operation = _dispatch(task, token.sessionId, grant: grant);
    _operation = operation;
    _pendingPhoto = null;
    _phase = LabelCheckPhase.checking;
    _notice = null;
    _notify();
    DispatchResult outcome;
    try {
      outcome = await operation.result;
    } catch (_) {
      if (_isCurrent(token) && identical(_operation, operation)) {
        _operation = null;
        _finish(
          token,
          notice: "I couldn't check that label. $kReadItYourselfWording",
        );
      }
      return;
    }
    if (!_isCurrent(token) || !identical(_operation, operation)) return;
    _operation = null;
    _legs = List.unmodifiable(outcome.legs);
    final text = outcome.text;
    if (text != null) {
      _result = LabelCheckResult(
        reading: parseLabelReading(text),
        legs: _legs,
        source: source,
      );
      _finish(token);
      return;
    }
    _blocked = outcome.blocked;
    _finish(
      token,
      notice: outcome.blocked == null
          ? "I couldn't check that label. $kReadItYourselfWording"
          : '${routeReasonSentence(outcome.blocked!)} $kReadItYourselfWording',
    );
  }

  /// The only call into the dispatcher. When `HybridDispatcher.start` gains
  /// `ConsentGrant? grant` (PR #186), pass `grant: grant` here so the
  /// dispatcher uses this grant instead of asking its own ConsentGate again.
  HybridOperation _dispatch(
    HybridTask task,
    String sessionId, {
    ConsentGrant? grant,
  }) => dispatcher.start(task, sessionId: sessionId);

  void _finish(
    _Token token, {
    String? notice,
    LabelCheckPhase phase = LabelCheckPhase.done,
  }) {
    if (!_isCurrent(token)) return;
    _phase = phase;
    _notice = notice;
    _notify();
  }

  HybridTask _photoTask(Uint8List jpeg) => HybridTask(
    feature: kLabelCheckFeature,
    systemInstruction: kLabelSystemInstruction,
    parts: [
      HybridText(buildPhotoPrompt()),
      HybridInlineData(jpeg, 'image/jpeg'),
    ],
    jsonSchema: kLabelSchema,
    maxOutputTokens: 160,
    timeout: requestTimeout,
  );

  HybridTask _typedTask(String text) => HybridTask(
    feature: kLabelCheckFeature,
    systemInstruction: kLabelSystemInstruction,
    parts: [HybridText(buildTypedPrompt(text))],
    jsonSchema: kLabelSchema,
    maxOutputTokens: 160,
    timeout: requestTimeout,
  );

  /// Whether the dispatcher's policy would run [task] on this device rather
  /// than needing the cloud: a local model that takes `onlyOnDevice`, reads
  /// images if there is one, and has room for the request (DESIGN.md §4
  /// token budget). Language support is the dispatcher's check.
  bool _fitsLocalModel(HybridCapabilities caps, HybridTask task) {
    final local = caps.local;
    if (local == null ||
        !caps.supportedModes.contains(HybridMode.onlyOnDevice)) {
      return false;
    }
    if (task.hasImage && !local.supportsImage) return false;
    return _estimateTokens(task, local.imageTokenEstimate) <=
        local.maxTotalTokens;
  }

  /// A typed label of the longest accepted length fits.
  bool _typedFitsLocalModel(HybridCapabilities caps) =>
      _fitsLocalModel(caps, _typedTask('x' * kMaxTypedLabelLength));

  static int _estimateTokens(HybridTask task, int imageTokenEstimate) {
    var chars = task.systemInstruction?.length ?? 0;
    var images = 0;
    for (final p in task.parts) {
      if (p is HybridText) chars += p.text.length;
      if (p is HybridInlineData && p.mimeType.startsWith('image/')) images++;
    }
    // Same measure as the dispatcher's `estimateLocalTokens`.
    final schema = task.jsonSchema;
    if (schema != null) chars += jsonEncode(schema).length;
    return (chars / 4).ceil() +
        images * imageTokenEstimate +
        task.maxOutputTokens;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

class _Token {
  const _Token(this.epoch, this.sessionId);
  final int epoch;
  final String sessionId;
}
