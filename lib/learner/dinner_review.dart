import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../data/dinner_messages.dart';
import '../data/dinner_mode.dart';
import '../data/dinner_status.dart';
import '../genui/cooking_ui_controller.dart'
    show CookingTimerState, CookingUiController;
import 'step_timers.dart';

export 'step_timers.dart' show isStepTimerFor;

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
/// durations of the steps after it. The current step's time is its step
/// timer's remaining time (zero once it has finished, even if the cook has
/// since dismissed it: pass timers removed after they ran out in
/// [pastTimers], e.g. [DinnerTimerMemory.pastTimers], and the session's saved
/// [finishedStepIds], which survive a reload; its own timer
/// duration if it never started), and never less than the longest running
/// timer. Durations are summed at full precision and rounded up to whole
/// minutes once. Steps with no duration add nothing; if nothing is known at
/// all, or the total is beyond [kMaxDinnerMinutes], [DinnerDraft.minutes] is
/// null rather than a guess. An unknown [currentStepId], or a recipe with no
/// steps that is not complete, is "started" with no estimate, never "ready".
DinnerDraft dinnerDraftFor({
  required List<RecipeStep> steps,
  required String? currentStepId,
  required bool complete,
  required DateTime now,
  Iterable<CookingTimerState> timers = const [],
  Iterable<CookingTimerState> pastTimers = const [],
  Iterable<String> finishedStepIds = const [],
}) {
  if (complete) return const DinnerDraft(DinnerKind.ready);
  final index = steps.indexWhere((s) => s.id == currentStepId);
  if (index < 0) return const DinnerDraft(DinnerKind.started);
  if (index == steps.length - 1) return const DinnerDraft(DinnerKind.ready);

  final current = steps[index];
  var longestRunning = Duration.zero;
  for (final timer in timers) {
    final left = timer.remaining(now);
    if (left > longestRunning) longestRunning = left;
  }
  // The step's own timer: a running one (the latest started) wins; else a
  // saved "finished" marker (it ran out and was dismissed, even before a
  // reload); else the latest dismissed-after-finishing timer on this screen.
  CookingTimerState? latest(Iterable<CookingTimerState> candidates) {
    CookingTimerState? found;
    for (final timer in candidates) {
      if (!isStepTimerFor(timer.id, current.id)) continue;
      if (found == null || timer.startedAt.isAfter(found.startedAt)) {
        found = timer;
      }
    }
    return found;
  }

  final running = latest(timers);
  final Duration currentLeft;
  if (running != null) {
    currentLeft = running.remaining(now);
  } else if (finishedStepIds.contains(current.id)) {
    currentLeft = Duration.zero;
  } else {
    currentLeft =
        latest(pastTimers)?.remaining(now) ?? _duration(current.timerSeconds);
  }
  var total = currentLeft > longestRunning ? currentLeft : longestRunning;
  for (final step in steps.skip(index + 1)) {
    total += _duration(step.timerSeconds);
  }
  if (total <= Duration.zero) return const DinnerDraft(DinnerKind.started);
  final minutes = (total.inMicroseconds / Duration.microsecondsPerMinute)
      .ceil();
  return DinnerDraft(
    DinnerKind.started,
    minutes: minutes > kMaxDinnerMinutes ? null : minutes,
  );
}

Duration _duration(int? seconds) =>
    seconds != null && seconds > 0 ? Duration(seconds: seconds) : Duration.zero;

/// Remembers which timers had run out when they were removed, so a step timer
/// the cook dismissed after it finished still tells [dinnerDraftFor] that the
/// step's time is used up. A timer cancelled while it still had time left is
/// forgotten: cancelling is not cooking, so that step's time still counts.
/// Attach it when the cooking screen starts.
class DinnerTimerMemory {
  final Map<String, CookingTimerState> _running = {};
  final Map<String, CookingTimerState> _finished = {};
  CookingUiController? _ui;

  /// Timers removed after they had run out (dismissed when finished).
  Iterable<CookingTimerState> get pastTimers => _finished.values;

