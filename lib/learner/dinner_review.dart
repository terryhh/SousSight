import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../data/dinner_messages.dart';
import '../data/dinner_mode.dart';
import '../data/dinner_status.dart';
import '../genui/cooking_ui_controller.dart' show CookingTimerState;

/// Which household message fits where the cook is (SS-100), and a suggested
/// "minutes to go" for it. The cook still reviews and edits it; nothing here
/// sends anything.
class DinnerDraft {
  const DinnerDraft(this.kind, {this.minutes});
  final DinnerKind kind;

  /// Null when the remaining time is unknown: the message leaves it out.
  final int? minutes;
}

/// The longest estimate the message template accepts (server: 1-120).
const kMaxDinnerMinutes = 120;

/// Picks the message from the cook's step: before the final step it is
/// "Dinner's started" with an estimate; on the final step, or once the
/// recipe is complete, it is "Dinner is ready!".
///
/// The estimate is the time left on the current step plus the timer
/// durations of the steps after it. The current step's time is its running
/// step timer's remaining time (zero once it has finished; its own timer
/// duration if it has not started), and never less than the longest running
/// timer. Steps with no
/// duration add nothing; if nothing is known at all, or the total is beyond
/// [kMaxDinnerMinutes], [DinnerDraft.minutes] is null rather than a guess.
/// An unknown [currentStepId] is treated as "started", never as "ready".
DinnerDraft dinnerDraftFor({
  required List<RecipeStep> steps,
  required String? currentStepId,
  required bool complete,
  required DateTime now,
  Iterable<CookingTimerState> timers = const [],
}) {
  if (complete || steps.isEmpty) return const DinnerDraft(DinnerKind.ready);
  final index = steps.indexWhere((s) => s.id == currentStepId);
  if (index == steps.length - 1) return const DinnerDraft(DinnerKind.ready);
  if (index < 0) return const DinnerDraft(DinnerKind.started);

  final current = steps[index];
  final stepPrefix = 'step-${current.id}';
  Duration? stepTimer;
  var longestRunning = Duration.zero;
  for (final timer in timers) {
    final left = timer.remaining(now);
    // A finished step timer still counts: that step has no time left.
    if (timer.id == stepPrefix || timer.id.startsWith('$stepPrefix-')) {
      if (stepTimer == null || left > stepTimer) stepTimer = left;
    }
    if (left > longestRunning) longestRunning = left;
  }
  // Every known duration is positive, so a known total is at least 1 s.
  final currentSeconds =
      stepTimer?.inSeconds ?? _positive(current.timerSeconds) ?? 0;
  var seconds = currentSeconds > longestRunning.inSeconds
      ? currentSeconds
      : longestRunning.inSeconds;
  for (final step in steps.skip(index + 1)) {
    seconds += _positive(step.timerSeconds) ?? 0;
  }
  if (seconds <= 0) return const DinnerDraft(DinnerKind.started);
  final minutes = (seconds / 60).ceil();
  return DinnerDraft(
    DinnerKind.started,
    minutes: minutes > kMaxDinnerMinutes ? null : minutes,
  );
}

int? _positive(int? seconds) => seconds != null && seconds > 0 ? seconds : null;

/// The latest cook-confirmed attempt of each kind. Reopening the review shows
/// that attempt's live status instead of minting a stale or duplicate send.
class DinnerAttempt {
  DinnerAttempt({required this.notificationId});
  final String notificationId;
  String recipient = '';
  bool claimed = false;
  DinnerMessageResult? result;
  String? outcome;
}

class DinnerAttemptMemory {
  final Map<DinnerKind, DinnerAttempt> _attempts = {};
  String lastRecipient = '';
  DinnerAttempt current(DinnerKind kind) => _attempts.putIfAbsent(
    kind,
    () => DinnerAttempt(notificationId: const Uuid().v4()),
  );

  /// Only called after a KNOWN failure, from an explicit cook tap.
  DinnerAttempt startNew(DinnerKind kind) =>
      _attempts[kind] = DinnerAttempt(notificationId: const Uuid().v4());
}

Future<void> showDinnerReview(
  BuildContext context, {
  required DinnerKind kind,
  required String sessionId,
  required String recipeTitle,
  required DinnerMessageSender send,
  required DinnerStatusSource statusSource,
  required DinnerAttemptMemory memory,
  required bool isDemo,
  DinnerMode mode = DinnerMode.real,
  int? initialMinutes,
}) => showDialog<void>(
  context: context,
  builder: (_) => DinnerReviewDialog(
    kind: kind,
    sessionId: sessionId,
    recipeTitle: recipeTitle,
    send: send,
    statusSource: statusSource,
    memory: memory,
    isDemo: isDemo,
    mode: mode,
    initialMinutes: initialMinutes,
  ),
);

