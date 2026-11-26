import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart' show InferenceLeg;
import '../app/centered_scroll.dart';
import '../app/how_it_works.dart';
import '../core/models.dart';
import '../learner/draft_recipe_chip.dart';
import '../live/live_types.dart';
import '../nearby/nearby_client.dart';
import '../nearby/nearby_sheet.dart';
import 'pantry_client.dart';
import 'pantry_handoff.dart';
import 'pantry_models.dart';
import 'pantry_ui.dart';
import 'recipe_draft.dart';
import 'wav.dart';

enum PantryMode { scan, say, type }

typedef PantryRecipeChosen = void Function(
  Recipe recipe,
  PantryHandoff handoff,
);

/// Plain words, no promises about what this device can do (SS-089): each
/// result's badge says where it actually ran.
const pantryPrivacyLine =
    "Each result shows whether it was worked out on this device or sent "
    "online to Google's AI. Photos and voice clips aren't stored. When you "
    'start cooking, the items you confirmed and your answer are saved with '
    'your cooking session.';

/// Items found that no suggested meal uses, so nothing the cook typed is
/// silently dropped (SS-089). Empty when there are no meals.
List<String> pantryUnusedItems(PantryResult result) {
  if (result.meals.isEmpty) return const [];
  return [
    for (final item in result.items)
      if (!result.meals.any(
        (meal) => meal.matched.any((m) => pantryNamesMatch(item.name, m)),
      ))
        item.name,
  ];
}

/// Shown beside Record: voice clips can't be understood on this device.
/// Says only what Record needs (Codex #221): no promise about other paths.
const pantryVoiceDisclosure =
    'Voice lists need online processing: when you tap Find my meal, the clip '
    "is sent to Google's AI. Leaving Say it deletes the clip.";

/// Said when a recorded clip is dropped because voice went off before send.
const pantryVoiceSkipped =
    'Your voice clip was skipped: online processing is off in this build.';

/// The same, in a build where online processing is off.
const pantryVoiceUnavailable =
    'Voice lists need online processing and a connection, which aren\'t '
    'available right now (off in this build or offline). Type your list '
    'instead.';

/// The catch-all when matching failed without a reason of its own.
const pantryUnavailableMessage =
    "Matching your food didn't work just now — no answer came back. Pick a "
    'recipe below, or try again.';

/// "What did you get from the pantry?" The cook shows, says, or types their
/// haul; one Gemini call suggests bundled recipes; the cook confirms and picks.
class PantryScreen extends StatefulWidget {
  const PantryScreen({
    super.key,
    required this.recipes,
    required this.client,
    required this.onChooseRecipe,
    this.draftClient,
    this.isDemo = false,
    this.mediaFactory,
    this.recordDuration = const Duration(seconds: 6),
    this.nearbyClient,
    this.locate,
    this.openLink,
    this.header,
    this.headerActions,
    this.unavailableReason,
    this.voiceOnline,
  });

  /// Whether this build can process a voice clip online. Null when unknown
  /// (the disclosure then states what Record needs without availability).

  final List<Recipe> recipes;
  final PantryClient client;
  final PantryRecipeChosen onChooseRecipe;

  /// Drafts an unreviewed recipe from confirmed items (SS-053). When null,
  /// the draft actions are hidden.
  final RecipeDraftClient? draftClient;
  final bool isDemo;

  /// Browser camera + microphone bridge. Not used in rehearsal mode.
  final LiveMedia Function()? mediaFactory;
  final Duration recordDuration;

  /// Grounding with Google Maps search. Defaults to the rehearsal client in
  /// demo mode; real mode needs a gated client (`nearbyClientFor`). Without
  /// one, or when this build does not approve the nearby route, the nearby
  /// entry points are hidden.
  final NearbyClient? nearbyClient;

  /// One-time location lookup; defaults to browser geolocation (real mode)
  /// or a simulated Orlando position (rehearsal mode).
  final NearbyLocator? locate;
  final NearbyLinkOpener? openLink;

  /// Shown under the brand row (for example the readiness panel).
  final Widget? header;

  /// Labelled buttons under the brand row (On this device, What we sent,
  /// Check a label).
  final Widget? headerActions;

