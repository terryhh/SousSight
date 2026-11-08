import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/models.dart';
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
  Recipe? _recipe;

  Map<String, dynamic> get _workspace => {
    'components': [
      {
        'id': 'root',
        'component': 'CookingColumn',
        'children': ['step'],
      },
      {
        'id': 'step',
        'component': 'stepCue',
        'title': 'Rehearsal: ${_step?.title ?? 'Check the current step'}',
        'body': _step == null
            ? 'Simulated coaching only. Show your food in a real session for a visual check.'
            : '${_step!.instruction} Look for: ${_step!.cue}',
        'action': 'check_now',
        'actionLabel': 'Check my food',
      },
    ],
  };

  RecipeStep? get _step => _recipe?.step(_stepId ?? _recipe!.steps.first.id);

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
    const prefix = 'Recipe data for this cooking session: ';
    for (final line in systemInstruction.split('\n')) {
      if (line.startsWith(prefix)) {
        _recipe = Recipe.fromMap(
          jsonDecode(line.substring(prefix.length)) as Map<String, dynamic>,
        );
        break;
      }
    }
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
    Map<String, dynamic> ui = _workspace;
    String reply =
        'Demo coach: show your ingredients, check your food, or start a timer.';
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
            'title': 'Rehearsal: compare your progress',
            'observed':
                'Simulated example only; no camera image was inspected.',
            'target': _step?.cue ?? 'Follow the current recipe cue.',
            'cue': 'This is an example response, not a camera assessment.',
          },
          {
            'id': 'next',
            'component': 'stepCue',
            'title': _step?.title ?? 'Check the current step',
            'body': _step?.instruction ?? 'Then show your food again.',
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
