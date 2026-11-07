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
  bool _newUserTranscript = true;
  bool _newCoachTranscript = true;
  bool microphoneMuted = false;
  String? watchGoal;
  String? watchId;
  int _watchSequence = 0;
  DateTime? _frameAt;
  LiveTransport? _transport;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, Map<String, Object?>> _toolResults = {};
  final Set<String> _cancelledTools = {};
  Future<void> _toolQueue = Future<void>.value();
  Future<void>? _startOperation;
  Future<void>? _stopOperation;
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
    final requestedEpoch = _epoch;
    if (_startOperation case final pending?) {
      // Multiple Connect clicks coalesce while a connection is active. A new
      // Connect after Stop waits for the old attempt to settle before reuse.
      if (isActive) return pending;
      await pending;
      if (_disposed || _epoch != requestedEpoch) return;
    }
    if (_stopOperation case final cleanup?) {
      await cleanup;
      if (_disposed || _epoch != requestedEpoch) return;
    }
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
    userTranscript = '';
    coachTranscript = '';
    _newUserTranscript = true;
    _newCoachTranscript = true;
    _toolResults.clear();
    _cancelledTools.clear();
    _toolQueue = Future<void>.value();
    _notify();
    late final LiveTransport transport;
    try {
      transport = transportFactory();
    } catch (_) {
      await _fail(
        'Could not initialize the live cooking connection.',
        forEpoch: epoch,
      );
      return;
    }
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
        if (_current(epoch)) unawaited(_fail(message, forEpoch: epoch));
      }),
      transport.events.listen(
        (event) => _handleEvent(event, transport, epoch),
        onError: (Object _) {
          if (_current(epoch)) {
            unawaited(
              _fail(
                'Live connection failed. Please reconnect.',
                forEpoch: epoch,
              ),
            );
          }
        },
        onDone: () {
          if (_current(epoch)) {
            unawaited(
              _fail(
                'Live connection ended. Tap Connect to continue.',
                forEpoch: epoch,
              ),
            );
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
      if (!_current(epoch)) return;
      await transport.sendText(
        'Call show_cooking_ui now to compose a useful cooking workspace from the '
        'supplied recipe, current step, and cook-confirmed facts using the allowed UI catalog. '
        'If essential context is missing, show a targeted question instead of inventing '
        'ingredients, quantities, or progress. Then give a brief spoken welcome and '
        'invite me to show the ingredients or current cooking step.',
      );
      _notify();
    } catch (_) {
      if (_current(epoch)) {
        await _fail(
          'Could not start live cooking. Check camera/microphone permissions and the Live service, then reconnect.',
          forEpoch: epoch,
        );
      }
    }
  }

  Future<void> sendText(String text) async {
    final transport = _transport;
    final epoch = _epoch;
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
        forEpoch: epoch,
      );
    }
  }

  void setMicrophoneMuted(bool muted) {
    microphoneMuted = muted;
    media.setMicrophoneMuted(muted);
    _notify();
  }

  String? startWatch(
    String goal, {
    Duration interval = const Duration(seconds: 8),
  }) {
    if (!isActive || goal.trim().isEmpty) return null;
    stopWatch();
    watchGoal = goal.trim();
    final id = 'watch-$_epoch-${++_watchSequence}';
    watchId = id;
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
          'Watch check for watchId=$id: use the latest camera frame to assess this visible goal: $watchGoal. '
          'Call report_readiness with watchId=$id and a short observation. Never reuse an older watchId. '
          'Say uncertain if the goal is hidden. '
          'Do not infer internal temperature or food safety.',
        ),
      );
    });
    _notify();
    return id;
  }

  void stopWatch() {
    _watchTimer?.cancel();
    _watchTimer = null;
    watchGoal = null;
    watchId = null;
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
        // Transcription packets are deltas, not cumulative snapshots. Preserve
        // repeated spoken words, but show the latest turn rather than joining
        // every response (including repeated greetings) into one long caption.
        if (isUser) {
          if (text.isNotEmpty) {
            userTranscript = _append(
              _newUserTranscript ? '' : userTranscript,
              text,
            );
            _newUserTranscript = false;
          }
          if (finished) _newUserTranscript = true;
        } else {
          if (text.isNotEmpty) {
            coachTranscript = _append(
              _newCoachTranscript ? '' : coachTranscript,
              text,
            );
            _newCoachTranscript = false;
          }
          if (finished) _newCoachTranscript = true;
        }
        if (finished) notice = null;
      case LiveTurnComplete():
        _newUserTranscript = true;
        _newCoachTranscript = true;
        status = LiveCookingStatus.listening;
      case LiveInterrupted():
        _newCoachTranscript = true;
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
    final invalid = validateLiveTool(call);
    final isReadiness = call.name == 'report_readiness';
    final reportedWatchId = call.arguments['watchId'];
    // Check before the deduplication cache: a repeated old report must not be
    // acknowledged as ready for a newer watch, even if its tool id is known.
    if (invalid != null) {
      result = {'ok': false, 'error': invalid};
    } else if (isReadiness && (watchId == null || reportedWatchId != watchId)) {
      result = {
        'ok': false,
        'error': 'This readiness report belongs to an inactive watch.',
      };
    } else if (isReadiness && !hasFreshFrame) {
      result = {
        'ok': false,
        'error': 'No fresh camera frame for the active watch.',
      };
    } else if (_toolResults[key] case final previous?) {
      result = previous;
    } else if (isReadiness &&
        call.arguments['state'] == 'ready' &&
        _readyReported) {
      result = {'ok': true, 'alreadyReported': true, 'watchId': watchId};
    } else {
      String? startedWatchId;
      try {
        if (call.name == 'watch_cooking') {
          startedWatchId = startWatch(call.arguments['goal'] as String);
        }
        result = await onToolCall(call);
        if (!_current(epoch) || _cancelledTools.contains(call.id)) return;
        if (isReadiness && reportedWatchId != watchId) {
          // Host work may be asynchronous. A completion from the previous
          // watch must not silence/cancel the current watch's next check.
          result = {
            'ok': false,
            'error': 'The active watch changed while this report was handled.',
          };
        } else if (isReadiness &&
            call.arguments['state'] == 'ready' &&
            result['ok'] != false) {
          _readyReported = true;
          _watchTimer?.cancel();
        }
        if (startedWatchId != null) {
          if (result['ok'] == false && watchId == startedWatchId) stopWatch();
          result = {...result, 'watchId': startedWatchId};
        }
      } catch (_) {
        if (startedWatchId != null && watchId == startedWatchId) stopWatch();
        result = {
          'ok': false,
          'error': 'The application could not complete this action.',
        };
      }
      if (!_current(epoch)) return;
      _toolResults[key] = result;
    }
    if (!_current(epoch) || _cancelledTools.contains(call.id)) return;
    try {
      await transport.respondToTool(call, result);
    } catch (_) {
      if (_current(epoch)) {
        await _fail(
          'Live coach disconnected while updating a cooking tool.',
          forEpoch: epoch,
        );
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
              forEpoch: epoch,
            ),
          );
        }
      }),
    );
  }

  Future<void> _fail(String message, {int? forEpoch}) async {
    if (_disposed || (forEpoch != null && !_current(forEpoch))) return;
    final cleanup = stop();
    final failureEpoch = _epoch;
    await cleanup;
    // Stop/reconnect/dispose may have happened while cleanup was pending.
    if (!_current(failureEpoch)) return;
    status = LiveCookingStatus.error;
    error = message;
    _notify();
  }

  Future<void> stop() {
    ++_epoch;
    _watchTimer?.cancel();
    _watchTimer = null;
    watchGoal = null;
    watchId = null;
    _readyReported = false;
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    final transport = _transport;
    _transport = null;
    status = LiveCookingStatus.idle;
    latestFrame = null;
    _frameAt = null;
    final previousCleanup = _stopOperation;
    final cleanup =
        Future.wait([
          ?previousCleanup,
          for (final subscription in subscriptions) subscription.cancel(),
          media.stop(),
          if (transport != null) transport.close(),
        ]).then<void>(
          (_) {},
          onError: (Object _) {
            // Capture shutdown is attempted independently of socket cleanup. Never
            // let an old close failure tear down a newly requested connection.
          },
        );
    _stopOperation = cleanup;
    unawaited(
      cleanup.then((_) {
        if (identical(_stopOperation, cleanup)) _stopOperation = null;
      }),
    );
    _notify();
    return cleanup;
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
    if (_disposed) return;
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
