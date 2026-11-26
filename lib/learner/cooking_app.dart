import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show OnDeviceStatus;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai/cooking_research_client.dart';
import '../research/cooking_research_panel.dart';
import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart';
import '../app/cloud_send_recorder.dart';
import '../app/centered_scroll.dart';
import '../app/hybrid_controls.dart';
import '../app/hybrid_runtime.dart';
import '../app/rehearsal_runtime.dart';
import '../app/services_scope.dart';
import '../coach_lite/coach_lite.dart';
import '../coach_lite/coach_lite_answer_card.dart';
import '../coach_lite/tts.dart';
import '../coach_lite/tts_toggle.dart';
import '../data/dinner_messages.dart';
import '../data/dinner_mode.dart';
import '../data/dinner_status.dart';
import '../data/offline_ops_banner.dart';
import '../genui/cooking_ui.dart';
import '../kitchen/kitchen_mode.dart';
import '../kitchen/kitchen_text.dart';
import '../live/live_media_factory.dart';
import '../live/live_backend.dart';
import '../live/live_controller.dart';
import '../live/live_types.dart';
import '../label/label_check_controller.dart';
import '../label/label_check_sheet.dart';
import '../trust/inference_source_badge.dart';
import '../trust/privacy_receipt_card.dart' show PrivacyReceiptBinding;
import '../watch/capture_owner.dart';
import '../watch/local_watch_controller.dart';
import '../watch/local_watch_overlay.dart';
import '../watch/watch_service.dart';
import '../core/analytics.dart';
import '../core/models.dart';
import '../pantry/pantry_flow.dart';
import '../app/how_it_works.dart';
import 'allergen_chip.dart';
import 'cooking_coordinator.dart';
import 'draft_recipe_chip.dart';
import 'dinner_review.dart';
import 'meal_complete.dart';
import 'plain_research_text.dart';
import 'recipe_notes.dart';

final cookingTheme = ThemeData(
  useMaterial3: true,
  materialTapTargetSize: MaterialTapTargetSize.padded,
  visualDensity: VisualDensity.standard,
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
  ),
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff285b43),
    primary: const Color(0xff285b43),
    secondary: const Color(0xffbf5b32),
    surface: const Color(0xfffffdf8),
  ),
  scaffoldBackgroundColor: const Color(0xfff5f1e8),
  cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
  ),
);

class CookingApp extends StatelessWidget {
  const CookingApp({
    super.key,
    required this.services,
    this.isDemo = false,
    this.pantryFirst = false,
    this.initialRecipeId,
    this.hybrid,
  });
  final AppServices services;
  final bool isDemo;

  /// Opens "What did you get from the pantry?" before cooking. A valid
  /// [initialRecipeId] deep link skips straight to that recipe.
  final bool pantryFirst;
  final String? initialRecipeId;

  /// Shared hybrid inference services. In rehearsal, the practice-mode
  /// runtime (scripted, labelled "Practice mode (pretend answers)").
  final HybridRuntime? hybrid;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SousSight',
    debugShowCheckedModeBanner: false,
    theme: cookingTheme,
    // The consent dialog opens on this navigator.
    navigatorKey: hybrid?.navigatorKey,
    home: pantryFirst
        ? PantryFlow(
            services: services,
            isDemo: isDemo,
            initialRecipeId: initialRecipeId,
            hybrid: hybrid,
          )
        : CookingScreen(services: services, isDemo: isDemo, hybrid: hybrid),
  );
}

/// Logs `household_message_sent` only when Vonage accepted the message
/// (`submitted`); failed, skipped and unknown results are not sends.
@visibleForTesting
void trackHouseholdSend(
  Analytics analytics,
  DinnerMessageRequest request,
  DinnerMessageResult result,
) {
  if (result.status != 'submitted') return;
  analytics.log(AnalyticsEvents.householdMessageSent, {
    'kind': request.kind.name,
    'simulated': result.simulated ? 1 : 0,
  });
}

class CookingScreen extends StatefulWidget {
  const CookingScreen({
    super.key,
    required this.services,
    required this.isDemo,
    this.createCoordinator,
    this.sendDinner,
    this.dinnerStatus,
    this.recipe,
    this.onBackToPantry,
    this.hybrid,
    this.textToSpeech,
  });
  final AppServices services;
  final bool isDemo;

  /// Coach Lite read-aloud voice; defaults to the device's (SS-077).
  final TextToSpeech Function()? textToSpeech;

  /// Shared hybrid inference services (the practice-mode runtime in
  /// rehearsal). Null in tests that build their own coordinator.
  final HybridRuntime? hybrid;

  /// The recipe chosen at runtime; defaults to the bundled build-time recipe.
  final Recipe? recipe;
  final VoidCallback? onBackToPantry;
  final CookingCoordinator Function()? createCoordinator;

  /// Defaults: the real endpoint and Firestore mirror, or a visibly simulated
  /// backend in demo builds.
  final DinnerMessageSender? sendDinner;
  final DinnerStatusSource? dinnerStatus;
  @override
  State<CookingScreen> createState() => _CookingScreenState();
}

