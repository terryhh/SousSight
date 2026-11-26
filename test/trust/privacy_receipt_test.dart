// SS-105: the receipt's numbers come only from ledger legs.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/live/live_backend_guard.dart' show kLiveFeature;
import 'package:soussight/trust/privacy_receipt.dart';
import 'package:soussight/trust/trust_labels.dart';

import 'trust_test_helpers.dart';

const _photo = {DataKind.image};
const _photoText = {DataKind.image, DataKind.text};

void main() {
  test('the Live feature constant matches the live guard', () {
    expect(kReceiptLiveFeature, kLiveFeature);
  });

  test('zero-cloud night: every answer on this device, nothing left', () {
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.sdkOnDevice, feature: 'pantry_scan'),
      leg(Provenance.sdkOnDevice, feature: 'local_watch', kinds: _photo),
      leg(Provenance.sdkOnDevice, feature: 'local_watch', kinds: _photo),
      leg(Provenance.sdkOnDevice, feature: 'coach_lite'),
    ]);
    expect(r.legCount, 4);
    expect(r.answers, 4);
    expect(r.onDeviceAnswers, 4);
    expect(r.cloudAnswers, 0);
    expect(r.practiceAnswers, 0);
    expect(r.cameraChecksOnDevice, 2);
    expect(r.photosSent, 0);
    expect(r.photosMaybeSent, 0);
    expect(r.unfinished, 0);
    expect(r.nothingLeft, isTrue);
    expect(r.practiceOnly, isFalse);
    expect(r.headline, '4 answers tonight');
    expect(r.summary, '4 answers tonight, 4 on this device; photos sent: 0.');
  });

  test('a night with no legs claims nothing but zero', () {
    final r = PrivacyReceipt.fromLegs(const []);
    expect(r.answers, 0);
    expect(r.headline, 'No AI answers tonight');
    expect(r.nothingLeft, isTrue);
    expect(r.practiceOnly, isFalse);
    expect(r.summary, 'No AI answers tonight; photos sent: 0.');
  });

  test('mixed night: sent photos are counted, listed and explained', () {
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.sdkOnDevice, feature: 'coach_lite'),
      leg(
        Provenance.sdkCloud,
        feature: 'label_check',
        kinds: _photoText,
        mode: HybridMode.preferOnDevice,
      ),
      leg(
        Provenance.sdkCloud,
        feature: 'label_check',
        kinds: _photoText,
        mode: HybridMode.preferOnDevice,
      ),
      leg(Provenance.cloudAdapter, feature: 'pantry_scan', kinds: _photo),
      leg(Provenance.cloudAdapter, feature: 'research'),
      leg(
        Provenance.cloudAdapter,
        feature: 'nearby',
        kinds: {DataKind.location},
      ),
    ]);
    expect(r.answers, 6);
    expect(r.onDeviceAnswers, 1);
    expect(r.cloudAnswers, 5);
    expect(r.photosSent, 3);
    expect(r.cameraChecksOnDevice, 0);
    expect(r.nothingLeft, isFalse);
    expect(r.sent, hasLength(4));
    final label = r.sent.firstWhere((s) => s.feature == 'label_check');
    expect(label.count, 2);
    expect(label.outcome, LegOutcome.cloudSdk);
    expect(label.what, 'Label check · photo and text');
    expect(label.why, 'Tried this device first; Gemini in the cloud answered');
    final pantry = r.sent.firstWhere((s) => s.feature == 'pantry_scan');
    expect(pantry.why, 'Sent to Gemini in the cloud');
    expect(
      r.sent.firstWhere((s) => s.feature == 'research').why,
      'Grounded answers search the web',
    );
    expect(
      r.sent.firstWhere((s) => s.feature == 'nearby').what,
      'Nearby stores · location',
    );
    expect(
      r.sent.firstWhere((s) => s.feature == 'nearby').why,
      'Finding places near you',
    );
    expect(r.summary, contains('1 on this device, 5 from the cloud'));
    expect(r.summary, endsWith('photos sent: 3.'));
  });

  test('unknown provenance is never on-device', () {
    final r = PrivacyReceipt.fromLegs([
      // Allowed to leave, then failed: may have been sent.
      leg(
        Provenance.unknown,
        feature: 'pantry_scan',
        kinds: _photo,
        transferPermitted: true,
        error: HybridErrorCode.network,
      ),
      // Still pending, allowed to leave: also "may have been sent".
      leg(Provenance.unknown, feature: 'coach_lite', transferPermitted: true),
      // Not allowed to leave and failed.
      leg(
        Provenance.unknown,
        feature: 'local_watch',
        kinds: _photo,
        transferPermitted: false,
        error: HybridErrorCode.unavailable,
      ),
      // Not allowed to leave, still running.
      leg(
        Provenance.unknown,
        feature: 'local_watch',
        kinds: _photo,
        transferPermitted: false,
      ),
    ]);
    expect(r.onDeviceAnswers, 0);
    expect(r.cameraChecksOnDevice, 0);
    expect(r.answers, 0);
    expect(r.unfinished, 4);
    expect(r.photosSent, 0);
    expect(r.photosMaybeSent, 1);
    expect(r.maybeSent, hasLength(2));
    expect(r.maybeSent.first.outcome, LegOutcome.maybeSent);
    expect(r.maybeSent.first.why, contains("we can't tell if it was sent"));
    expect(r.nothingLeft, isFalse);
    expect(r.summary, endsWith('photos sent: 0, and 1 may have been sent.'));
  });

  test('simulated legs read as practice, never on this device', () {
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.simulated, feature: 'pantry_scan'),
      leg(Provenance.simulated, feature: 'local_watch', kinds: _photo),
      leg(Provenance.simulated, feature: 'local_watch', kinds: _photo),
    ]);
    expect(r.practiceAnswers, 3);
    expect(r.onDeviceAnswers, 0);
    expect(r.cameraChecksOnDevice, 0);
    expect(r.practiceCameraChecks, 2);
    expect(r.practiceOnly, isTrue);
    expect(r.headline, '3 practice answers tonight');
    expect(r.summary, '3 practice answers tonight; photos sent: 0.');
    final one = PrivacyReceipt.fromLegs([leg(Provenance.simulated)]);
    expect(one.headline, '1 practice answer tonight');
  });

  test('practice mixed with real legs is not practice-only', () {
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.simulated),
      leg(Provenance.sdkOnDevice),
    ]);
    expect(r.practiceOnly, isFalse);
    expect(r.headline, '2 answers tonight');
    expect(
      r.summary,
      '2 answers tonight, 1 on this device, 1 practice; '
      'photos sent: 0.',
    );
    // A practice night where something real left is not "nothing was sent".
    final sent = PrivacyReceipt.fromLegs([
      leg(Provenance.simulated),
      leg(
        Provenance.cloudAdapter,
        feature: 'research',
        error: HybridErrorCode.failed,
      ),
    ]);
    expect(sent.practiceOnly, isFalse);
  });

  test('Live coach legs are sessions, not answers or photos', () {
    final live = {DataKind.audio, DataKind.image, DataKind.text};
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.cloudAdapter, feature: 'live', kinds: live),
      leg(Provenance.cloudAdapter, feature: 'live', kinds: live),
      leg(
        Provenance.unknown,
        feature: 'live',
        kinds: live,
        transferPermitted: true,
        error: HybridErrorCode.network,
      ),
      leg(
        Provenance.unknown,
        feature: 'live',
        kinds: live,
        transferPermitted: false,
        error: HybridErrorCode.blocked,
      ),
      leg(Provenance.sdkOnDevice, feature: 'coach_lite'),
    ]);
    expect(r.liveSessions, 2);
    expect(r.answers, 1);
    expect(r.cloudAnswers, 0);
    expect(r.photosSent, 0);
    expect(r.photosMaybeSent, 0);
    expect(r.unfinished, 0);
    expect(r.sent.single.count, 2);
    expect(r.sent.single.what, 'Live coach · photo, voice clip and text');
    expect(r.sent.single.why, 'The Live coach hears and sees while it is on');
    expect(r.maybeSent.single.feature, 'live');
    expect(r.nothingLeft, isFalse);
    expect(r.summary, contains('2 Live coach sessions'));
    final one = PrivacyReceipt.fromLegs([
      leg(Provenance.cloudAdapter, feature: 'live', kinds: live),
    ]);
    expect(one.summary, contains('1 Live coach session;'));
  });

  test('sent legs that errored still count as sent, not as answers', () {
    final r = PrivacyReceipt.fromLegs([
      leg(
        Provenance.sdkCloud,
        feature: 'label_check',
        kinds: _photo,
        error: HybridErrorCode.blocked,
      ),
      leg(Provenance.sdkOnDevice, error: HybridErrorCode.busy),
      leg(Provenance.simulated, error: HybridErrorCode.failed),
    ]);
    expect(r.answers, 0);
    expect(r.photosSent, 1);
    expect(r.unfinished, 3);
    expect(r.sent.single.count, 1);
    expect(r.practiceOnly, isFalse);
  });

  test('receiptDateLine formats without a locale', () {
    expect(
      receiptDateLine(DateTime(2026, 11, 26, 19, 42)),
      'Thu 26 Nov · 7:42 pm',
    );
    expect(receiptDateLine(DateTime(2026, 1, 4, 0, 5)), 'Sun 4 Jan · 12:05 am');
    expect(
      receiptDateLine(DateTime(2026, 6, 1, 12, 0)),
      'Mon 1 Jun · 12:00 pm',
    );
  });
}
