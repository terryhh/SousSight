import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../data/dinner_messages.dart';
import '../data/dinner_status.dart';

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
  });
  final DinnerKind kind;
  final String sessionId;
  final String recipeTitle;
  final DinnerMessageSender send;
  final DinnerStatusSource statusSource;
  final DinnerAttemptMemory memory;
  final bool isDemo;

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
  final _minutes = TextEditingController(text: '30');
  final _cookName = TextEditingController();
  StreamSubscription<DinnerDeliveryStatus?>? _subscription;
  DinnerDeliveryStatus? _status;
  bool _sending = false;
  String? _validationError;

  bool get _started => widget.kind == DinnerKind.started;
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

  DinnerMessageRequest _request({DinnerSimulation? simulate}) =>
      DinnerMessageRequest(
        sessionId: widget.sessionId,
        notificationId: _attempt.notificationId,
        recipient: _recipient.text.trim(),
        kind: widget.kind,
        recipeTitle: widget.recipeTitle,
        minutes: _started ? int.tryParse(_minutes.text.trim()) : null,
        cookName: _started ? _cookName.text : null,
        simulate: simulate,
      );

  Future<void> _submit({DinnerSimulation? simulate}) async {
    // Guard the callback too: two taps can arrive before a rebuild.
    if (_locked) return;
    final minutes = int.tryParse(_minutes.text.trim());
    if (!RegExp(r'^\+?[1-9][0-9]{7,14}$').hasMatch(_recipient.text.trim()) ||
        (_started && (minutes == null || minutes < 1 || minutes > 120))) {
      setState(
        () => _validationError = _started
            ? 'Enter a full international phone number and 1–120 minutes.'
            : 'Enter a full international phone number.',
      );
      return;
    }
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
      widget.memory.lastRecipient = request.recipient;
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
            if (_started) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _minutes,
                enabled: !_locked,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Minutes until dinner',
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
        if (!_attempt.claimed)
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
          child: Text(widget.isDemo ? 'Rehearse send' : 'Confirm and send'),
        ),
      ],
    );
  }
}