/// The Live transport for this build, wrapped so each connect attempt and each
/// resume is exactly one leg in the session ledger. The AI Logic transport
/// (SS-074) opens its legs through its guard (`recordCloudLeg`), right before
/// each socket opens; [LedgeredLiveTransport] settles them. Rehearsal (no
/// runtime) is left as is. [build] replaces [liveTransportFactory] in tests.
@visibleForTesting
LiveTransportFactory? ledgeredLiveFactory({
  required bool isDemo,
  HybridRuntime? hybrid,
  bool selfRecording = kLiveAiLogic,
  LiveTransportFactory? Function(LiveLegRecorder? recordCloudLeg)? build,
}) {
  LiveTransportFactory? make(LiveLegRecorder? record) => build != null
      ? build(record)
      : liveTransportFactory(
          isDemo: isDemo,
          cloudRoutes: hybrid?.cloudRoutes,
          privacy: hybrid?.privacy,
          recordCloudLeg: record,
        );
  if (isDemo || hybrid == null) return make(null);
  if (make(null) == null) return null; // no Live coach in this build
  return () {
    final legs = LiveLegTracker(hybrid.cloudSends);
    return LedgeredLiveTransport(
      make(legs.admitted)!(),
      legs,
      selfRecording: selfRecording,
    );
  };
}

/// The one "Watch my food" service for a cooking session: an on-device watch
/// over a camera-only capture of [live]'s media, or the Live watch when Live
/// is connected (SS-067).
/// [liveAvailable] is false in builds without the Live coach, so refusals
/// never point to it; [simulated] labels practice mode (SS-089).
@visibleForTesting
WatchService buildWatchService(
  HybridRuntime hybrid,
  LiveCookingController live, {
  bool liveAvailable = true,
  bool simulated = false,
}) {
  late final LocalWatchController local;
  local = LocalWatchController(
    liveAvailable: liveAvailable,
    simulated: simulated,
    dispatcher: hybrid.dispatcher,
    capture: CaptureOwner(live.media),
    // The "Ask the cloud about this photo" offer exists only when the build
    // approves cloud help; the prompt shows the exact frame.
    consentGate: hybrid.cloudRoutes.allows(CloudRoute.hybridFallback)
        ? FramePreviewConsentGate(
            hybrid.consent,
            () => local.consentFrame?.bytes,
          )
        : null,
    privacy: hybrid.privacy,
  );
  return WatchService(
    liveAvailable: liveAvailable,
    simulated: simulated,
    local: local,
    startLiveWatch: live.startWatch,
    stopLiveWatch: live.stopWatch,
    // Decide before any "watching" state (SS-089): the model must take
    // photos and be ready now, or the watch is refused up front.
    localVisionSupported: () async {
      final local = (await hybrid.inference.capabilities()).local;
      if (local == null || !local.supportsImage) return false;
      final image = await hybrid.inference.availability(withImage: true);
      return image.status == OnDeviceStatus.available;
    },
  );
}

/// Per runtime, the ledger generation each meal's session was bound on,
/// recorded in the same call that bound it (SS-105).
final _mealLedgerGenerations = Expando<Map<String, int>>(
  'meal ledger generations',
);

/// A coordinator's `onSessionReady` for a hybrid build: binds the runtime's
/// ledger to the session with [bind] (default `bindCookingSession`) and, in
/// the same call, records the generation the meal starts on. The privacy
/// receipt prints only while the ledger is still on it, however late the
/// cooking screen subscribes. A bind that did not take records nothing.
void Function(String sessionId) bindMealSession(
  HybridRuntime hybrid, [
  void Function(String sessionId)? bind,
]) => (sessionId) {
  (bind ?? hybrid.bindCookingSession)(sessionId);
  if (hybrid.sessionId != sessionId) return;
  (_mealLedgerGenerations[hybrid] ??= {})[sessionId] = hybrid.ledger.generation;
};

/// Owns a cooking session's lifetime; a new cook gets a fresh screen and coordinator.
class _CookingScreenState extends State<CookingScreen> {
  late CookingCoordinator _cook;
  bool _initialized = false;
  bool _startingNewCook = false;

  CookingCoordinator _createCoordinator() {
    final custom = widget.createCoordinator?.call();
    if (custom != null) return custom;
    // Rehearsal gets the practice-mode runtime: Coach Lite, the local watch
    // (over a drawn practice camera) and the trust sheets all run, labelled
    // as pretend. Research and Live stay simulated as before.
    final hybrid = widget.hybrid;
    final transport = ledgeredLiveFactory(
      isDemo: widget.isDemo,
      hybrid: widget.isDemo ? null : hybrid,
    );
    return CookingCoordinator(
      services: widget.services,
      isDemo: widget.isDemo,
      recipe: widget.recipe,
      // Answers arrive as plain text: the panel shows Markdown raw (G2c).
      research: PlainTextResearchClient(
        widget.isDemo
            ? FakeCookingResearchClient()
            : GeminiCookingResearchClient(recorder: hybrid?.cloudSends),
      ),
      transportFactory: transport,
      media: widget.isDemo
          ? RehearsalLiveMedia(
              onCameraStart: switch (hybrid?.inference) {
                final RehearsalHybridInference practice => practice.newWatch,
                _ => null,
              },
            )
          : createLiveMedia(),
      coachLite: hybrid == null
          ? null
          : CoachLite(
              dispatcher: hybrid.dispatcher,
              privacy: hybrid.privacy,
              cloudRoutes: hybrid.cloudRoutes,
              isOnline: hybrid.isOnline,
            ),
      watchServiceFactory: hybrid == null
          ? null
          : (live) => buildWatchService(
              hybrid,
              live,
              liveAvailable: transport != null,
              simulated: widget.isDemo || isPracticeRuntime(hybrid),
            ),
      onSessionReady: hybrid == null ? null : bindMealSession(hybrid),
      // Rehearsal research is the simulated client; nothing is sent.
      researchAllowed: hybrid == null || widget.isDemo
          ? null
          : () => hybrid.cloudRoutes.allows(CloudRoute.research),
      isOnline: hybrid?.isOnline,
    );
  }

  @override
  void initState() {
    super.initState();
    _cook = _createCoordinator();
  }

