import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai/cooking_research_client.dart';
import '../research/cooking_research_panel.dart';
import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart';
import '../app/cloud_send_recorder.dart';
import '../app/hybrid_controls.dart';
import '../app/hybrid_runtime.dart';
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
import 'demo_live.dart';
import 'draft_recipe_chip.dart';
import 'dinner_review.dart';
import 'meal_complete.dart';

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

  /// Shared hybrid inference services (real builds). Null in rehearsal.
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

  /// Shared hybrid inference services. Null in rehearsal and in tests that
  /// build their own coordinator.
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
@visibleForTesting
WatchService buildWatchService(
  HybridRuntime hybrid,
  LiveCookingController live,
) {
  late final LocalWatchController local;
  local = LocalWatchController(
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
    local: local,
    startLiveWatch: live.startWatch,
    stopLiveWatch: live.stopWatch,
    localVisionSupported: () async =>
        (await hybrid.inference.capabilities()).local?.supportsImage ?? false,
  );
}

/// Owns a cooking session's lifetime; a new cook gets a fresh screen and coordinator.
class _CookingScreenState extends State<CookingScreen> {
  late CookingCoordinator _cook;
  bool _initialized = false;
  bool _startingNewCook = false;

  CookingCoordinator _createCoordinator() {
    final custom = widget.createCoordinator?.call();
    if (custom != null) return custom;
    final hybrid = widget.isDemo ? null : widget.hybrid;
    return CookingCoordinator(
      services: widget.services,
      isDemo: widget.isDemo,
      recipe: widget.recipe,
      research: widget.isDemo
          ? FakeCookingResearchClient()
          : GeminiCookingResearchClient(recorder: hybrid?.cloudSends),
      transportFactory: ledgeredLiveFactory(
        isDemo: widget.isDemo,
        hybrid: hybrid,
      ),
      media: widget.isDemo ? DemoLiveMedia() : createLiveMedia(),
      coachLite: hybrid == null
          ? null
          : CoachLite(
              dispatcher: hybrid.dispatcher,
              privacy: hybrid.privacy,
              cloudRoutes: hybrid.cloudRoutes,
              isOnline: hybrid.isOnline,
            ),
      // Rehearsal keeps the Live-only watch: no local watch on DemoLiveMedia.
      watchServiceFactory: hybrid == null
          ? null
          : (live) => buildWatchService(hybrid, live),
      onSessionReady: hybrid?.bindCookingSession,
      researchAllowed: hybrid == null
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
    hybrid: widget.isDemo ? null : widget.hybrid,
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
  final _message = TextEditingController();
  final _dinnerAttempts = DinnerAttemptMemory();
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
  String _prediction = 'Not sure';
  String? _announcedAlert;
  bool _messagePending = false;

  /// Coach Lite read-aloud; only where Coach Lite exists (SS-077).
  CoachLiteSpeaker? _speaker;

  late final KitchenMode _kitchen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cook = widget.cook;
    // Screen stays on while this session is cooking; Big text (SS-107).
    _kitchen = KitchenModeScope.createFor(context)
      ..followSession(cook, () => cook.session != null && !cook.complete);
    unawaited(_kitchen.load());
    if (cook.coachLite != null) {
      final privacy = widget.hybrid?.privacy;
      _speaker = CoachLiteSpeaker(
        (widget.textToSpeech ?? deviceTextToSpeech)(),
        // Read at every speak: local-only allows only a local voice.
        localOnly: () =>
            privacy != null && localOnlyFor(privacy, coachLiteFeature),
      );
      unawaited(_speaker!.init());
    }
    cook.addListener(_onChange);
    if (!widget.initialized) unawaited(cook.initialize());
  }

  void _onChange() {
    if (!mounted) return;
    _speaker?.sync(
      answer: cook.coachLiteAnswer,
      busy: cook.coachLiteBusy,
      liveActive: cook.live.isActive,
      stepId: cook.step.id,
    );
    if (cook.session?.id case final id?) _label?.setSession(id);
    if (cook.alert == null) _announcedAlert = null;
    if (cook.alert != null && cook.alert != _announcedAlert) {
      _announcedAlert = cook.alert;
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
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1320),
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
                        child: _header(),
                      ),
                    ),
                    if (widget.isDemo)
                      SliverToBoxAdapter(
                        child: _banner(
                          'Rehearsal mode · Camera, voice, and AI responses are simulated. No messages are sent.',
                          Icons.science_outlined,
                        ),
                      ),
                    if (cook.loading)
                      const SliverFillRemaining(
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
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
              if (!cook.loading) _controlDock(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _header() => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 24,
    runSpacing: 12,
    children: [
      if (widget.onBackToPantry case final back?)
        TextButton.icon(
          key: const ValueKey('back-to-pantry'),
          onPressed: () {
            unawaited(cook.live.stop());
            back();
          },
          icon: const Icon(Icons.arrow_back),
          label: const Text('Back to pantry'),
        ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: const Color(0xff285b43),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.soup_kitchen_outlined,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          const Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SousSight',
                  style: TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
                Text(
                  'A little guidance. A lot more confidence.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xffe4ebdf),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            widget.isDemo
                ? 'Interactive rehearsal'
                : 'Your live cooking companion',
          ),
        ),
      ),
      TextButton.icon(
        key: const ValueKey('new-cook'),
        onPressed: cook.loading ? null : widget.onNewCook,
        icon: const Icon(Icons.restart_alt),
        label: Text(widget.startingNewCook ? 'Starting…' : 'New cook'),
      ),
      DraftRecipeChip(recipe: cook.recipe),
      AllergenChip(recipe: cook.recipe),
      if (widget.hybrid case final hybrid?)
        HybridHeaderButtons(
          hybrid: hybrid,
          onLabel: cook.session == null ? null : () => _openLabel(hybrid),
        ),
      HowItWorksButton(isDemo: widget.isDemo),
    ],
  );

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
      const Text(
        'LET’S MAKE SOMETHING GOOD',
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 2,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 10),
      Text(
        cook.recipe.title,
        style: const TextStyle(
          fontSize: 32,
          height: 1.12,
          letterSpacing: -1,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Show your ingredients. Talk through the tricky parts. Cook at your pace.',
        style: TextStyle(fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 20),
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
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(24, 70, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.soup_kitchen_outlined,
                        size: 76,
                        color: Color(0xffefce98),
                      ),
                      SizedBox(height: 18),
                      Text(
                        'Your counter is the canvas',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        'Connect your camera and microphone\nso we can cook together.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xffc8d8c9), height: 1.5),
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
                        ? 'SIMULATED'
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
        _inlineNotice(error, Icons.cloud_off_outlined),
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
                              ? 'Rehearsal on'
                              : 'Rehearsal ready')
                        : (cook.live.isActive
                              ? _liveLabel
                              : cook.watchService?.captureLabel ??
                                    (cook.liveEnabled
                                        ? 'Camera and microphone off'
                                        : 'Live coach is off in this build · '
                                              'type a question for Coach Lite')),
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
                        ? 'Ask Coach Lite (on-device)…'
                        : 'Ask the coach…',
                    suffixIcon: IconButton(
                      onPressed: _messagePending ? null : _send,
                      icon: const Icon(Icons.arrow_upward_rounded),
                      tooltip: 'Send message',
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: () {
                  final question = _message.text.trim();
                  if (question.isNotEmpty) {
                    unawaited(cook.researchQuestionNow(question));
                  } else {
                    _message.text = 'What should I look for during this step?';
                  }
                },
                icon: const Icon(Icons.travel_explore),
                tooltip: 'Research a cooking question',
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
          onTextHousehold: _reviewDinner,
          onCookSomethingElse: switch (widget.onBackToPantry) {
            final back? => () {
              unawaited(cook.live.stop());
              back();
            },
            null => widget.onNewCook,
          },
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
          KitchenBigTextToggle(mode: _kitchen),
          const SizedBox(width: 12),
          Text(
            '${cook.stepIndex + 1} / ${cook.recipe.steps.length}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
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
        _inlineNotice(error, Icons.error_outline),
      if (cook.alert case final alert?)
        Semantics(
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
      if (cook.coachLiteBusy)
        Semantics(
          liveRegion: true,
          child: _inlineNotice(
            'Coach Lite is thinking…',
            Icons.hourglass_top_outlined,
          ),
        ),
      CookingSurface(controller: cook.ui),
      if (cook.coachLiteAnswer != null)
        if (_speaker case final speaker?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: CoachLiteSpeakerToggle(speaker: speaker),
          ),
      if (cook.coachLiteAnswer case final answer?)
        CoachLiteAnswerFooter(
          answer: answer,
          onStartTimer: (label, seconds) =>
              unawaited(cook.startSuggestedTimer(label, seconds)),
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
              selected: _prediction == prediction,
              onSelected: (_) => setState(() => _prediction = prediction),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: () => cook.checkNow(_prediction),
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
              const Expanded(
                child: Text(
                  'Call everyone to the table.\nReview a dinner-ready message before sending.',
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

  Future<void> _reviewDinner() => _reviewHousehold(DinnerKind.ready);

  /// Opt-in "started cooking" text; opens the same review, never auto-sends.
  Future<void> _reviewStarted() => _reviewHousehold(DinnerKind.started);

  Future<void> _reviewHousehold(DinnerKind kind) async {
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
    );
  }
}