class DinnerReviewDialog extends StatefulWidget {
  const DinnerReviewDialog({
    super.key,
    required this.kind,
    required this.sessionId,
    required this.recipeTitle,
    required this.send,
    required this.statusSource,
    required this.memory,
    required this.isDemo,
    this.mode = DinnerMode.real,
    this.initialMinutes,
  });
  final DinnerKind kind;
  final String sessionId;
  final String recipeTitle;
  final DinnerMessageSender send;
  final DinnerStatusSource statusSource;
  final DinnerAttemptMemory memory;
  final bool isDemo;

  /// [DinnerMode.simulated] shows the fictional [simulatedDinnerRecipient]
  /// instead of a phone field; the cook still reviews and confirms. Pair it
  /// with a sender and status source from `dinnerSenderFor`/`dinnerStatusFor`.
  final DinnerMode mode;

  /// The suggested "minutes to go" for a started message (see
  /// [dinnerDraftFor]); the cook can change or clear it. Null starts blank,
  /// and a blank field leaves the time out of the message.
  final int? initialMinutes;

  @override
  State<DinnerReviewDialog> createState() => _DinnerReviewDialogState();
}

class _DinnerReviewDialogState extends State<DinnerReviewDialog> {
  late DinnerAttempt _attempt = widget.memory.current(widget.kind);
  late final _recipient = TextEditingController(
    text: _attempt.recipient.isNotEmpty
        ? _attempt.recipient
        : widget.memory.lastRecipient,
  );
  late final _minutes = TextEditingController(
    text: widget.initialMinutes?.toString() ?? '',
  );
  final _cookName = TextEditingController();
  StreamSubscription<DinnerDeliveryStatus?>? _subscription;
  DinnerDeliveryStatus? _status;
  bool _sending = false;
  String? _validationError;

  bool get _started => widget.kind == DinnerKind.started;
  bool get _simulated => widget.mode == DinnerMode.simulated;
  bool get _locked => _attempt.claimed || _sending;

  @override
  void initState() {
    super.initState();
    _minutes.addListener(_refresh);
    _cookName.addListener(_refresh);
    if (_attempt.claimed) _watch();
  }

  void _refresh() => setState(() {});

  void _watch() {
    unawaited(_subscription?.cancel());
    _subscription = widget.statusSource
        .watch(widget.sessionId, _attempt.notificationId)
        .listen(
          (status) {
            if (mounted && status != null) setState(() => _status = status);
          },
          onError: (Object _) {
            // Status is informational; keep the last known value.
          },
        );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _recipient.dispose();
    _minutes.dispose();
    _cookName.dispose();
    super.dispose();
  }

  /// Blank means "unknown": the message leaves the time out.
  int? get _minutesValue => int.tryParse(_minutes.text.trim());

  bool get _badMinutes {
    if (!_started) return false;
    final text = _minutes.text.trim();
    if (text.isEmpty) return false;
    final minutes = int.tryParse(text);
    return minutes == null || minutes < 1 || minutes > kMaxDinnerMinutes;
  }

  DinnerMessageRequest _request({DinnerSimulation? simulate}) =>
      DinnerMessageRequest(
        sessionId: widget.sessionId,
        notificationId: _attempt.notificationId,
        recipient: _simulated
            ? simulatedDinnerRecipient
            : _recipient.text.trim(),
        kind: widget.kind,
        recipeTitle: widget.recipeTitle,
        minutes: _started ? _minutesValue : null,
        cookName: _started ? _cookName.text : null,
        simulate: simulate,
      );