  Future<void> _newCook() async {
    if (_startingNewCook) return;
    setState(() => _startingNewCook = true);
    CookingCoordinator? candidate;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start a new cook?'),
          scrollable: true,
          content: const Text(
            'Your current cook stays saved. The new cook starts with an empty '
            'checklist and fresh progress. Camera, microphone and watches will '
            'stop, and the current timer workspace will close.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep cooking'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Start new cook'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      candidate = _createCoordinator();
      await candidate.initialize(startNew: true);
      if (!mounted) return;
      if (candidate.session == null || candidate.error != null) {
        throw StateError('New session was not ready.');
      }
      // Creation failure must leave the old cook usable. Only after a new
      // session exists do we stop capture and retire the old async/UI boundary.
      final previous = _cook;
      // Disposing retires the old research epoch, timers and watches, and its
      // live controller synchronously stops capture and the transport. Only
      // socket cleanup continues asynchronously; never block the new cook on
      // a slow close.
      previous.dispose();
      if (!mounted) return;
      setState(() {
        _cook = candidate!;
        candidate = null;
        _initialized = true;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not start a new cook. Your current cook is still available. Try again.',
            ),
          ),
        );
      }
    } finally {
      candidate?.dispose();
      if (mounted) setState(() => _startingNewCook = false);
    }
  }

  @override
  Widget build(BuildContext context) => _CookingSessionScreen(
    key: ObjectKey(_cook),
    services: widget.services,
    isDemo: widget.isDemo,
    cook: _cook,
    initialized: _initialized,
    onNewCook: _startingNewCook ? null : _newCook,
    onBackToPantry: widget.onBackToPantry,
    startingNewCook: _startingNewCook,
    sendDinner: widget.sendDinner,
    dinnerStatus: widget.dinnerStatus,
    hybrid: widget.hybrid,
    textToSpeech: widget.textToSpeech,
  );

  @override
  void dispose() {
    _cook.dispose();
    super.dispose();
  }
}

class _CookingSessionScreen extends StatefulWidget {
  const _CookingSessionScreen({
    super.key,
    required this.services,
    required this.isDemo,
    required this.cook,
    required this.initialized,
    required this.onNewCook,
    this.onBackToPantry,
    required this.startingNewCook,
    required this.sendDinner,
    required this.dinnerStatus,
    this.hybrid,
    this.textToSpeech,
  });
  final HybridRuntime? hybrid;
  final TextToSpeech Function()? textToSpeech;
  final AppServices services;
  final bool isDemo;
  final CookingCoordinator cook;
  final bool initialized;
  final VoidCallback? onNewCook;
  final VoidCallback? onBackToPantry;
  final bool startingNewCook;
  final DinnerMessageSender? sendDinner;
  final DinnerStatusSource? dinnerStatus;

  @override
  State<_CookingSessionScreen> createState() => _CookingSessionScreenState();
}

