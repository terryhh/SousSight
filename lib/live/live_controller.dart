import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'live_tools.dart';
import 'live_types.dart';

enum LiveCookingStatus {
  idle,
  connecting,
  listening,
  speaking,
  reconnecting,
  error,
}

/// Coordinates one user-started camera/microphone session. It never sends
/// notifications or advances recipe state without the host's tool handler.
class LiveCookingController extends ChangeNotifier {
  LiveCookingController({
    required this.transportFactory,
    required this.media,
    required this.onToolCall,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LiveTransportFactory transportFactory;
  final LiveMedia media;
  final LiveToolHandler onToolCall;
  final DateTime Function() _clock;
  LiveCookingStatus status = LiveCookingStatus.idle;
  String? error;
  String? notice;
  Uint8List? latestFrame;
  String userTranscript = '';
  String coachTranscript = '';
  bool microphoneMuted = false;
  String? watchGoal;
  DateTime? _frameAt;
  LiveTransport? _transport;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, Map<String, Object?>> _toolResults = {};
  final Set<String> _cancelledTools = {};
  Future<void> _toolQueue = Future<void>.value();
  Future<void>? _startOperation;
  Timer? _watchTimer;
  int _epoch = 0;
  bool _disposed = false;
  bool _readyReported = false;

  bool get isActive =>
      status != LiveCookingStatus.idle && status != LiveCookingStatus.error;
  bool get hasFreshFrame =>
      _frameAt != null &&
      _clock().difference(_frameAt!) < const Duration(seconds: 4);

  Future<void> start({required String cookingContext}) async {
    if (_disposed) throw StateError('Live controller has been disposed.');
    if (_startOperation case final pending?) await pending;
    if (isActive) return;
    final epoch = ++_epoch;
    final operation = _start(epoch, cookingContext);
    _startOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_startOperation, operation)) _startOperation = null;
    }
  }

  Future<void> _start(int epoch, String context) async {
    status = LiveCookingStatus.connecting;
    error = null;
    notice = null;
    _toolResults.clear();
    _cancelledTools.clear();
    _toolQueue = Future<void>.value();
    _notify();
    final transport = transportFactory();
    _transport = transport;
    _subscriptions.addAll([
      media.frames.listen((jpeg) {
        if (!_current(epoch)) return;
        latestFrame = jpeg;
        _frameAt = _clock();
        _notify();
        if (status != LiveCookingStatus.connecting) {
          _send(transport.sendVideo(jpeg), epoch);
        }
      }),
      media.microphone.listen((pcm) {
        if (!_current(epoch) ||
            microphoneMuted ||
            status == LiveCookingStatus.connecting) {
          return;
        }
        _send(transport.sendAudio(pcm), epoch);
      }),
      media.errors.listen((message) {
        if (_current(epoch)) unawaited(_fail(message));
      }),
      transport.events.listen(
        (event) => _handleEvent(event, transport, epoch),
        onError: (Object _) {
          if (_current(epoch)) {
            unawaited(_fail('Live connection failed. Please reconnect.'));
          }
        },
        onDone: () {
          if (_current(epoch)) {
            unawaited(_fail('Live connection ended. Tap Connect to continue.'));
          }
        },
      ),
    ]);
    try {
      // Called before the first network await so browsers can unlock audio
      // playback from the user's Connect gesture.
      await media.start().timeout(const Duration(seconds: 30));
      if (!_current(epoch)) return;
      media.setMicrophoneMuted(microphoneMuted);
      await transport
          .connect(systemInstruction: cookingLiveInstruction(context))
          .timeout(const Duration(seconds: 25));
      if (!_current(epoch)) {
        await transport.close();
        return;
      }
      status = LiveCookingStatus.listening;
      if (latestFrame case final jpeg?) await transport.sendVideo(jpeg);
      await transport.sendText(
        'Say a brief hello and ask me to show the ingredients or current cooking step.',
      );
      _notify();
    } catch (_) {
      if (_current(epoch)) {
        await _fail(
          'Could not start live cooking. Check camera/microphone permissions and the Live service, then reconnect.',
        );
      }
    }
  }

  Future<void> sendText(String text) async {
    final transport = _transport;
    if (transport == null ||
        !isActive ||
        status == LiveCookingStatus.connecting ||
        text.trim().isEmpty) {
      return;
    }
    try {
      await transport.sendText(text.trim());
    } catch (_) {
      await _fail(
        'Your message could not reach the live coach. Please reconnect.',
      );
    }
  }

  void setMicrophoneMuted(bool muted) {
    microphoneMuted = muted;
    media.setMicrophoneMuted(muted);
    _notify();
  }

  void startWatch(
    String goal, {
    Duration interval = const Duration(seconds: 8),
  }) {
    if (!isActive || goal.trim().isEmpty) return;
    stopWatch();
    watchGoal = goal.trim();
    _readyReported = false;
    // The application initiates observations; silent video alone is not
    // assumed to make the model proactively speak.
    final period = interval < const Duration(seconds: 3)
        ? const Duration(seconds: 3)
        : interval;
    _watchTimer = Timer.periodic(period, (_) {
      if (status != LiveCookingStatus.listening ||
          !hasFreshFrame ||
          _readyReported) {
        return;
      }
      unawaited(
        sendText(
          'Watch check: use the latest camera frame to assess this visible goal: $watchGoal. '
          'Call report_readiness with a short observation. Say uncertain if the goal is hidden. '
          'Do not infer internal temperature or food safety.',
        ),
      );
    });
    _notify();
  }

  void stopWatch() {
    _watchTimer?.cancel();
    _watchTimer = null;
    watchGoal = null;
    _readyReported = false;
    _notify();
  }

  void _handleEvent(LiveEvent event, LiveTransport transport, int epoch) {
    if (!_current(epoch)) return;
    switch (event) {
      case LiveAudio(:final pcm):
        status = LiveCookingStatus.speaking;
        media.playAudio(pcm);
      case LiveTranscript(:final text, :final isUser, :final finished):
        // Keep a bounded latest transcript, independent of the audio chunks.
        if (isUser) {
          userTranscript = _append(userTranscript, text);
        } else {
          coachTranscript = _append(coachTranscript, text);
        }
        if (finished) notice = null;
      case LiveTurnComplete():
        status = LiveCookingStatus.listening;
      case LiveInterrupted():
        media.interruptPlayback();
        status = LiveCookingStatus.listening;
      case LiveToolCall():
        _toolQueue = _toolQueue.then(
          (_) => _executeTool(event, transport, epoch),
        );
      case LiveToolsCancelled(:final ids):
        _cancelledTools.addAll(ids);
      case LiveConnectionNotice(:final message, :final reconnecting):
        notice = message;
        status = reconnecting
            ? LiveCookingStatus.reconnecting
            : LiveCookingStatus.listening;
    }
    _notify();
  }

  Future<void> _executeTool(
    LiveToolCall call,
    LiveTransport transport,
    int epoch,
  ) async {
    if (!_current(epoch) || _cancelledTools.contains(call.id)) return;
    final key = call.id ?? '${call.name}:${jsonEncode(call.arguments)}';
    Map<String, Object?> result;
    if (_toolResults[key] case final previous?) {
      result = previous;
    } else {
      final invalid = validateLiveTool(call);
      if (invalid != null) {
        result = {'ok': false, 'error': invalid};
      } else if (call.name == 'report_readiness' &&
          (watchGoal == null || !hasFreshFrame)) {
        result = {
          'ok': false,
          'error': 'No active watch with a fresh camera frame.',
        };
      } else if (call.name == 'report_readiness' &&
          call.arguments['state'] == 'ready' &&
          _readyReported) {
        result = {'ok': true, 'alreadyReported': true};
      } else {
        try {
          if (call.name == 'watch_cooking') {
            startWatch(call.arguments['goal'] as String);
          }
          result = await onToolCall(call);
          if (call.name == 'report_readiness' &&
              call.arguments['state'] == 'ready' &&
              result['ok'] != false) {
            _readyReported = true;
            _watchTimer?.cancel();
          }
        } catch (_) {
          result = {
            'ok': false,
            'error': 'The application could not complete this action.',
          };
        }
      }
      _toolResults[key] = result;
    }
    if (!_current(epoch) || _cancelledTools.contains(call.id)) return;
    try {
      await transport.respondToTool(call, result);
    } catch (_) {
      if (_current(epoch)) {
        await _fail('Live coach disconnected while updating a cooking tool.');
      }
    }
  }

  void _send(Future<void> operation, int epoch) {
    unawaited(
      operation.catchError((Object _) {
        if (_current(epoch)) {
          unawaited(
            _fail(
              'The live media connection was interrupted. Please reconnect.',
            ),
          );
        }
      }),
    );
  }

  Future<void> _fail(String message) async {
    await stop();
    if (_disposed) return;
    status = LiveCookingStatus.error;
    error = message;
    _notify();
  }

  Future<void> stop() async {
    ++_epoch;
    _watchTimer?.cancel();
    _watchTimer = null;
    watchGoal = null;
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    final transport = _transport;
    _transport = null;
    status = LiveCookingStatus.idle;
    latestFrame = null;
    _frameAt = null;
    _notify();
    await Future.wait([
      for (final subscription in subscriptions) subscription.cancel(),
      media.stop(),
      if (transport != null) transport.close(),
    ]);
  }

  bool _current(int epoch) => !_disposed && _epoch == epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _append(String previous, String next) {
    final value = previous + next;
    return value.length > 1600 ? value.substring(value.length - 1600) : value;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