  void attach(CookingUiController ui) {
    detach();
    _ui = ui;
    ui.addListener(_observe);
    _observe();
  }

  void detach() {
    _ui?.removeListener(_observe);
    _ui = null;
    _running.clear();
  }

  void _observe() {
    final ui = _ui;
    if (ui == null) return;
    // Judged at the moment of removal, not later: a cancelled timer whose
    // deadline passes afterwards never counts as finished.
    final now = ui.clock();
    final current = {for (final timer in ui.timers) timer.id: timer};
    for (final MapEntry(key: id, value: timer) in _running.entries) {
      if (current.containsKey(id)) continue;
      if (!timer.deadline.isAfter(now)) _finished[id] = timer;
    }
    _running
      ..clear()
      ..addAll(current);
  }
}

/// The latest cook-confirmed attempt of each kind. Reopening the review shows
/// that attempt's live status instead of minting a stale or duplicate send.
///
/// It outlives the dialog: a send the cook confirmed keeps going after the
/// dialog is dismissed, and a reopened dialog listens for its outcome.
class DinnerAttempt extends ChangeNotifier {
  DinnerAttempt({required this.notificationId});
  final String notificationId;
  String recipient = '';
  bool claimed = false;

  /// The request the cook confirmed, snapshotted before the send is awaited.
  /// From then on the attempt is locked to it: a reopened dialog shows these
  /// slots (and its preview), never a fresh estimate or an edit, even when
  /// the response was lost and [result] is null.
  DinnerMessageRequest? confirmed;
  DinnerMessageResult? result;
  String? outcome;

  /// Confirmed, and the send has not finished yet.
  bool get pending => confirmed != null && !claimed;

  /// Tells an open dialog that the attempt changed.
  void changed() => notifyListeners();
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
    text:
        (_attempt.confirmed != null
                ? _attempt.confirmed!.minutes
                : widget.initialMinutes)
            ?.toString() ??
        '',
  );
  late final _cookName = TextEditingController(
    text: _attempt.confirmed?.cookName ?? '',
  );
  StreamSubscription<DinnerDeliveryStatus?>? _subscription;
  DinnerDeliveryStatus? _status;
  bool _sending = false;
  String? _validationError;

  bool get _started => widget.kind == DinnerKind.started;
  bool get _simulated => widget.mode == DinnerMode.simulated;
  bool get _locked => _attempt.claimed || _attempt.pending || _sending;

  @override
  void initState() {
    super.initState();
    _minutes.addListener(_refresh);
    _cookName.addListener(_refresh);
    _attempt.addListener(_onAttempt);
    if (_attempt.claimed) _watch();
  }

  void _refresh() => setState(() {});

  /// A send confirmed in an earlier (dismissed) dialog finished.
  void _onAttempt() {
    if (!mounted) return;
    if (_attempt.claimed && _subscription == null) _watch();
    setState(() {});
  }

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
    _attempt.removeListener(_onAttempt);
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
    attempt
      ..confirmed = request
      ..changed();
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
    } on DinnerValidationException catch (error) {
      // Nothing was claimed; the same ID may be confirmed again after edits.
      attempt.confirmed = null;
      if (mounted) setState(() => _validationError = error.explanation);
    } on DinnerConflictException catch (error) {
      attempt
        ..claimed = true
        ..outcome = error.explanation;
    } catch (_) {
      attempt
        ..claimed = true
        ..outcome = 'Message status could not be confirmed. No automatic resend will occur.';
    } finally {
      if (mounted) setState(() => _sending = false);
      // Open dialogs on this attempt (this one or a reopened one) watch it.
      attempt.changed();
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
    _subscription = null;
    _attempt.removeListener(_onAttempt);
    setState(() {
      _attempt = widget.memory.startNew(widget.kind)..addListener(_onAttempt);
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
    final preview =
        _attempt.result?.message ??
        _attempt.confirmed?.preview ??
        _request().preview;
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
            if (_attempt.pending && !_sending)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Sending the message you confirmed. It will not be sent '
                  'again.',
                  key: Key('dinner-pending'),
                ),
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