class _CookingSessionScreenState extends State<_CookingSessionScreen>
    with WidgetsBindingObserver {
  late final CookingCoordinator cook;

  /// Tonight's privacy receipt binding, bound to the generation recorded by
  /// [bindMealSession] when this meal's session was bound, and kept
  /// here, outside the layout, so a retired receipt stays retired across
  /// breakpoint rebuilds. Null (no receipt) until the meal is complete and
  /// the ledger is known to be this meal's.
  PrivacyReceiptBinding? _receipt;
  PrivacyReceiptBinding? _receiptBinding() {
    final hybrid = widget.hybrid;
    final meal = switch (cook.session?.id) {
      final id? when hybrid != null => _mealLedgerGenerations[hybrid]?[id],
      _ => null,
    };
    if (hybrid == null || meal == null || !cook.complete) return null;
    return _receipt ??= PrivacyReceiptBinding(
      generation: () => hybrid.ledger.generation,
      expected: meal,
      clock: cook.services.clock,
    );
  }

  /// Screen wake lock and Big text for this session (SS-107).
  late final KitchenMode _kitchen;
  final _message = TextEditingController();
  final _dinnerAttempts = DinnerAttemptMemory();
  final _dinnerTimers = DinnerTimerMemory();
  final _fakeDinner = FakeDinnerBackend();
  late final DinnerMessageSender _deliverDinner =
      widget.sendDinner ??
      dinnerSenderFor(
        configuredDinnerMode,
        isDemo: widget.isDemo,
        fake: _fakeDinner,
      );

  /// Counts only sends Vonage accepted (`submitted`) in real, non-demo
  /// builds. Simulated sends never reached a provider and are not counted.
  Future<DinnerMessageResult> _sendDinner(DinnerMessageRequest request) async {
    final result = await _deliverDinner(request);
    if (dinnerAnalyticsEnabled(configuredDinnerMode, isDemo: widget.isDemo)) {
      trackHouseholdSend(widget.services.analytics, request, result);
    }
    return result;
  }

  late final DinnerStatusSource _dinnerStatus =
      widget.dinnerStatus ??
      dinnerStatusFor(
        configuredDinnerMode,
        isDemo: widget.isDemo,
        fake: _fakeDinner,
      );

  /// Nothing is preselected: the cook says how it looks (SS-089).
  String? _prediction;

  /// The step [_prediction] was chosen on; a new step clears it (Codex #221).
  String? _predictionStep;
  String? _announcedAlert;
  bool _messagePending = false;

  /// Coach Lite read-aloud; only where Coach Lite exists (SS-077).
  CoachLiteSpeaker? _speaker;

  /// Rehearsal / practice mode: nothing may leave the browser, voice
  /// included.
  bool get _practice => widget.isDemo || isPracticeRuntime(widget.hybrid);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cook = widget.cook;
    _dinnerTimers.attach(cook.ui);
    // Screen stays on while this session is cooking; Big text (SS-107).
    _kitchen = KitchenModeScope.createFor(context)
      ..followSession(cook, () => cook.session != null && !cook.complete);
    unawaited(_kitchen.load());
    if (cook.coachLite != null) {
      final privacy = widget.hybrid?.privacy;
      _speaker = CoachLiteSpeaker(
        (widget.textToSpeech ?? deviceTextToSpeech)(),
        // Read at every speak: local-only allows only a local voice. Practice
        // mode is always local-only: a pretend answer and the echoed typed
        // question never go to an online voice service (Codex #221).
        localOnly: () =>
            _practice ||
            (privacy != null && localOnlyFor(privacy, coachLiteFeature)),
      );
      unawaited(_speaker!.init());
    }
    cook.addListener(_onChange);
    if (!widget.initialized) unawaited(cook.initialize());
  }

  /// Anchors that [_reveal] scrolls into view when something new appears,
  /// so replies and alerts never land under the fold or the dock (SS-089).
  final _alertKey = GlobalKey(debugLabel: 'cooking-alert');
  final _replyKey = GlobalKey(debugLabel: 'coach-reply');
  final _errorKey = GlobalKey(debugLabel: 'cooking-error');
  final _researchKey = GlobalKey(debugLabel: 'research-panel');
  final _transcriptKey = GlobalKey(debugLabel: 'live-transcript');
  int _shownTurns = 0;
  int _revealedTranscript = 0;
  final _liveErrorKey = GlobalKey(debugLabel: 'live-error');
  String? _shownLiveError;
  Object? _shownReply;
  String? _shownError;
  Object? _shownResearch;
  bool _wasResearching = false;

  /// Scrolls [key]'s widget near the top of the cooking scroll view after the
  /// next frame. Instant when the platform asks for reduced motion.
  void _reveal(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = key.currentContext;
      if (!mounted || target == null || !target.mounted) return;
      final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.05,
          duration: still ? Duration.zero : const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _revealChanges() {
    // A new typed question (busy) or its answer.
    final reply = cook.coachLiteBusy
        ? ('busy', cook.coachLiteQuestion)
        : cook.coachLiteAnswer?.stamp;
    if (reply != null && reply != _shownReply) _reveal(_replyKey);
    _shownReply = reply;
    if (cook.error != null && cook.error != _shownError) _reveal(_errorKey);
    _shownError = cook.error;
    // A new research panel, and again when its sources arrive (G2c).
    final panel = cook.researchPanel;
    if (panel != null &&
        (!identical(panel, _shownResearch) ||
            (_wasResearching && !cook.researching))) {
      _reveal(_researchKey);
    }
    _shownResearch = panel;
    // A finished Live reply, once per completed turn (typed or spoken),
    // never on a partial transcript (Codex #221).
    if (cook.live.completedTurns != _shownTurns) {
      _shownTurns = cook.live.completedTurns;
      // Only a turn that brought new reply text (Codex #221).
      if (cook.live.coachTranscriptVersion != _revealedTranscript &&
          cook.live.coachTranscript.isNotEmpty) {
        _revealedTranscript = cook.live.coachTranscriptVersion;
        _reveal(_transcriptKey);
      }
    }
    // A Live failure (e.g. camera permission denied) is shown in view.
    if (cook.live.error != null && cook.live.error != _shownLiveError) {
      _reveal(_liveErrorKey);
    }
    _shownLiveError = cook.live.error;
    _wasResearching = cook.researching;
  }

  void _onChange() {
    if (!mounted) return;
    // Bind the receipt at the completion event itself (SS-105).
    _receiptBinding();
    _speaker?.sync(
      answer: cook.coachLiteAnswer,
      busy: cook.coachLiteBusy,
      liveActive: cook.live.isActive,
      stepId: cook.step.id,
    );
    if (cook.session?.id case final id?) _label?.setSession(id);
    _revealChanges();
    if (cook.alert == null) _announcedAlert = null;
    if (cook.alert != null && cook.alert != _announcedAlert) {
      _announcedAlert = cook.alert;
      _reveal(_alertKey);
      if (cook.alert == 'Dinner-ready draft is ready to review.') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_reviewDinner());
        });
      }
      if (cook.alert!.startsWith('Check your food:') ||
          cook.alert!.contains('time is up')) {
        _chime();
      }
    }
    setState(() {});
  }

  void _chime() {
    if (!cook.live.isActive) return;
    final pcm = ByteData(12000);
    for (var i = 0; i < 6000; i++) {
      final envelope = math.sin(math.pi * i / 6000);
      pcm.setInt16(
        i * 2,
        (9000 * envelope * math.sin(2 * math.pi * 880 * i / 24000)).round(),
        Endian.little,
      );
    }
    cook.live.media.playAudio(pcm.buffer.asUint8List());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      unawaited(cook.live.stop());
      cook.watchService?.onBackgrounded();
      _speaker?.setForeground(false);
    }
    if (state == AppLifecycleState.resumed) {
      cook.ui.refreshTimers();
      _speaker?.setForeground(true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cook.removeListener(_onChange);
    _dinnerTimers.detach();
    _kitchen.dispose();
    _speaker?.dispose();
    _message.dispose();
    unawaited(_fakeDinner.dispose());
    super.dispose();
  }

  Future<void> _send() async {
    if (_messagePending || _message.text.trim().isEmpty) return;
    setState(() => _messagePending = true);
    final text = _message.text;
    try {
      final accepted = await cook.say(text);
      if (accepted && mounted) _message.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save that answer. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _messagePending = false);
    }
  }

  @override
  // The scroll view spans the window; content is centred inside it (max
  // 1320 px) so the wheel works over the side margins on desktop (SS-089).
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, outer) {
          final extra = centeredSide(outer.maxWidth, maxWidth: 1320);
          return Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  key: const ValueKey('cooking-scroll'),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          extra + (_compact ? 16 : 24),
                          _compact ? 10 : 22,
                          extra + (_compact ? 16 : 24),
                          _compact ? 6 : 14,
                        ),
                        child: _header(),
                      ),
                    ),
                    if (widget.isDemo)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: extra),
                          child: _banner(
                            'Practice mode (pretend answers) · No real camera, '
                            'microphone or AI is used, and no messages are '
                            'sent.',
                            Icons.science_outlined,
                          ),
                        ),
                      ),
                    if (cook.loading)
                      const SliverFillRemaining(
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          extra + (_compact ? 16 : 24),
                          8,
                          extra + (_compact ? 16 : 24),
                          32,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final narrow = constraints.maxWidth < 850;
                              final left = _cameraColumn(
                                includeConversation: !narrow,
                              );
                              final right = KitchenBigText(
                                mode: _kitchen,
                                child: _workspace(),
                              );
                              if (narrow) {
                                return Column(
                                  children: [
                                    left,
                                    const SizedBox(height: 24),
                                    right,
                                    const SizedBox(height: 24),
                                    _conversation(),
                                  ],
                                );
                              }
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 11, child: left),
                                  const SizedBox(width: 28),
                                  Expanded(flex: 10, child: right),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (!cook.loading)
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1320),
                    child: _controlDock(),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );

  /// Phone-width layout: a tighter header and camera card (SS-089).
  bool get _compact => MediaQuery.sizeOf(context).width < 600;

  /// Two deliberate rows (SS-089): brand and navigation, then the tools
  /// (chips and labelled buttons), which wrap as a group. About 110 px less
  /// than before on phones, and no accidental wrap on desktop.
  Widget _header() {
    final compact = _compact;
    final back = widget.onBackToPantry;
    void goBack() {
      unawaited(cook.live.stop());
      back!();
    }

    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.all(compact ? 8 : 11),
          decoration: BoxDecoration(
            color: const Color(0xff285b43),
            borderRadius: BorderRadius.circular(compact ? 12 : 16),
          ),
          child: Icon(
            Icons.soup_kitchen_outlined,
            color: Colors.white,
            size: compact ? 22 : 26,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'SousSight',
                style: TextStyle(
                  fontSize: compact ? 22 : 27,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
              if (!compact)
                const Text(
                  'A little guidance. A lot more confidence.',
                  style: TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    );
    final hybrid = widget.hybrid;
    return Column(
      key: const ValueKey('cooking-header'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (back != null) ...[
              if (compact)
                IconButton(
                  key: const ValueKey('back-to-pantry'),
                  onPressed: goBack,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back to pantry',
                )
              else
                TextButton.icon(
                  key: const ValueKey('back-to-pantry'),
                  onPressed: goBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back to pantry'),
                ),
              SizedBox(width: compact ? 2 : 16),
            ],
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: brand),
            ),
            HowItWorksButton(isDemo: widget.isDemo),
          ],
        ),
        SizedBox(height: compact ? 4 : 10),
        Wrap(
          key: const ValueKey('cooking-header-tools'),
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              key: const ValueKey('new-cook'),
              onPressed: cook.loading ? null : widget.onNewCook,
              icon: const Icon(Icons.restart_alt),
              label: Text(widget.startingNewCook ? 'Starting…' : 'New cook'),
            ),
            DraftRecipeChip(recipe: cook.recipe, practice: widget.isDemo),
            AllergenChip(recipe: cook.recipe),
            if (hybrid != null)
              HybridHeaderButtons(
                hybrid: hybrid,
                onLabel: cook.session == null ? null : () => _openLabel(hybrid),
              ),
          ],
        ),
      ],
    );
  }

  /// The open label check, told when the cooking session changes under it.
  LabelCheckController? _label;

  Future<void> _openLabel(HybridRuntime hybrid) async {
    final sessionId = cook.session?.id;
    if (sessionId == null) return;
    final controller = hybrid.labelCheck(sessionId);
    _label = controller;
    try {
      await showLabelCheckSheet(
        context,
        controller: controller,
        takePhoto: _labelPhoto,
      );
    } finally {
      if (identical(_label, controller)) _label = null;
    }
  }

  /// One label photo. While Live holds the camera, its latest frame (already
  /// shared with Live); otherwise a camera-only capture through the
  /// session's CaptureOwner, released straight after.
  Future<Uint8List?> _labelPhoto() async {
    if (cook.live.isActive) return cook.live.latestFrame;
    final service = cook.watchService;
    if (service == null) return null;
    final capture = service.capture;
    Future<Uint8List?> nextFrame() => capture.media.timedFrames
        .skip(2)
        .first
        .then<Uint8List?>((frame) => frame.bytes)
        .timeout(const Duration(seconds: 8), onTimeout: () => null);
    if (capture.mode == CaptureMode.localCamera) return nextFrame();
    CaptureLease? lease;
    try {
      lease = await capture.acquireLocalCamera();
      if (lease == null) return null;
      final bytes = await nextFrame();
      return capture.isCurrent(lease) ? bytes : null;
    } catch (_) {
      return null;
    } finally {
      if (lease != null && capture.isCurrent(lease)) await capture.release();
    }
  }

  /// Which ledger legs belong to the local watch running now.
  final _watchLegs = WatchLegScope();

  /// The privacy chip, viewfinder and status over the camera preview while
  /// a local watch shows it. Null when Live owns the preview or no local
  /// watch is running. Upload wording comes from this watch's ledger legs.
  Widget? _localWatchOverlay() {
    if (cook.live.isActive) return null;
    final local = cook.watchService?.local;
    if (local == null) return null;
    final ledger = widget.hybrid?.ledgerSource;
    // Snapshot the ledger as soon as a watch is seen, before its first frame.
    if (ledger != null) {
      _watchLegs.begin(local.isActive ? local.watchId : null, ledger.legs);
    }
    // A local watch only exists with the hybrid runtime, so its ledger.
    if (local.previewFrame == null || ledger == null) return null;
    return ListenableBuilder(
      listenable: ledger,
      builder: (context, _) =>
          LocalWatchOverlay.of(
            local,
            ledgerLegs: ledger.legs,
            scope: _watchLegs,
          ) ??
          const SizedBox.shrink(),
    );
  }

  Widget _cameraColumn({bool includeConversation = true}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!_compact) ...[
        const Text(
          'LET’S MAKE SOMETHING GOOD',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 2,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
      ],
      Text(
        cook.recipe.title,
        style: TextStyle(
          fontSize: _compact ? 26 : 32,
          height: 1.12,
          letterSpacing: -1,
          fontWeight: FontWeight.w700,
        ),
      ),
      if (!_compact) ...[
        const SizedBox(height: 10),
        const Text(
          'Show your ingredients. Talk through the tricky parts. Cook at your pace.',
          style: TextStyle(fontSize: 15, height: 1.5),
        ),
      ],
      SizedBox(height: _compact ? 12 : 20),
      ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Stack(
          children: [
            if (cook.live.latestFrame ?? cook.watchService?.local.previewFrame
                case final frame?)
              AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.memory(
                  frame,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              )
            else
              Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xff214937), Color(0xff102d24)],
                  ),
                ),
                child: Padding(
                  padding: _compact
                      ? const EdgeInsets.fromLTRB(20, 52, 20, 18)
                      : const EdgeInsets.fromLTRB(24, 70, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.soup_kitchen_outlined,
                        size: _compact ? 52 : 76,
                        color: const Color(0xffefce98),
                      ),
                      SizedBox(height: _compact ? 10 : 18),
                      const Text(
                        'Your counter is the canvas',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        widget.isDemo
                            ? 'Practice mode: no real camera. Tap Watch my '
                                  'food to try a pretend watch.'
                            : cook.liveEnabled
                            ? 'Connect your camera and microphone\nso we can '
                                  'cook together.'
                            : 'Your camera stays off until you tap Watch my '
                                  'food.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xffc8d8c9),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_localWatchOverlay() case final overlay?)
              Positioned.fill(child: overlay),
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    widget.isDemo
                        ? 'PRACTICE MODE'
                        : cook.live.isActive
                        ? _liveLabel
                        : (cook.watchService?.captureLabel?.toUpperCase() ??
                              'CAMERA OFF'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('watch-toggle'),
            onPressed: cook.watching
                ? cook.stopWatch
                : () => unawaited(cook.startWatch()),
            icon: const Icon(Icons.visibility_outlined),
            label: Text(cook.watching ? 'Pause watch' : 'Watch my food'),
          ),
          if (cook.watchService?.local case final local?
              when local.canRequestCloudCheck)
            TextButton.icon(
              key: const ValueKey('watch-cloud-check'),
              onPressed: () => unawaited(local.requestCloudCheck()),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Ask the cloud about this photo'),
            ),
        ],
      ),
      if (cook.watchService?.statusText case final status?)
        Semantics(
          liveRegion: true,
          child:
              watchStatusNotice(cook.watchService!) ??
              _inlineNotice(status, Icons.visibility_outlined),
        ),
      if (cook.watchService?.local.verdict?.legs case final legs?
          when legs.isNotEmpty)
        InferenceSourceBadge(legs: legs),
      if (cook.live.error case final error?)
        KeyedSubtree(
          key: _liveErrorKey,
          child: _inlineNotice(error, Icons.cloud_off_outlined),
        ),
      if (cook.live.notice case final notice?)
        _inlineNotice(notice, Icons.info_outline),
      if (includeConversation) _conversation(),
    ],
  );

  Widget _conversation() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (cook.live.coachTranscript.isNotEmpty)
        Padding(
          key: _transcriptKey,
          padding: const EdgeInsets.only(top: 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'SOUSSIGHT',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      key: const ValueKey('coach-caption-scroll'),
                      child: Text(
                        cook.live.coachTranscript,
                        style: const TextStyle(height: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget _controlDock() => Material(
    key: const ValueKey('cooking-control-dock'),
    color: Theme.of(context).colorScheme.surface,
    elevation: 8,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pinned with Stop so the cost warning stays visible while cooking.
          if (cook.live.sessionWarning case final warning?)
            Row(
              children: [
                const Icon(Icons.hourglass_bottom, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(warning)),
                if (cook.live.canExtendSession)
                  TextButton(
                    key: const ValueKey('extend-live-session'),
                    onPressed: cook.live.extendSession,
                    child: Text(
                      'Keep going (+${cook.live.sessionExtension.inMinutes} min)',
                    ),
                  ),
              ],
            ),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    !cook.live.isActive &&
                            cook.live.notice == liveCostPauseMessage
                        ? liveCostPauseMessage
                        : widget.isDemo
                        ? (cook.live.isActive
                              ? 'Practice mode on'
                              : cook.watchService?.captureLabel ??
                                    'Practice mode ready')
                        : (cook.live.isActive
                              ? _liveLabel
                              : cook.watchService?.captureLabel ??
                                    (cook.liveEnabled
                                        ? 'Camera and microphone off'
                                        : cook.coachLite != null
                                        ? 'Type a question below.'
                                        : 'Follow the steps below; your '
                                              'timers still work.')),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (cook.live.isActive)
                IconButton(
                  key: const ValueKey('microphone-toggle'),
                  onPressed: () =>
                      cook.live.setMicrophoneMuted(!cook.live.microphoneMuted),
                  icon: Icon(
                    cook.live.microphoneMuted
                        ? Icons.mic_off_outlined
                        : Icons.mic_none,
                  ),
                  tooltip: cook.live.microphoneMuted
                      ? 'Unmute microphone'
                      : 'Mute microphone',
                ),
              if (cook.liveEnabled)
                Tooltip(
                  message: cook.live.isActive
                      ? 'End live session'
                      : (widget.isDemo ? 'Start rehearsal' : 'Cook with me'),
                  child: FilledButton.icon(
                    key: const ValueKey('live-session-toggle'),
                    onPressed: () =>
                        cook.live.isActive ? cook.live.stop() : cook.connect(),
                    icon: Icon(
                      cook.live.isActive
                          ? Icons.stop_rounded
                          : Icons.videocam_outlined,
                    ),
                    label: Text(cook.live.isActive ? 'Stop' : 'Start'),
                  ),
                ),
            ],
          ),
          if (cook.researching) const _CheckingSources(),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('cooking-message-input'),
                  controller: _message,
                  minLines: 1,
                  maxLines: 2,
                  maxLength: 1000,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: cook.cookQuestion != null
                        ? 'Your answer…'
                        : !cook.live.isActive && cook.coachLite != null
                        ? 'Ask a question…'
                        : 'Ask the coach…',
                  ),
                ),
              ),
              // A sibling of the field, not its suffix, so the field's
              // accessible name and the button's are each said once.
              _DockButton(
                key: const ValueKey('send-message'),
                label: 'Send message',
                icon: Icons.arrow_upward_rounded,
                onPressed: _messagePending ? null : _send,
              ),
              _DockButton(
                key: const ValueKey('research-question'),
                label: 'Research a cooking question',
                icon: Icons.travel_explore,
                onPressed: () {
                  final question = _message.text.trim();
                  if (question.isNotEmpty) {
                    unawaited(cook.researchQuestionNow(question));
                  } else {
                    _message.text = 'What should I look for during this step?';
                  }
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );

  String get _liveLabel => switch (cook.live.status) {
    LiveCookingStatus.speaking => 'COACH SPEAKING',
    LiveCookingStatus.connecting => 'CONNECTING',
    LiveCookingStatus.reconnecting => 'RECONNECTING',
    _ =>
      cook.live.microphoneMuted
          ? 'CAMERA ON · MIC MUTED'
          : 'LISTENING & LOOKING',
  };

  Widget _workspace() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (cook.complete) ...[
        MealCompletePanel(
          cook: cook,
          isDemo: widget.isDemo,
          // The same guarded, ledger-backed client as the pantry (Codex #221).
          nearbyClient: switch ((widget.isDemo, widget.hybrid)) {
            (false, final hybrid?) => hybridNearbyClient(hybrid),
            _ => null,
          },
          onTextHousehold: _reviewDinner,
          onCookSomethingElse: switch (widget.onBackToPantry) {
            final back? => () {
              unawaited(cook.live.stop());
              back();
            },
            null => widget.onNewCook,
          },
          ledger: widget.hybrid?.ledgerSource,
          receiptBinding: _receiptBinding(),
        ),
        const SizedBox(height: 24),
      ],
      Row(
        children: [
          const Expanded(
            child: Text(
              'Your cooking space',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 21),
            ),
          ),
          Text(
            '${cook.stepIndex + 1} / ${cook.recipe.steps.length}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: KitchenBigTextToggle(mode: _kitchen),
      ),
      const SizedBox(height: 12),
      LinearProgressIndicator(
        value:
            (cook.session?.completedStepIds.length ?? 0) /
            cook.recipe.steps.length,
        borderRadius: BorderRadius.circular(8),
        minHeight: 5,
      ),
      const SizedBox(height: 16),
      if (cook.offline) OfflineBanner(pendingSteps: cook.pendingStepSaves),
      if (cook.error case final error?)
        KeyedSubtree(
          key: _errorKey,
          child: Semantics(
            liveRegion: true,
            child: _inlineNotice(error, Icons.error_outline),
          ),
        ),
      if (cook.alert case final alert?)
        Semantics(
          key: _alertKey,
          liveRegion: true,
          child: Card(
            color: const Color(0xfffbe8c9),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.notifications_active_outlined),
                  const SizedBox(width: 10),
                  Expanded(child: Text(alert)),
                  IconButton(
                    onPressed: cook.clearAlert,
                    icon: const Icon(Icons.close),
                    tooltip: 'Dismiss',
                  ),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: 10),
      // The reply region: a typed question's "thinking" line, then why it
      // ran where it did (or why there is no answer); the workspace the
      // answer fills follows. [_reveal] scrolls to the region's top, which is
      // kept short so it always lands in view.
      KeyedSubtree(
        key: _replyKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cook.coachLiteBusy)
              Semantics(
                liveRegion: true,
                child: _inlineNotice(switch (cook.coachLiteQuestion) {
                  final q? when q.isNotEmpty =>
                    'Thinking about “${q.length > 80 ? '${q.substring(0, 79)}…' : q}”…',
                  _ => 'Thinking about your question…',
                }, Icons.hourglass_top_outlined),
              ),
            if (cook.coachLiteAnswer case final answer?)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: CoachLiteAnswerFooter(
                  answer: answer,
                  question: cook.coachLiteQuestion,
                  recipeNotes: recipeNotesFor(
                    cook.coachLiteQuestion ?? '',
                    cook.recipe,
                    cook.step,
                  ),
                  recipeNotesLabel: recipeNotesLabel(cook.recipe),
                  onStartTimer: (label, seconds) =>
                      unawaited(cook.startSuggestedTimer(label, seconds)),
                ),
              ),
          ],
        ),
      ),
      CookingSurface(controller: cook.ui),
      if (cook.coachLiteAnswer != null)
        if (_speaker case final speaker?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: CoachLiteSpeakerToggle(
              speaker: speaker,
              practice: _practice,
            ),
          ),
      const SizedBox(height: 16),
      const Text(
        'How does your food look?',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (final prediction in ['Ready', 'Not yet', 'Not sure'])
            ChoiceChip(
              label: Text(prediction),
              selected:
                  _predictionStep == cook.step.id && _prediction == prediction,
              onSelected: (_) => setState(() {
                _prediction = prediction;
                _predictionStep = cook.step.id;
              }),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: () => cook.checkNow(
              _predictionStep == cook.step.id ? _prediction : null,
            ),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Check my food'),
          ),
          if (cook.step.timerSeconds != null && cook.step.timerSeconds! > 0)
            OutlinedButton.icon(
              onPressed: cook.startStepTimer,
              icon: const Icon(Icons.timer_outlined),
              label: Text(
                cook.step.timerSeconds! % 60 == 0
                    ? 'Start ${cook.step.timerSeconds! ~/ 60}-minute timer'
                    : 'Start ${cook.step.timerSeconds}-second timer',
              ),
            ),
          TextButton(
            onPressed: cook.advancing || cook.complete
                ? null
                : cook.advanceStep,
            child: Text(
              cook.stepIndex == cook.recipe.steps.length - 1
                  ? 'Finish cooking'
                  : 'Next step →',
            ),
          ),
          TextButton(
            onPressed: cook.showIngredients,
            child: const Text('Ingredients'),
          ),
        ],
      ),
      if (cook.researchPanel case final panel?)
        Padding(
          key: _researchKey,
          padding: const EdgeInsets.only(top: 20),
          child: CookingResearchPanel(
            key: ObjectKey(panel),
            client: panel.client,
            query: panel.query,
            onCookConfirmed: (fact) =>
                unawaited(cook.confirmResearchFact(panel, fact)),
            onOpenSource: (citation) => unawaited(
              launchUrl(citation.uri, mode: LaunchMode.externalApplication),
            ),
          ),
        ),
      const SizedBox(height: 24),
      Card(
        color: const Color(0xffe4ebdf),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.sms_outlined),
              const SizedBox(width: 12),
              Expanded(
                // Matches the message the button opens (SS-100).
                child: Text(
                  _dinnerDraft().kind == DinnerKind.ready
                      ? 'Call everyone to the table.\nReview a dinner-ready message before sending.'
                      : "Let everyone know dinner's started.\nReview a household message before sending.",
                  key: const Key('dinner-card-copy'),
                ),
              ),
              IconButton(
                onPressed: _reviewDinner,
                icon: const Icon(Icons.arrow_forward),
                tooltip: 'Review dinner message',
              ),
            ],
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _reviewStarted,
          icon: const Icon(Icons.outdoor_grill_outlined),
          label: const Text('Text household: started cooking'),
        ),
      ),
    ],
  );

  Widget _inlineNotice(String text, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );

  Widget _banner(String text, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: _inlineNotice(text, icon),
  );

  /// "Started" or "ready" from the cook's step, with a time estimate (SS-100).
  DinnerDraft _dinnerDraft() => dinnerDraftFor(
    steps: cook.recipe.steps,
    currentStepId: cook.session?.currentStepId,
    complete: cook.complete,
    now: cook.services.clock(),
    timers: cook.ui.timers,
    pastTimers: _dinnerTimers.pastTimers,
    finishedStepIds: cook.session?.finishedTimerStepIds ?? const [],
  );

  Future<void> _reviewDinner() {
    final draft = _dinnerDraft();
    return _reviewHousehold(draft.kind, initialMinutes: draft.minutes);
  }

  /// Opt-in "started cooking" text; opens the same review, never auto-sends.
  Future<void> _reviewStarted() => _reviewHousehold(
    DinnerKind.started,
    initialMinutes: _dinnerDraft().minutes,
  );

  Future<void> _reviewHousehold(DinnerKind kind, {int? initialMinutes}) async {
    final session = cook.session;
    if (session == null) return;
    await showDinnerReview(
      context,
      kind: kind,
      sessionId: session.id,
      recipeTitle: cook.recipe.title,
      send: _sendDinner,
      statusSource: _dinnerStatus,
      mode: configuredDinnerMode,
      memory: _dinnerAttempts,
      isDemo: widget.isDemo,
      initialMinutes: initialMinutes,
    );
  }
}

/// A dock icon button whose accessible name is [label], said once: the
/// tooltip is visual only and the button carries the semantics label.
class _DockButton extends StatelessWidget {
  const _DockButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    excludeSemantics: true,
    onTap: onPressed,
    child: Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: IconButton(onPressed: onPressed, icon: Icon(icon)),
    ),
  );
}

/// Shown in the dock, where the cook tapped "Research a cooking question",
/// while sources are being checked (G2c). A still icon under reduced motion.
class _CheckingSources extends StatelessWidget {
  const _CheckingSources();

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      liveRegion: true,
      child: Padding(
        key: const ValueKey('research-checking'),
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: still
                  ? const Icon(Icons.travel_explore, size: 18)
                  : const CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Checking sources… the answer will appear in your cooking '
                'space.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
