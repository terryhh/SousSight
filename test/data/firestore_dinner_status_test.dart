// The cook's delivery status view reads what Cloud Functions write to
// sessions/{id}/notifications/{id}. In-memory Firestore only: this proves the
// path and the mapping, not the security rules (see test/rules).

import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/data/dinner_status.dart';

void main() {
  test(
    'streams null until the server writes, then each status change',
    () async {
      final db = FakeFirebaseFirestore();
      final updates = StreamIterator(
        FirestoreDinnerStatusSource(db).watch('session-1', 'notice-1'),
      );
      final doc = db
          .collection('sessions')
          .doc('session-1')
          .collection('notifications')
          .doc('notice-1');

      expect(await updates.moveNext(), isTrue);
      expect(updates.current, isNull, reason: 'nothing written yet');

      await doc.set({'status': 'pending', 'kind': 'ready'});
      expect(await updates.moveNext(), isTrue);
      expect(updates.current!.status, 'pending');
      expect(updates.current!.kind, 'ready');
      expect(updates.current!.isUncertain, isTrue);
      expect(updates.current!.isFailure, isFalse);

      await doc.set({
        'status': 'rejected',
        'errorTitle': 'Illegal Sender Address',
        'errorCode': '1120',
        'simulated': true,
      });
      expect(await updates.moveNext(), isTrue);
      final rejected = updates.current!;
      expect(rejected.isFailure, isTrue);
      expect(rejected.simulated, isTrue);
      expect(
        rejected.label,
        '$simulatedLabel Not delivered: Illegal Sender Address (error 1120)',
      );
      await updates.cancel();
    },
  );

  test('another notification or session is not mixed in', () async {
    final db = FakeFirebaseFirestore();
    await db
        .collection('sessions')
        .doc('session-2')
        .collection('notifications')
        .doc('notice-1')
        .set({'status': 'delivered'});
    final status = await FirestoreDinnerStatusSource(db)
        .watch('session-1', 'notice-1')
        .first;
    expect(status, isNull);
  });

  test('a document without a status is uncertain, never delivered', () async {
    final db = FakeFirebaseFirestore();
    await db
        .collection('sessions')
        .doc('s')
        .collection('notifications')
        .doc('n')
        .set({'kind': 'started'});
    final status = await FirestoreDinnerStatusSource(db).watch('s', 'n').first;
    expect(status!.status, 'unknown');
    expect(status.isUncertain, isTrue);
    expect(status.label, contains('uncertain'));
  });
}