  Future<void> _submit({DinnerSimulation? simulate}) async {
    // Guard the callback too: two taps can arrive before a rebuild.
    if (_locked) return;
    final badMinutes = _badMinutes;
    if (_simulated && badMinutes) {
      setState(
        () => _validationError = 'Enter 1–120 minutes, or leave it blank.',
      );
      return;
    }
    if (!_simulated &&
        (!RegExp(r'^\+?[1-9][0-9]{7,14}$').hasMatch(_recipient.text.trim()) ||
            badMinutes)) {
      setState(
        () => _validationError = _started
            ? 'Enter a full international phone number, and 1–120 minutes '
                  'or leave minutes blank.'
            : 'Enter a full international phone number.',
      );
      return;
    }
    // Simulated mode: a plain confirm is a simulated delivery, never a send.
    if (_simulated) simulate ??= DinnerSimulation.delivered;
    final attempt = _attempt;
    final request = _request(simulate: simulate);
    setState(() {
      _sending = true;
      _validationError = null;
    });
    try {
      final result = await widget.send(request);
      attempt
        ..claimed = true
        ..recipient = request.recipient
        ..result = result;
      if (!_simulated) widget.memory.lastRecipient = request.recipient;
      if (mounted && identical(attempt, _attempt)) _watch();
    } on DinnerValidationException catch (error) {
      // Nothing was claimed; the same ID may be confirmed again after edits.
      if (mounted) setState(() => _validationError = error.explanation);
    } on DinnerConflictException catch (error) {
      attempt
        ..claimed = true
        ..outcome = error.explanation;
      if (mounted) _watch();
    } catch (_) {
      attempt
        ..claimed = true
        ..outcome = 'Message status could not be confirmed. No automatic resend will occur.';
      if (mounted) _watch();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  DinnerDeliveryStatus? get _effectiveStatus {
    if (_status != null) return _status;
    final result = _attempt.result;
    if (result == null) return null;
    final status = result.deliveryStatus ?? result.status;
    final simulatedFailure =
        result.simulated && (status == 'rejected' || status == 'undeliverable');
    return DinnerDeliveryStatus(
      status: status,
      kind: widget.kind.name,
      errorTitle: simulatedFailure ? 'Illegal Sender Address' : null,
      errorCode: simulatedFailure ? '1120' : null,
      simulated: result.simulated,
    );
  }

  void _startNewMessage() {
    // Explicit cook action after a KNOWN failure: a new notification ID, never
    // a resend of the old one, and nothing is sent until the cook confirms.
    unawaited(_subscription?.cancel());
    setState(() {
      _attempt = widget.memory.startNew(widget.kind);
      _status = null;
      _validationError = null;
    });
  }

  Future<void> _copy(String preview) async {
    await Clipboard.setData(ClipboardData(text: preview));
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('Message copied.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _effectiveStatus;
    final preview = _attempt.result?.message ?? _request().preview;
    final failed = status?.isFailure ?? false;
    final outcome = _attempt.outcome;
    return AlertDialog(
      title: Text(
        _started ? 'Text household: started cooking' : 'Dinner is ready',
      ),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_simulated) ...[
              const Text(
                '$simulatedLabel This build simulates household messages. '
                'Review the exact message, then confirm.',
                key: Key('dinner-simulated-notice'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Recipient: $simulatedDinnerRecipient (fictional)',
                key: Key('dinner-simulated-recipient'),
              ),
            ] else ...[
              const Text(
                'Choose your configured household contact and review the exact message.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _recipient,
                enabled: !_locked,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Recipient',
                  hintText: '+14075550123',
                ),
              ),
            ],
            if (_started) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _minutes,
                enabled: !_locked,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Minutes until dinner',
                  helperText: "Leave blank if you're not sure.",
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _cookName,
                enabled: !_locked,
                maxLength: 30,
                decoration: const InputDecoration(
                  labelText: 'Your name (optional)',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text('Message', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(preview, key: const Key('dinner-preview')),
            if (_validationError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_validationError!),
              ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(status.label, key: const Key('dinner-status')),
              )
            else if (outcome != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(outcome, key: const Key('dinner-status')),
              ),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _startNewMessage,
                      child: const Text('Edit and send as new message'),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_copy(preview)),
                      child: const Text('Copy message'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        // Zero-cost demo: the server never contacts Vonage for these and
        // labels every resulting status "Simulated — no SMS sent".
        // In simulated mode the primary button already simulates delivery.
        if (!_attempt.claimed && !_simulated)
          OutlinedButton(
            onPressed: _locked
                ? null
                : () =>
                      unawaited(_submit(simulate: DinnerSimulation.delivered)),
            child: const Text('Simulate delivery (demo)'),
          ),
        if (!_attempt.claimed)
          OutlinedButton(
            onPressed: _locked
                ? null
                : () => unawaited(_submit(simulate: DinnerSimulation.rejected)),
            child: const Text('Simulate failed delivery (demo)'),
          ),
        FilledButton(
          onPressed: _locked ? null : () => unawaited(_submit()),
          child: Text(
            _simulated
                ? 'Confirm simulated send'
                : widget.isDemo
                ? 'Rehearse send'
                : 'Confirm and send',
          ),
        ),
      ],
    );
  }
}
