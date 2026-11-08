import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/how_it_works.dart';
import '../core/models.dart';
import '../live/live_types.dart';
import 'pantry_client.dart';
import 'pantry_handoff.dart';
import 'pantry_models.dart';
import 'pantry_ui.dart';
import 'wav.dart';

enum PantryMode { scan, say, type }

typedef PantryRecipeChosen = void Function(
  Recipe recipe,
  PantryHandoff handoff,
);

const pantryPrivacyLine =
    'Photos and audio go to Google Gemini to identify ingredients; nothing is stored.';

/// "What did you get from the pantry?" The cook shows, says, or types their
/// haul; one Gemini call suggests bundled recipes; the cook confirms and picks.
class PantryScreen extends StatefulWidget {
  const PantryScreen({
    super.key,
    required this.recipes,
    required this.client,
    required this.onChooseRecipe,
    this.isDemo = false,
    this.mediaFactory,
    this.recordDuration = const Duration(seconds: 6),
  });

  final List<Recipe> recipes;
  final PantryClient client;
  final PantryRecipeChosen onChooseRecipe;
  final bool isDemo;

  /// Browser camera + microphone bridge. Not used in rehearsal mode.
  final LiveMedia Function()? mediaFactory;
  final Duration recordDuration;

  @override
  State<PantryScreen> createState() => _PantryScreenState();
}

class _PantryScreenState extends State<PantryScreen> {
  late final PantryUiController _ui = PantryUiController(
    onChooseMeal: _chooseById,
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
  PantryResult? _result;

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

  Future<bool> _ensureMedia() async {
    if (_media != null) return true;
    final factory = widget.mediaFactory;
    if (factory == null || _mediaStarting) return false;
    setState(() => _mediaStarting = true);
    final media = factory();
    final epoch = _mediaEpoch;
    _pendingMedia = media;
    try {
      _subscriptions.addAll([
        media.frames.listen((frame) {
          if (mounted) setState(() => _preview = frame);
        }),
        media.microphone.listen((chunk) => _recording?.add(chunk)),
        media.errors.listen((message) {
          if (!mounted) return;
          setState(() {
            _error = message;
            _media = null;
          });
        }),
      ]);
      await media.start();
      if (!mounted || epoch != _mediaEpoch) {
        await media.stop();
        return false;
      }
      _media = media;
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
    _preview = null;
    await media?.stop();
  }

  Future<void> _selectMode(PantryMode mode) async {
    setState(() {
      _mode = mode;
      _error = null;
    });
    if (mode == PantryMode.scan && !widget.isDemo && _photo == null) {
      await _ensureMedia();
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
    if (widget.isDemo) {
      setState(() => _simulatedAudio = true);
      return;
    }
    if (!await _ensureMedia() || !mounted) return;
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
    if (!_hasInput && !widget.isDemo) {
      setState(() => _error = 'Show, say, or type what you got first.');
      return;
    }
    setState(() {
      _thinking = true;
      _error = null;
    });
    // Release the camera and microphone as soon as the inputs are captured.
    await _stopMedia();
    try {
      final result = await widget.client.identify(
        PantryInput(text: _text.text, photoJpeg: _photo, audioWav: _audio),
        widget.recipes,
      );
      if (!mounted) return;
      _ui.show(result, widget.recipes);
      setState(() {
        _result = result;
        _answer.clear();
      });
    } on PantryException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Ingredient matching is unavailable right now. Pick a recipe below.',
        );
      }
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  void _chooseById(String recipeId) {
    final recipe = widget.recipes.where((r) => r.id == recipeId).firstOrNull;
    if (recipe != null) _choose(recipe);
  }

  void _choose(Recipe recipe, {bool skipped = false}) {
    final question = _result?.question;
    final answer = _answer.text.trim();
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
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _brand(),
                const SizedBox(height: 18),
                if (widget.isDemo) ...[
                  _notice(
                    'Rehearsal mode · Camera, microphone, and Gemini are not used. Results are simulated.',
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
                if (_error case final error?) ...[
                  const SizedBox(height: 14),
                  _notice(
                    error,
                    Icons.info_outline,
                    color: const Color(0xFFFBE3DC),
                  ),
                ],
                if (_result case final result?) ...[
                  const SizedBox(height: 28),
                  _resultsHeader(result),
                  const SizedBox(height: 14),
                  if (result.question case final question?) ...[
                    _questionCard(question),
                    const SizedBox(height: 18),
                  ],
                  PantrySurface(controller: _ui),
                ],
                const SizedBox(height: 32),
                _skipList(),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _brand() => Row(
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
                                          ? 'Simulated photo captured'
                                          : 'Rehearsal: the camera is not used')
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
                        ? 'SIMULATED'
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
                  ? 'Simulate a photo'
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
                    ? 'Simulated voice clip ready.'
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
                ? 'Simulate a voice clip'
                : captured
                ? 'Record again ($seconds s)'
                : 'Record $seconds seconds',
          ),
          onPressed: recording || _mediaStarting
              ? null
              : () => unawaited(_record()),
        ),
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
          'Meals you can make',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ),
      if (result.simulated) _pill('SIMULATED', color: const Color(0xFF6B5A3E)),
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
            hintText: 'Your answer (optional) — I’ll pass it to your coach',
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