  /// Why AI help can't run here, in plain words, or null when it can or
  /// nobody knows. Read when matching fails without a reason (SS-089).
  final Future<String?> Function()? unavailableReason;
  final bool Function()? voiceOnline;

  @override
  State<PantryScreen> createState() => _PantryScreenState();
}

class _PantryScreenState extends State<PantryScreen> {
  late final NearbyClient? _nearby =
      widget.nearbyClient ?? (widget.isDemo ? const FakeNearbyClient() : null);
  late final PantryUiController _ui = PantryUiController(
    onChooseMeal: _chooseById,
    onFindMissing: nearbyOffered(_nearby)
        ? (missing) =>
              unawaited(_openNearby(NearbyKind.groceries, missing: missing))
        : null,
  );
  final _text = TextEditingController();
  final _answer = TextEditingController();
  PantryMode _mode = PantryMode.type;
  LiveMedia? _media;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _mediaStarting = false;
  // Bumped whenever capture is stopped so a slow start (for example a pending
  // permission prompt) can never activate the camera after the cook left.
  int _mediaEpoch = 0;
  LiveMedia? _pendingMedia;
  Uint8List? _preview;
  Uint8List? _photo;
  Uint8List? _audio;
  bool _simulatedPhoto = false;
  bool _simulatedAudio = false;
  BytesBuilder? _recording;
  Timer? _recordTimer;
  double _recordProgress = 0;
  bool _thinking = false;
  String? _error;
  List<InferenceLeg> _errorLegs = const [];

  /// True only when [_error] came from matching (not the camera or mic), so
  /// the "no answer came back" source line appears only there (Codex #221).
  bool _matchError = false;
  PantryResult? _result;
  bool _drafting = false;
  final _resultsKey = GlobalKey(debugLabel: 'pantry-results');
  final _errorKey = GlobalKey(debugLabel: 'pantry-error');

