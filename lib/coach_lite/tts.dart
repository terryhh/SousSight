// Coach Lite read-aloud (SS-077): device text-to-speech for Coach Lite
// answers. Off by default; the cook turns it on with the speaker toggle.
//
// Speech stops when the step changes, the cook asks again, Live connects, the
// app is backgrounded or the screen goes away. Each answer is read at most
// once automatically. Sentences that would certify doneness, temperature or
// safety are never spoken (the same filter model answers must pass).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'coach_lite.dart';
import 'tts_native.dart' if (dart.library.js_interop) 'tts_web.dart';

/// Where the voice runs, as far as the platform tells us.
enum VoiceLocality {
  /// Android/iOS text-to-speech engine.
  deviceEngine,

  /// A browser voice the browser reports as local (`localService`).
  browserLocal,

  /// No browser voice reported as local: the browser may use an online voice
  /// service, which would receive the answer text.
  browserMayUseNetwork,
}

class TtsSupport {
  const TtsSupport({required this.available, required this.locality});
  static const unavailable = TtsSupport(
    available: false,
    locality: VoiceLocality.browserMayUseNetwork,
  );
  final bool available;
  final VoiceLocality locality;
}

/// The platform voice. Implementations: [createDeviceTextToSpeech]; tests use
/// a fake.
abstract class TextToSpeech {
  /// Never throws; unavailable when the platform cannot speak.
  Future<TtsSupport> probe();

  /// Replaces anything being spoken.
  Future<void> speak(String text);
  Future<void> stop();
}

/// The text read aloud for [answer]: each visible component in display order,
/// minus any sentence that would certify doneness, temperature or safety.
/// Empty for a cancelled answer.
String coachLiteSpokenText(CoachLiteAnswer answer, {int maxChars = 1500}) {
  if (answer.status == CoachLiteStatus.cancelled) return '';
  final byId = {for (final c in answer.components) c['id']: c};
  final root = byId['root'];
  final order = root?['children'];
  if (order is! List) return '';
  final parts = <String>[];
  void add(Object? value, [String prefix = '']) {
    if (value is! String) return;
    final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return;
    for (final sentence in clean.split(RegExp(r'(?<=[.!?])\s+'))) {
      if (sentence.isEmpty || coachLiteCertifies(sentence)) continue;
      final s = '$prefix$sentence';
      parts.add(RegExp(r'[.!?…:]$').hasMatch(s) ? s : '$s.');
    }
  }

  for (final id in order) {
    final c = byId[id];
    if (c == null) continue;
    switch (c['component']) {
      case 'stepCue':
        add(c['title']);
        add(c['body']);
      case 'comparison':
        add(c['title']);
        add(c['observed'], 'You said: ');
        add(c['target'], 'Aim for: ');
        add(c['cue']);
    }
  }
  final text = parts.join(' ');
  if (text.length <= maxChars) return text;
  final cut = text.substring(0, maxChars);
  final end = cut.lastIndexOf(RegExp(r'[.!?]\s'));
  return end > 0 ? cut.substring(0, end + 1) : cut;
}

/// Owns read-aloud for one cooking screen.
class CoachLiteSpeaker extends ChangeNotifier {
  CoachLiteSpeaker(this._tts);

  final TextToSpeech _tts;
  TtsSupport _support = TtsSupport.unavailable;
  bool _enabled = false;
  bool _disposed = false;

  /// Bumped by every speak and stop; a pending speak checks it after each
  /// await so a stop, a newer answer or disposal always wins.
  int _generation = 0;

  /// True from a speak until the next stop, so idle updates don't spam the
  /// platform with stop calls.
  bool _mayBeSpeaking = false;

  /// The answer on screen that may be read, if any.
  CoachLiteAnswer? _current;

  /// The newest answer seen, so an answer is read at most once on its own.
  CoachLiteStamp? _seen;

  bool get available => _support.available;
  VoiceLocality get locality => _support.locality;
  bool get enabled => _enabled;

  /// Checks the platform once. The toggle stays hidden until this reports
  /// the voice available.
  Future<void> init() => _probe();

  Future<void> _probe() async {
    final support = await _tts.probe();
    if (_disposed) return;
    _support = support;
    notifyListeners();
  }

  /// The cook's toggle. Turning it on reads the answer on screen now; off
  /// stops at once.
  void setEnabled(bool on) {
    if (_disposed || on == _enabled) return;
    if (on && !available) return;
    _enabled = on;
    if (on) {
      // The browser's voice list may have loaded since the first probe.
      unawaited(_probe());
      if (_current case final answer?) unawaited(_speak(answer));
    } else {
      stop();
    }
    notifyListeners();
  }

  /// Call on every coordinator change with its current state.
  void sync({
    required CoachLiteAnswer? answer,
    required bool busy,
    required bool liveActive,
    required String stepId,
  }) {
    if (_disposed) return;
    final readable =
        answer != null &&
        !busy &&
        !liveActive &&
        answer.stamp.stepId == stepId &&
        answer.status != CoachLiteStatus.cancelled;
    if (!readable) {
      // Asked again, Live took over, the step changed or the answer went.
      _current = null;
      stop();
      return;
    }
    _current = answer;
    if (answer.stamp == _seen) return;
    _seen = answer.stamp;
    if (_enabled) unawaited(_speak(answer));
  }

  /// Stops speech now (and any speak still starting). Keeps the toggle.
  void stop() {
    _generation++;
    if (!_mayBeSpeaking) return;
    _mayBeSpeaking = false;
    unawaited(_tts.stop().catchError((Object _) {}));
  }

  Future<void> _speak(CoachLiteAnswer answer) async {
    final generation = ++_generation;
    final text = coachLiteSpokenText(answer);
    if (text.isEmpty) return;
    _mayBeSpeaking = true;
    try {
      await _tts.stop();
      if (_disposed || generation != _generation || !_enabled) return;
      await _tts.speak(text);
    } catch (e) {
      debugPrint('Read aloud failed (${e.runtimeType}).');
    }
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}

/// The platform's text-to-speech: flutter_tts on Android and iOS, the
/// browser's Web Speech API on the web.
TextToSpeech deviceTextToSpeech() => createDeviceTextToSpeech();
