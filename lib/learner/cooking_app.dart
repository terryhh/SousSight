import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../ai/cooking_research_client.dart';
import '../research/cooking_research_panel.dart';
import '../app/services_scope.dart';
import '../data/dinner_messages.dart';
import '../data/live_token_provider.dart';
import '../genui/cooking_ui.dart';
import '../live/browser_live_media.dart';
import '../live/ephemeral_live_transport.dart';
import '../live/live_controller.dart';
import 'cooking_coordinator.dart';
import 'demo_live.dart';

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
  const CookingApp({super.key, required this.services, this.isDemo = false});
  final AppServices services;
  final bool isDemo;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SousSight',
    debugShowCheckedModeBanner: false,
    theme: cookingTheme,
    home: CookingScreen(services: services, isDemo: isDemo),
  );
}

typedef DinnerMessageSender = Future<DinnerMessageResult> Function({
  required String sessionId,
  required String notificationId,
  required String recipient,
  required String message,
  bool demo,
});

class CookingScreen extends StatefulWidget {
  const CookingScreen({
    super.key,
    required this.services,
    required this.isDemo,
    this.createCoordinator,
    this.sendDinner = sendDinnerMessage,
  });
  final AppServices services;
  final bool isDemo;
  final CookingCoordinator Function()? createCoordinator;
  final DinnerMessageSender sendDinner;
  @override
  State<CookingScreen> createState() => _CookingScreenState();
}