  /// Scrolls [key]'s widget into view after the next frame, instantly when
  /// the platform asks for reduced motion.
  void _reveal(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = key.currentContext;
      if (!mounted || target == null || !target.mounted) return;
      final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.05,
          duration: still ? Duration.zero : const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  String? _draftError;
  Recipe? _drafted;
  List<InferenceLeg> _draftLegs = const [];
  int _draftEpoch = 0;

  @override
  void dispose() {
    _recordTimer?.cancel();
    unawaited(_stopMedia());
    _ui.dispose();
    _text.dispose();
    _answer.dispose();
    super.dispose();
  }

  // ---- media ---------------------------------------------------------------

  /// Whether the running capture includes the microphone.
  bool _mediaHasMic = false;

  /// Scan needs only the camera; Record asks for the microphone too
  /// (Codex #221). A camera-only capture is restarted with the microphone
  /// when Record needs it.
  Future<bool> _ensureMedia({bool microphone = false}) async {
    if (_media != null && (!microphone || _mediaHasMic)) return true;
    if (_media != null) await _stopMedia();
    final factory = widget.mediaFactory;
    if (factory == null || _mediaStarting) return false;
    setState(() => _mediaStarting = true);
    final media = factory();
    final epoch = _mediaEpoch;
    _pendingMedia = media;
    try {
      _subscriptions.addAll([
        if (microphone)
          media.frames.listen((frame) {
            if (mounted) setState(() => _preview = frame);
          })
        else
          media.timedFrames.listen((frame) {
            if (mounted) setState(() => _preview = frame.bytes);
          }),
        if (microphone)
          media.microphone.listen((chunk) => _recording?.add(chunk)),
        media.errors.listen((message) {
          if (!mounted) return;
          setState(() {
            _error = message;
            _matchError = false;
            _media = null;
          });
        }),
      ]);
      await (microphone ? media.start() : media.startCameraOnly());
      if (!mounted || epoch != _mediaEpoch) {
        await media.stop();
        return false;
      }
      _media = media;
      _mediaHasMic = microphone;
      return true;
    } catch (_) {
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      unawaited(media.stop());
      if (mounted) {
        setState(() {
          _error = 'Camera or microphone is blocked. Allow access in the browser, or type your list instead.';
          _matchError = false;
          _mode = PantryMode.type;
        });
      }
      return false;
    } finally {
      if (identical(_pendingMedia, media)) _pendingMedia = null;
      if (mounted) setState(() => _mediaStarting = false);
    }
  }

  Future<void> _stopMedia() async {
    _mediaEpoch++;
    final pending = _pendingMedia;
    _pendingMedia = null;
    if (pending != null && !identical(pending, _media)) {
      unawaited(pending.stop());
    }
    _recordTimer?.cancel();
    _recording = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final media = _media;
    _media = null;
    _mediaHasMic = false;
    _preview = null;
    await media?.stop();
  }

  /// Read live at render, at Record and at send (Codex #221).
  bool get _voiceOff => widget.voiceOnline?.call() == false;

  /// Shown once a clip was dropped at send because voice went off.
  String? _voiceSkipped;

  /// Bumped by every mode switch; an older switch's work stops after any
  /// await once this has moved on (Codex #221).
  int _modeEpoch = 0;

  Future<void> _selectMode(PantryMode mode) async {
    final changed = mode != _mode;
    final epoch = ++_modeEpoch;
    setState(() {
      // A clip never rides along unseen: leaving Say it deletes it.
      if (mode != PantryMode.say) {
        _recordTimer?.cancel();
        _recording = null;
        _recordProgress = 0;
        _audio = null;
        _simulatedAudio = false;
      }
      _mode = mode;
      _error = null;
    });
    // Release capture when the mode changes, including a start still waiting
    // for permission: stopping bumps the epoch so it never activates
    // (Codex #221).
    if (changed) await _stopMedia();
    if (!mounted || epoch != _modeEpoch || !_onScreen) return;
    if (mode == PantryMode.scan && !widget.isDemo && _photo == null) {
      await _ensureMedia();
      // A later switch while the camera started: release it.
      if (mounted && epoch != _modeEpoch && _mode != PantryMode.scan) {
        await _stopMedia();
      }
    }
  }

  void _capturePhoto() {
    if (widget.isDemo) {
      setState(() => _simulatedPhoto = true);
      return;
    }
    final frame = _preview;
    if (frame == null) return;
    setState(() => _photo = Uint8List.fromList(frame));
  }

  Future<void> _record() async {
    if (_recording != null) return;
    // A pretend clip needs no online processing (Codex #221).
    if (widget.isDemo) {
      setState(() => _simulatedAudio = true);
      return;
    }
    if (_voiceOff) {
      setState(() => _error = pantryVoiceUnavailable);
      return;
    }
    // A new clip replaces any earlier "skipped" notice.
    if (_voiceSkipped != null) setState(() => _voiceSkipped = null);
    if (!await _ensureMedia(microphone: true) || !mounted) return;
    // The cook may have left Say it while permission was pending.
    if (_mode != PantryMode.say) {
      await _stopMedia();
      return;
    }
    _media?.setMicrophoneMuted(false);
    setState(() {
      _audio = null;
      _recording = BytesBuilder(copy: false);
      _recordProgress = 0;
    });
    _recordTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return timer.cancel();
      final elapsed = const Duration(milliseconds: 100) * timer.tick;
      if (elapsed >= widget.recordDuration) {
        _finishRecording();
      } else {
        setState(
          () => _recordProgress =
              elapsed.inMilliseconds / widget.recordDuration.inMilliseconds,
        );
      }
    });
  }

  void _finishRecording() {
    _recordTimer?.cancel();
    final pcm = _recording?.takeBytes();
    _recording = null;
    setState(() {
      _recordProgress = 0;
      // Under half a second of 16 kHz PCM16 is not a usable clip.
      if (pcm == null || pcm.length < 16000) {
        _error = 'I did not hear anything. Check the microphone and try again.';
        _matchError = false;
      } else {
        _audio = pcm16ToWav(pcm);
      }
    });
  }

  // ---- analysis ------------------------------------------------------------

  bool get _hasInput =>
      _text.text.trim().isNotEmpty ||
      _photo != null ||
      _audio != null ||
      _simulatedPhoto ||
      _simulatedAudio;

  Future<void> _analyze() async {
    if (_thinking) return;
    // The notice belongs to the submission that dropped a clip (Codex #221).
    if (_voiceSkipped != null) setState(() => _voiceSkipped = null);
    // Re-read the voice gate at send: a closed gate drops the clip, and the
    // cook is told (Codex #221).
    if (_audio != null && _voiceOff && !widget.isDemo) {
      setState(() {
        _audio = null;
        _voiceSkipped = pantryVoiceSkipped;
      });
      if (!_hasInput) {
        setState(() {
          _error = pantryVoiceSkipped;
          _matchError = false;
        });
        // Same cleanup as a send: release capture (Codex #221).
        await _stopMedia();
        return;
      }
    }
    if (!_hasInput && !widget.isDemo) {
      setState(() {
        _error = 'Show, say, or type what you got first.';
        _matchError = false;
      });
      return;
    }
    setState(() {
      _thinking = true;
      _error = null;
      _errorLegs = const [];
    });
    // Release the camera and microphone as soon as the inputs are captured.
    await _stopMedia();
    if (!mounted) return;
    // Re-read the gate after the await: it may have closed meanwhile
    // (Codex #221).
    if (_audio != null && _voiceOff && !widget.isDemo) {
      setState(() {
        _audio = null;
        _voiceSkipped = pantryVoiceSkipped;
      });
      if (!_hasInput) {
        setState(() {
          _thinking = false;
          _error = pantryVoiceSkipped;
          _matchError = false;
        });
        return;
      }
    }
    // The cook's submitted words, not whatever the field holds when the
    // answer arrives (Codex #221).
    final submitted = _text.text;
    try {
      final result = await widget.client.identify(
        PantryInput(
          text: submitted,
          simulatedPhoto: _simulatedPhoto,
          simulatedAudio: _simulatedAudio && _mode == PantryMode.say,
          photoJpeg: _photo,
          // Audio is sent only from Say it, where the clip is shown, and only
          // while voice processing is on (re-read at send).
          audioWav: _mode == PantryMode.say && !_voiceOff ? _audio : null,
        ),
        widget.recipes,
      );
      if (!mounted) return;
      // What the cook typed is their own word: those items start confirmed.
      _ui.show(result, widget.recipes, typed: submitted);
      _reveal(_resultsKey);
      setState(() {
        _result = result;
        _draftEpoch++;
        _drafting = false;
        _draftError = null;
        _drafted = null;
        _draftLegs = const [];
        _answer.clear();
      });
    } on PantryException catch (error) {
      if (mounted) {
        final message = await _withReason(error.message);
        if (!mounted) return;
        setState(() {
          _error = message;
          _errorLegs = error.legs;
          _matchError = true;
        });
        _reveal(_errorKey);
      }
    } catch (_) {
      if (mounted) {
        final message = await _withReason(pantryUnavailableMessage);
        if (!mounted) return;
        setState(() {
          _error = message;
          _matchError = true;
        });
        _reveal(_errorKey);
      }
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  /// Adds the known reason to a reasonless "unavailable" message.
  Future<String> _withReason(String message) async {
    const generic = {
      pantryUnavailableMessage,
      'Ingredient matching is unavailable right now. Pick a recipe below.',
    };
    if (!generic.contains(message)) return message;
    String? reason;
    try {
      reason = await widget.unavailableReason?.call();
    } catch (_) {
      reason = null;
    }
    return reason == null
        ? pantryUnavailableMessage
        : "Matching your food didn't work just now. $reason Pick a recipe "
              'below, or try again.';
  }

  Future<void> _openNearby(
    NearbyKind kind, {
    List<String> missing = const [],
  }) => showNearbySheet(
    context,
    client: _nearby!,
    kind: kind,
    missingItems: missing,
    locate:
        widget.locate ??
        (widget.isDemo ? () async => NearbyCoordinates(28.54, -81.38) : null),
    openLink: widget.openLink,
  );

  Future<void> _draft() async {
    final client = widget.draftClient;
    final items = _ui.confirmedItems;
    if (client == null || _drafting || items.isEmpty) return;
    final epoch = ++_draftEpoch;
    setState(() {
      _drafting = true;
      _draftError = null;
    });
    try {
      final result = await client.draft(
        RecipeDraftRequest(confirmedItems: items, note: _text.text.trim()),
      );
      if (!mounted || epoch != _draftEpoch) return;
      setState(() {
        _drafted = result.recipe;
        _draftLegs = result.legs;
      });
      _choose(result.recipe);
    } on RecipeDraftException catch (error) {
      if (mounted && epoch == _draftEpoch) {
        setState(() => _draftError = error.message);
      }
    } catch (_) {
      if (mounted && epoch == _draftEpoch) {
        setState(
          () => _draftError =
              'Recipe drafting is unavailable right now. Pick a recipe below.',
        );
      }
    } finally {
      if (mounted && epoch == _draftEpoch) setState(() => _drafting = false);
    }
  }

  void _chooseById(String recipeId) {
    final recipe = widget.recipes.where((r) => r.id == recipeId).firstOrNull;
    if (recipe != null) _choose(recipe);
  }

  /// False once another route (cooking) covers the pantry.
  bool get _onScreen => ModalRoute.of(context)?.isCurrent ?? true;

  void _choose(Recipe recipe, {bool skipped = false}) {
    final question = _result?.question;
    final answer = _answer.text.trim();
    // Leaving the pantry: any pending mode switch is superseded, so it never
    // opens a camera behind the cooking screen, and no clip is kept
    // (Codex #221).
    _modeEpoch++;
    _recordTimer?.cancel();
    _recording = null;
    _audio = null;
    _simulatedAudio = false;
    unawaited(_stopMedia());
    widget.onChooseRecipe(
      recipe,
      skipped
          ? const PantryHandoff()
          : PantryHandoff(
              confirmedItems: _ui.confirmedItems,
              answer: question != null && answer.isNotEmpty
                  ? (question: question, answer: answer)
                  : null,
            ),
    );
  }

  // ---- layout --------------------------------------------------------------

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF7EFE1),
    // The scroll view spans the window and the column is centred inside it,
    // so the wheel works over the side margins on desktop (SS-089).
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = centeredSide(
            constraints.maxWidth,
            maxWidth: 720,
            gutter: 16,
          );
          return SingleChildScrollView(
            key: const ValueKey('pantry-scroll'),
            padding: EdgeInsets.fromLTRB(side, 16, side, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _brand(),
                const SizedBox(height: 18),
                ?widget.header,
                if (widget.isDemo) ...[
                  _notice(
                    'Practice mode (pretend answers) · No real camera, '
                    'microphone or AI is used.',
                    Icons.science_outlined,
                  ),
                  const SizedBox(height: 14),
                ],
                _hero(),
                const SizedBox(height: 18),
                _modeTabs(),
                const SizedBox(height: 14),
                _modePanel(),
                const SizedBox(height: 16),
                _findButton(),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: Color(0xFF6B5A3E),
                    ),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        pantryPrivacyLine,
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF6B5A3E),
                        ),
                      ),
                    ),
                  ],
                ),
                // Shown only while the gate is still closed (Codex #221).
                if (_voiceSkipped case final skipped? when _error == null) ...[
                  const SizedBox(height: 14),
                  _notice(skipped, Icons.mic_off_outlined),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 14),
                  Semantics(
                    key: _errorKey,
                    liveRegion: true,
                    child: _notice(
                      error,
                      Icons.info_outline,
                      color: const Color(0xFFFBE3DC),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_matchError)
                    _errorLegs.isNotEmpty
                        ? PantryLegList(legs: _errorLegs)
                        : const _NoAnswerSource(),
                ],
                if (_result case final result?) ...[
                  const SizedBox(height: 28),
                  KeyedSubtree(key: _resultsKey, child: _resultsHeader(result)),
                  const SizedBox(height: 8),
                  PantryLegList(legs: result.legs),
                  if (result.notice case final notice?) ...[
                    const SizedBox(height: 8),
                    _notice(
                      notice,
                      Icons.mic_off_outlined,
                      color: const Color(0xFFFFF1CC),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (pantryUnusedItems(result) case final unused
                      when unused.isNotEmpty) ...[
                    Text(
                      'Not used in these recipes: ${unused.join(', ')}',
                      key: const ValueKey('pantry-unused'),
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF5C4A2E),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (result.question case final question?) ...[
                    _questionCard(question),
                    const SizedBox(height: 18),
                  ],
                  if (widget.draftClient != null) ...[
                    AnimatedBuilder(
                      animation: _ui,
                      builder: (_, _) => _draftSection(result),
                    ),
                    const SizedBox(height: 18),
                  ],
                  PantrySurface(controller: _ui),
                ],
                if (nearbyOffered(_nearby)) ...[
                  const SizedBox(height: 24),
                  _nearbyCard(),
                ],
                const SizedBox(height: 32),
                _skipList(),
              ],
            ),
          );
        },
      ),
    ),
  );

  Widget _brand() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: pantryGreen,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.soup_kitchen_outlined,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SousSight',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
                Text(
                  'Pantry to plate, with a coach beside you',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          HowItWorksButton(isDemo: widget.isDemo),
        ],
      ),
      if (widget.headerActions case final actions?) ...[
        const SizedBox(height: 6),
        Align(alignment: Alignment.centerLeft, child: actions),
      ],
    ],
  );

  Widget _hero() => Container(
    padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2C6A4F), Color(0xFF173F30)],
      ),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'GARDEN · PANTRY · PLATE',
          style: TextStyle(
            color: pantryMustard,
            fontSize: 12,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: 10),
        Text(
          'What did you get from the pantry?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 32,
            height: 1.1,
            letterSpacing: -1,
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: 10),
        Text(
          'Show it, say it, or type it. I’ll match it to a meal you can make today, then cook it with you step by step.',
          style: TextStyle(
            color: Color(0xFFDDE8DF),
            fontSize: 16,
            height: 1.45,
          ),
        ),
      ],
    ),
  );

  Widget _modeTabs() => Row(
    spacing: 10,
    children: [
      for (final (mode, icon, label) in [
        (PantryMode.scan, Icons.photo_camera_outlined, 'Scan'),
        (PantryMode.say, Icons.mic_none_rounded, 'Say it'),
        (PantryMode.type, Icons.keyboard_outlined, 'Type it'),
      ])
        Expanded(
          child: Semantics(
            selected: _mode == mode,
            button: true,
            child: Material(
              color: _mode == mode ? pantryTomato : Colors.white,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                key: ValueKey('mode-${mode.name}'),
                borderRadius: BorderRadius.circular(20),
                onTap: () => unawaited(_selectMode(mode)),
                child: SizedBox(
                  height: 84,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        size: 30,
                        color: _mode == mode ? Colors.white : pantryTomato,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: _mode == mode
                              ? Colors.white
                              : const Color(0xFF3B3328),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _modePanel() => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: switch (_mode) {
        PantryMode.scan => _scanPanel(),
        PantryMode.say => _sayPanel(),
        PantryMode.type => _typePanel(),
      },
    ),
  );

  Widget _scanPanel() {
    final shown = _photo ?? _preview;
    final captured = _photo != null || _simulatedPhoto;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (shown != null)
                  Image.memory(shown, fit: BoxFit.cover, gaplessPlayback: true)
                else
                  ColoredBox(
                    color: const Color(0xFF1D3F31),
                    child: Center(
                      child: _mediaStarting
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                widget.isDemo
                                    ? (_simulatedPhoto
                                          ? 'Pretend photo captured'
                                          : 'Practice mode: the camera is not used')
                                    : 'Lay your haul out on the counter and point the camera at it.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  height: 1.4,
                                ),
                              ),
                            ),
                    ),
                  ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: _pill(
                    widget.isDemo
                        ? 'PRACTICE MODE'
                        : _photo != null
                        ? 'PHOTO READY'
                        : _preview != null
                        ? 'LIVE PREVIEW'
                        : 'CAMERA OFF',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (captured)
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Retake'),
            onPressed: () {
              setState(() {
                _photo = null;
                _simulatedPhoto = false;
              });
              if (!widget.isDemo) unawaited(_ensureMedia());
            },
          )
        else
          FilledButton.icon(
            key: const ValueKey('snap-photo'),
            style: _bigButton(pantryGreen),
            icon: const Icon(Icons.camera_alt),
            label: Text(
              widget.isDemo
                  ? 'Take a pretend photo'
                  : _preview == null
                  ? 'Start camera'
                  : 'Snap photo',
            ),
            onPressed: widget.isDemo || _preview != null
                ? _capturePhoto
                : () => unawaited(_ensureMedia()),
          ),
      ],
    );
  }

  Widget _sayPanel() {
    final recording = _recording != null;
    final captured = _audio != null || _simulatedAudio;
    final seconds = widget.recordDuration.inSeconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          recording
              ? 'Listening… name everything you got.'
              : captured
              ? (widget.isDemo
                    ? 'Pretend voice clip ready.'
                    : 'Got it. Your $seconds-second clip is ready.')
              : 'Tap and list what’s in your bag, like “black beans, corn, two tomatoes, bread.”',
          style: const TextStyle(fontSize: 16, height: 1.4),
        ),
        const SizedBox(height: 14),
        if (recording)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _recordProgress,
              minHeight: 12,
              color: pantryTomato,
              backgroundColor: const Color(0xFFF4DCD3),
            ),
          ),
        if (recording) const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('record-voice'),
          style: _bigButton(recording ? pantryTomato : pantryGreen),
          icon: Icon(recording ? Icons.graphic_eq : Icons.mic),
          label: Text(
            recording
                ? 'Recording…'
                : widget.isDemo
                ? 'Record a pretend voice clip'
                : captured
                ? 'Record again ($seconds s)'
                : 'Record $seconds seconds',
          ),
          onPressed:
              recording || _mediaStarting || (_voiceOff && !widget.isDemo)
              ? null
              : () => unawaited(_record()),
        ),
        if (!widget.isDemo) ...[
          const SizedBox(height: 10),
          // Said before the cook records (Codex #221): the voice task asks
          // no further consent because this line is the disclosure.
          Row(
            key: const ValueKey('voice-cloud-disclosure'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.cloud_outlined,
                size: 18,
                color: Color(0xFF5C4A2E),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _voiceOff ? pantryVoiceUnavailable : pantryVoiceDisclosure,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF5C4A2E),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _typePanel() => TextField(
    key: const ValueKey('pantry-text'),
    controller: _text,
    minLines: 3,
    maxLines: 6,
    maxLength: 1500,
    onChanged: (_) => setState(() {}),
    style: const TextStyle(fontSize: 17),
    decoration: const InputDecoration(
      hintText:
          'e.g. canned black beans, corn, 2 tomatoes, bread, peanut butter',
      filled: true,
      fillColor: pantryCream,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Widget _findButton() => FilledButton.icon(
    key: const ValueKey('find-meal'),
    style: _bigButton(pantryTomato, height: 64),
    icon: _thinking
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          )
        : const Icon(Icons.auto_awesome),
    label: Text(_thinking ? 'Finding meals…' : 'Find my meal'),
    onPressed: _thinking ? null : () => unawaited(_analyze()),
  );

  Widget _resultsHeader(PantryResult result) => Row(
    children: [
      const Expanded(
        child: Text(
          'Your pantry haul',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ),
      if (result.simulated)
        _pill('PRACTICE MODE', color: const Color(0xFF6B5A3E)),
    ],
  );

  Widget _questionCard(String question) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF1CC),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: pantryMustard, width: 1.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.help_outline, color: Color(0xFF8A5A00)),
            SizedBox(width: 8),
            Text(
              'QUICK QUESTION',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w800,
                color: Color(0xFF8A5A00),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          question,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('pantry-answer'),
          controller: _answer,
          maxLength: 300,
          decoration: const InputDecoration(
            hintText: 'Your answer (optional)',
            hintMaxLines: 2,
            helperText: 'I’ll pass it to your coach.',
            helperMaxLines: 2,
            filled: true,
            fillColor: Colors.white,
            counterText: '',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _draftSection(PantryResult result) {
    final canDraft = _ui.confirmedItems.isNotEmpty && !_drafting;
    final status = <Widget>[
      if (_drafting) ...[
        const SizedBox(height: 12),
        const Row(
          key: ValueKey('draft-progress'),
          children: [
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(width: 10),
            Expanded(child: Text('Drafting a recipe from your items…')),
          ],
        ),
      ],
      if (_draftError case final error?) ...[
        const SizedBox(height: 12),
        _notice(error, Icons.info_outline, color: const Color(0xFFFBE3DC)),
      ],
      if (_drafted case final drafted?) ...[
        const SizedBox(height: 12),
        Text(
          drafted.title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: DraftRecipeChip(recipe: drafted, practice: widget.isDemo),
        ),
        const SizedBox(height: 8),
        PantryLegList(legs: _draftLegs),
        OutlinedButton.icon(
          key: const ValueKey('cook-drafted'),
          icon: const Icon(Icons.restaurant),
          label: const Text('Cook this draft'),
          onPressed: () => _choose(drafted),
        ),
      ],
    ];
    return Container(
      key: const ValueKey('draft-card'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: pantryMustard, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Make a real meal from your pantry haul',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          const Text(
            "Tap the ingredients you have below, then SousSight's AI creates a "
            'recipe from exactly those. It is labelled as not reviewed by a '
            'person.',
            style: TextStyle(fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const ValueKey('draft-recipe'),
            style: _bigButton(pantryGreen),
            icon: const Icon(Icons.auto_awesome),
            label: Text(
              _drafting
                  ? 'Creating your recipe…'
                  : 'Make a meal from these ingredients',
            ),
            onPressed: canDraft ? () => unawaited(_draft()) : null,
          ),
          if (_ui.confirmedItems.isEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Tap the ingredients you have below first',
              key: ValueKey('draft-hint'),
              style: TextStyle(fontSize: 13, color: Color(0xFF6B5A3E)),
            ),
          ],
          ...status,
        ],
      ),
    );
  }

  Widget _nearbyCard() => Material(
    color: const Color(0xFFE4EBDF),
    borderRadius: BorderRadius.circular(22),
    child: InkWell(
      key: const ValueKey('nearby-food-help'),
      borderRadius: BorderRadius.circular(22),
      onTap: () => unawaited(_openNearby(NearbyKind.foodHelp)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                Icons.volunteer_activism_outlined,
                color: pantryGreen,
                size: 30,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Find food help nearby',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Food pantries and free meals near you, from Google Maps.',
                      style: TextStyle(fontSize: 14, color: Color(0xFF3B3328)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _skipList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Skip — pick a recipe',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      for (final recipe in widget.recipes)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              key: ValueKey('skip-${recipe.id}'),
              borderRadius: BorderRadius.circular(20),
              onTap: () => _choose(recipe, skipped: true),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.menu_book_outlined, color: pantryGreen),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              recipe.title,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${recipe.ingredients.length} ingredients · ${recipe.steps.length} steps',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF6B5A3E),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  static ButtonStyle _bigButton(Color color, {double height = 56}) =>
      FilledButton.styleFrom(
        backgroundColor: color,
        minimumSize: Size.fromHeight(height),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      );

  static Widget _pill(String text, {Color? color}) => DecoratedBox(
    decoration: BoxDecoration(
      color: color ?? Colors.black.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          letterSpacing: 1,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );

  static Widget _notice(String text, IconData icon, {Color? color}) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color ?? const Color(0xFFE4EBDF),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
            ),
          ],
        ),
      );
}

/// The source line for a failure with no inference legs: says that no answer
/// came back, and claims nothing about where anything ran (SS-089).
class _NoAnswerSource extends StatelessWidget {
  const _NoAnswerSource();

  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('pantry-no-answer-source'),
    container: true,
    label: 'Where this ran: no answer came back.',
    excludeSemantics: true,
    child: const Row(
      children: [
        Icon(Icons.block, size: 16, color: Color(0xFF3D3A34)),
        SizedBox(width: 6),
        Flexible(
          child: Text(
            'Meal match · no answer came back',
            style: TextStyle(fontSize: 13, color: Color(0xFF3D3A34)),
          ),
        ),
      ],
    ),
  );
}
