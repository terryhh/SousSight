import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../genui/cooking_ui.dart';
import '../live/live_types.dart';

/// Deliberately camera-free rehearsal. The UI labels this mode as simulated.
class DemoLiveMedia implements LiveMedia {
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  Stream<Uint8List> get microphone => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  void setMicrophoneMuted(bool muted) {}
  @override
  void playAudio(Uint8List pcm24khz) {}
  @override
  void interruptPlayback() {}
}

class DemoLiveTransport implements LiveTransport {
  final _events = StreamController<LiveEvent>.broadcast();
  int _id = 0;
  String? _stepId;

  void _readStep(String context) {
    final match = RegExp(r'currentStepId: ([A-Za-z0-9_-]+)')
        .firstMatch(context);
    if (match != null) _stepId = match.group(1);
  }

  @override
  Stream<LiveEvent> get events => _events.stream;
  @override
  Future<void> connect({required String systemInstruction}) async {
    _readStep(systemInstruction);
  }

  @override
  Future<void> sendAudio(Uint8List pcm16khz) async {}
  @override
  Future<void> sendVideo(Uint8List jpeg) async {}
  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) async {}
  @override
  Future<void> sendText(String text) async {
    if (_events.isClosed) return;
    _readStep(text);
    final lower = text.toLowerCase();
    Map<String, dynamic> ui = demoCookingUi;
    String reply =
        'Demo coach: show your ingredients, check your bowl, or start a timer.';
    if (lower.contains('compare') || lower.contains('doing this right')) {
      ui = {
        'components': [
          {
            'id': 'root',
            'component': 'CookingColumn',
            'children': ['comparison', 'next'],
          },
          {
            'id': 'comparison',
            'component': 'comparison',
            'title': 'Rehearsal: a little more mashing',
            'observed': 'Simulated result: several whole chickpeas remain.',
            'target': 'Coarse, broken pieces with a few small chunks.',
            'cue': 'This is an example response, not a camera assessment.',
          },
          {
            'id': 'next',
            'component': 'stepCue',
            'title': 'Try a few more presses',
            'body': 'Then show the bowl again.',
            'action': 'check_now',
            'actionLabel': 'Check again',
          },
        ],
      };
      reply = 'Demo coach: the workspace has changed to a comparison panel.';
    }
    _events.add(LiveTranscript(reply, isUser: false, finished: true));
    _events.add(
      LiveToolCall(
        name: 'show_cooking_ui',
        id: 'demo-${_id++}',
        arguments: {'stepId': _stepId, 'uiJson': jsonEncode(ui)},
      ),
    );
    _events.add(const LiveTurnComplete());
  }

  @override
  Future<void> close() => _events.close();
}
