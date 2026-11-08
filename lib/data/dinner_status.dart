import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'dinner_messages.dart';

/// Cook-readable mirror of a household message, written only by Cloud
/// Functions at `sessions/{sessionId}/notifications/{notificationId}`.
class DinnerDeliveryStatus {
  const DinnerDeliveryStatus({
    required this.status,
    this.kind,
    this.errorTitle,
    this.errorCode,
    this.reason,
    this.simulated = false,
  });

  factory DinnerDeliveryStatus.fromMap(Map<String, dynamic> map) =>
      DinnerDeliveryStatus(
        status: map['status'] as String? ?? 'unknown',
        kind: map['kind'] as String?,
        errorTitle: map['errorTitle'] as String?,
        errorCode: map['errorCode'] as String?,
        reason: map['reason'] as String?,
        simulated: map['simulated'] == true,
      );

  /// pending | submitted | skipped | failed | unknown (send outcome) or
  /// delivered | read | rejected | undeliverable (Vonage status webhook).
  final String status;
  final String? kind;
  final String? errorTitle;
  final String? errorCode;
  final String? reason;
  final bool simulated;

  bool get isFailure =>
      status == 'failed' || status == 'rejected' || status == 'undeliverable';
  bool get isUncertain => status == 'unknown' || status == 'pending';

  String get label {
    final text = switch (status) {
      'pending' => 'Sending to Vonage…',
      'submitted' => 'Sent to Vonage. Waiting for a delivery report.',
      'delivered' => 'Delivered ✓',
      'read' => 'Read',
      'rejected' || 'undeliverable' =>
        'Not delivered: ${errorTitle ?? 'Vonage reported a failure'}'
            '${errorCode == null ? '' : ' (error $errorCode)'}',
      'failed' => 'Not sent: Vonage did not accept the message.',
      'skipped' => 'Rehearsal only: no message was sent.',
      _ => 'The delivery state is uncertain. We will not resend automatically.',
    };
    return simulated ? '$simulatedLabel $text' : text;
  }
}

/// Prefix on every simulated status so a demo can never pass for a real SMS.
const simulatedLabel = 'Simulated — no SMS sent.';

abstract interface class DinnerStatusSource {
  Stream<DinnerDeliveryStatus?> watch(String sessionId, String notificationId);
}

class FirestoreDinnerStatusSource implements DinnerStatusSource {
  FirestoreDinnerStatusSource([FirebaseFirestore? db])
    : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  @override
  Stream<DinnerDeliveryStatus?> watch(
    String sessionId,
    String notificationId,
  ) => _db
      .collection('sessions')
      .doc(sessionId)
      .collection('notifications')
      .doc(notificationId)
      .snapshots()
      .map((snapshot) {
        final data = snapshot.data();
        return data == null ? null : DinnerDeliveryStatus.fromMap(data);
      });
}

/// Visibly simulated backend for FAKE_BACKEND builds and widget tests. Real
/// sends become rehearsals; `simulate` follows the server's demo path.
class FakeDinnerBackend implements DinnerStatusSource {
  final _controllers = <String, StreamController<DinnerDeliveryStatus?>>{};
  final _latest = <String, DinnerDeliveryStatus>{};
  final List<DinnerMessageRequest> sent = [];

  StreamController<DinnerDeliveryStatus?> _controller(String key) =>
      _controllers.putIfAbsent(
        key,
        () => StreamController<DinnerDeliveryStatus?>.broadcast(),
      );

  /// Publishes a status as if the server mirror changed.
  void emit(String sessionId, String notificationId, DinnerDeliveryStatus s) {
    final key = '$sessionId/$notificationId';
    _latest[key] = s;
    _controller(key).add(s);
  }

  @override
  Stream<DinnerDeliveryStatus?> watch(
    String sessionId,
    String notificationId,
  ) async* {
    final key = '$sessionId/$notificationId';
    yield _latest[key];
    yield* _controller(key).stream;
  }

  Future<DinnerMessageResult> send(DinnerMessageRequest request) async {
    sent.add(request);
    final kind = request.kind.name;
    final simulate = request.simulate;
    if (simulate != null) {
      final rejected = simulate == DinnerSimulation.rejected;
      emit(
        request.sessionId,
        request.notificationId,
        DinnerDeliveryStatus(
          status: simulate.name,
          kind: kind,
          errorTitle: rejected ? 'Illegal Sender Address' : null,
          errorCode: rejected ? '1120' : null,
          simulated: true,
        ),
      );
      return DinnerMessageResult(
        'submitted',
        'demo',
        message: request.preview,
        deliveryStatus: simulate.name,
        simulated: true,
      );
    }
    emit(
      request.sessionId,
      request.notificationId,
      DinnerDeliveryStatus(status: 'skipped', kind: kind),
    );
    return DinnerMessageResult('skipped', 'demo', message: request.preview);
  }

  Future<void> dispose() async {
    for (final controller in _controllers.values) {
      await controller.close();
    }
  }
}