class _CookingScreenState extends State<CookingScreen>
    with WidgetsBindingObserver {
  late final CookingCoordinator cook;
  final _message = TextEditingController();
  final _notificationId = const Uuid().v4();
  String _prediction = 'Not sure';
  String? _announcedAlert;
  bool _messagePending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cook =
        widget.createCoordinator?.call() ??
        CookingCoordinator(
          services: widget.services,
          isDemo: widget.isDemo,
          research: widget.isDemo
              ? FakeCookingResearchClient()
              : GeminiCookingResearchClient(),
          transportFactory: widget.isDemo
              ? DemoLiveTransport.new
              : () =>
                    EphemeralGeminiLiveTransport(tokenProvider: fetchLiveToken),
          media: widget.isDemo ? DemoLiveMedia() : createBrowserLiveMedia(),
        );
    cook.addListener(_onChange);
    unawaited(cook.initialize());
  }

  void _onChange() {
    if (!mounted) return;
    if (cook.alert == null) _announcedAlert = null;
    if (cook.alert != null && cook.alert != _announcedAlert) {
      _announcedAlert = cook.alert;
      if (cook.alert == 'Dinner-ready draft is ready to review.') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_reviewDinner());
        });
      }
      if (cook.alert!.startsWith('Check your bowl:') ||
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
    }
    if (state == AppLifecycleState.resumed) cook.ui.refreshTimers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cook.removeListener(_onChange);
    cook.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_messagePending || _message.text.trim().isEmpty) return;
    setState(() => _messagePending = true);
    final text = _message.text;
    try {
      await cook.say(text);
      if (cook.live.isActive) _message.clear();
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
                        final right = _workspace();
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
      ),
    ),
  );

  Widget _header() => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 24,
    runSpacing: 12,
    children: [
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
    ],
  );

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
            if (cook.live.latestFrame case final frame?)
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
                        : 'CAMERA OFF',
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
          FilledButton.icon(
            onPressed: cook.live.status == LiveCookingStatus.connecting
                ? null
                : () => cook.live.isActive ? cook.live.stop() : cook.connect(),
            icon: Icon(
              cook.live.isActive ? Icons.stop_rounded : Icons.videocam_outlined,
            ),
            label: Text(
              cook.live.isActive
                  ? 'End live session'
                  : widget.isDemo
                  ? 'Start rehearsal'
                  : 'Cook with me',
            ),
          ),
          if (cook.live.isActive)
            OutlinedButton.icon(
              onPressed: () =>
                  cook.live.setMicrophoneMuted(!cook.live.microphoneMuted),
              icon: Icon(
                cook.live.microphoneMuted
                    ? Icons.mic_off_outlined
                    : Icons.mic_none,
              ),
              label: Text(cook.live.microphoneMuted ? 'Unmute' : 'Mute'),
            ),
          OutlinedButton.icon(
            onPressed: cook.live.watchGoal == null
                ? cook.startWatch
                : cook.stopWatch,
            icon: const Icon(Icons.visibility_outlined),
            label: Text(
              cook.live.watchGoal == null ? 'Watch my bowl' : 'Pause watch',
            ),
          ),
        ],
      ),
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
      const SizedBox(height: 16),
      TextField(
        controller: _message,
        minLines: 1,
        maxLines: 4,
        maxLength: 1000,
        onSubmitted: (_) => _send(),
        decoration: InputDecoration(
          counterText: '',
          hintText: cook.cookQuestion == null
              ? 'Ask a cooking question…'
              : 'Your answer to the coach…',
          suffixIcon: IconButton(
            onPressed: _messagePending ? null : _send,
            icon: const Icon(Icons.arrow_upward_rounded),
            tooltip: 'Send message',
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: () {
          final question = _message.text.trim();
          if (question.isNotEmpty) {
            unawaited(cook.researchQuestionNow(question));
          } else {
            _message.text =
                'Can I use vinegar instead of lemon in this recipe?';
          }
        },
        icon: const Icon(Icons.travel_explore, size: 18),
        label: const Text('Research a cooking question'),
      ),
    ],
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
      const SizedBox(height: 12),
      LinearProgressIndicator(
        value:
            (cook.session?.completedStepIds.length ?? 0) /
            cook.recipe.steps.length,
        borderRadius: BorderRadius.circular(8),
        minHeight: 5,
      ),
      const SizedBox(height: 16),
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
      CookingSurface(controller: cook.ui),
      const SizedBox(height: 16),
      const Text(
        'What do you think of your bowl?',
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
            label: const Text('Check my bowl'),
          ),
          OutlinedButton.icon(
            onPressed: cook.startStepTimer,
            icon: const Icon(Icons.timer_outlined),
            label: Text(
              cook.step.timerSeconds == null
                  ? '1-minute timer'
                  : 'Start ${cook.step.timerSeconds! ~/ 60}-minute timer',
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

  Future<void> _reviewDinner() async {
    final recipient = TextEditingController();
    final message = TextEditingController(
      text: cook.dinnerDraft ?? 'Dinner is ready! Come join me.',
    );
    bool sending = false;
    String? result;
    String? validationError;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Dinner is ready'),
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Choose your configured household contact and review the exact message.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: recipient,
                  enabled: !sending && result == null,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Recipient',
                    hintText: '+14075550123',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: message,
                  enabled: !sending && result == null,
                  maxLines: 3,
                  maxLength: 320,
                  decoration: const InputDecoration(labelText: 'Message'),
                ),
                if (validationError != null) Text(validationError!),
                if (result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(result!),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: sending ? null : () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: sending || result != null
                  ? null
                  : () async {
                      // Guard the callback too: two taps can arrive before the
                      // disabled button has rebuilt.
                      if (sending || result != null) return;
                      if (!RegExp(r'^\+?[1-9][0-9]{7,14}$')
                              .hasMatch(recipient.text.trim()) ||
                          message.text.trim().isEmpty) {
                        update(
                          () => validationError = 'Enter a full international phone number and a message.',
                        );
                        return;
                      }
                      update(() {
                        sending = true;
                        validationError = null;
                      });
                      try {
                        final response = await widget.sendDinner(
                          sessionId: cook.session!.id,
                          notificationId: _notificationId,
                          recipient: recipient.text.trim(),
                          message: message.text.trim(),
                          demo: widget.isDemo,
                        );
                        if (context.mounted) {
                          update(() => result = response.explanation);
                        }
                      } catch (_) {
                        if (context.mounted) {
                          update(
                            () => result = 'Message status could not be confirmed. No automatic resend will occur.',
                          );
                        }
                      } finally {
                        if (context.mounted) update(() => sending = false);
                      }
                    },
              child: Text(widget.isDemo ? 'Rehearse send' : 'Confirm and send'),
            ),
          ],
        ),
      ),
    );
    recipient.dispose();
    message.dispose();
  }
}
