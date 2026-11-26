// SS-105: the receipt's numbers come only from ledger legs.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/live/live_backend_guard.dart'
    show kLiveFeature, kLiveLegKinds;
import 'package:soussight/trust/privacy_receipt.dart';
import 'package:soussight/trust/trust_labels.dart';

import 'trust_test_helpers.dart';

const _photo = {DataKind.image};
const _photoText = {DataKind.image, DataKind.text};

void main() {
  test('the Live feature constant matches the live guard', () {
    expect(kReceiptLiveFeature, kLiveFeature);
  });

  test('zero-cloud night: every run on this device, nothing recorded left', () {
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.sdkOnDevice, feature: 'pantry_scan'),
      leg(Provenance.sdkOnDevice, feature: 'local_watch', kinds: _photo),
      leg(Provenance.sdkOnDevice, feature: 'local_watch', kinds: _photo),
      leg(Provenance.sdkOnDevice, feature: 'coach_lite'),
    ]);
    expect(r.legCount, 4);
    expect(r.runs, 4);
    expect(r.onDeviceRuns, 4);
    expect(r.cloudRuns, 0);
    expect(r.practiceRuns, 0);
    expect(r.cameraChecksOnDevice, 2);
    expect(r.photoRequestsSent, 0);
    expect(r.photoRequestsMaybeSent, 0);
    expect(r.unfinished, 0);
    expect(r.inProgress, 0);
    expect(r.nothingRecordedLeft, isTrue);
    expect(r.practiceOnly, isFalse);
    expect(r.headline, '4 AI runs tonight');
    expect(
      r.summary,
      '4 AI runs tonight, 4 on this device; '
      'recorded requests that sent photos: 0.',
    );
  });

  test('a night with no legs claims nothing but zero', () {
    final r = PrivacyReceipt.fromLegs(const []);
    expect(r.runs, 0);
    expect(r.headline, 'No finished AI runs recorded tonight');
    expect(r.nothingRecordedLeft, isTrue);
    expect(r.practiceOnly, isFalse);
    expect(r.allSimulated, isFalse);
  });

  test('a run is counted per finished leg, not as an accepted answer', () {
    // The dispatcher's semantic retry: a local result the feature rejected,
    // then a cloud result it also rejected. Both legs ran; neither was an
    // accepted answer, so the receipt says "runs", and keeps both legs.
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.sdkOnDevice, feature: 'pantry_scan'),
      leg(Provenance.sdkCloud, feature: 'pantry_scan'),
    ]);
    expect(r.runs, 2);
    expect(r.headline, '2 AI runs tonight');
    expect(r.sent.single.feature, 'pantry_scan');
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
      leg(
        Provenance.sdkCloud,
        feature: 'coach_lite',
        mode: HybridMode.preferInCloud,
      ),
      const InferenceLeg(
        requestId: 'no-mode',
        feature: 'coach_lite',
        mode: null,
        kinds: {DataKind.text},
        transferPermitted: true,
        provenance: Provenance.sdkCloud,
      ),
    ]);
    expect(r.runs, 8);
    expect(r.onDeviceRuns, 1);
    expect(r.cloudRuns, 7);
    expect(r.photoRequestsSent, 3);
    expect(r.cameraChecksOnDevice, 0);
    expect(r.nothingRecordedLeft, isFalse);
    final label = r.sent.firstWhere((s) => s.feature == 'label_check');
    expect(label.count, 2);
    expect(label.outcome, LegOutcome.cloudSdk);
    expect(label.what, 'Label check · photo and text');
    // The observed result first; the requested preference separately.
    expect(
      label.why,
      'Ran on Gemini in the cloud · asked to prefer this device',
    );
    expect(label.why, isNot(contains('Tried')));
    expect(
      r.sent.firstWhere((s) => s.feature == 'pantry_scan').why,
      "Sent by SousSight's cloud client · asked for the cloud",
    );
    expect(
      r.sent.firstWhere((s) => s.feature == 'research').why,
      "Sent by SousSight's cloud client to search the web · asked for the "
      'cloud',
    );
    final nearby = r.sent.firstWhere((s) => s.feature == 'nearby');
    expect(nearby.what, 'Nearby stores · location');
    expect(nearby.why, contains('to find places near you'));
    final coach = r.sent.where((s) => s.feature == 'coach_lite').toList();
    expect(coach.map((s) => s.why), {
      'Ran on Gemini in the cloud · asked to prefer the cloud',
      'Ran on Gemini in the cloud',
    });
    expect(r.summary, contains('1 on this device, 7 in the cloud'));
    expect(r.summary, endsWith('recorded requests that sent photos: 3.'));
  });

  test('an on-device-only request that reached the cloud says so', () {
    final r = PrivacyReceipt.fromLegs([
      leg(
        Provenance.sdkCloud,
        feature: 'coach_lite',
        mode: HybridMode.onlyOnDevice,
      ),
    ]);
    expect(
      r.sent.single.why,
      'Ran on Gemini in the cloud · asked for this device only',
    );
  });

  test('unknown provenance is never on-device; pending is not "stopped"', () {
    final r = PrivacyReceipt.fromLegs([
      // Allowed to leave, then failed: may have been sent.
      leg(
        Provenance.unknown,
        feature: 'pantry_scan',
        kinds: _photo,
        transferPermitted: true,
        error: HybridErrorCode.network,
      ),
      // Still pending, allowed to leave (InferenceLedger.begin's state).
      leg(
        Provenance.unknown,
        feature: 'label_check',
        kinds: _photo,
        transferPermitted: true,
      ),
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
    expect(r.onDeviceRuns, 0);
    expect(r.cameraChecksOnDevice, 0);
    expect(r.runs, 0);
    expect(r.unfinished, 2);
    expect(r.inProgress, 2);
    expect(r.photoRequestsSent, 0);
    expect(r.photoRequestsMaybeSent, 2);
    expect(r.maybeSent, hasLength(2));
    final stopped = r.maybeSent.firstWhere((s) => s.feature == 'pantry_scan');
    expect(stopped.pending, isFalse);
    expect(stopped.why, contains("we can't tell if it was sent"));
    final running = r.maybeSent.firstWhere((s) => s.feature == 'label_check');
    expect(running.pending, isTrue);
    expect(running.outcome, LegOutcome.maybeSent);
    expect(running.why, 'Still running: allowed to leave, not finished yet');
    expect(running.why, isNot(contains('stopped')));
    expect(r.nothingRecordedLeft, isFalse);
    expect(
      r.summary,
      endsWith('recorded requests that sent photos: 0, and 2 more may have.'),
    );
  });

  test('simulated legs read as practice, never on this device', () {
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.simulated, feature: 'pantry_scan'),
      leg(Provenance.simulated, feature: 'local_watch', kinds: _photo),
      leg(Provenance.simulated, feature: 'local_watch', kinds: _photo),
    ]);
    expect(r.practiceRuns, 3);
    expect(r.onDeviceRuns, 0);
    expect(r.cameraChecksOnDevice, 0);
    expect(r.practiceCameraChecks, 2);
    expect(r.allSimulated, isTrue);
    expect(r.practiceOnly, isTrue);
    expect(r.headline, '3 practice runs tonight');
    expect(
      r.summary,
      '3 practice runs tonight; recorded requests that sent photos: 0.',
    );
    final one = PrivacyReceipt.fromLegs([leg(Provenance.simulated)]);
    expect(one.headline, '1 practice run tonight');
    // An errored simulated leg is still simulated.
    expect(
      PrivacyReceipt.fromLegs([
        leg(Provenance.simulated),
        leg(Provenance.simulated, error: HybridErrorCode.failed),
      ]).practiceOnly,
      isTrue,
    );
  });

  test('practice is practice-only only when every leg is simulated', () {
    final mixed = PrivacyReceipt.fromLegs([
      leg(Provenance.simulated),
      leg(Provenance.sdkOnDevice),
    ]);
    expect(mixed.practiceOnly, isFalse);
    expect(mixed.headline, '2 AI runs tonight');
    expect(
      mixed.summary,
      '2 AI runs tonight, 1 on this device, 1 practice; '
      'recorded requests that sent photos: 0.',
    );
    // A real local-only timeout cannot establish that no model ran.
    final timeout = PrivacyReceipt.fromLegs([
      leg(Provenance.simulated),
      leg(
        Provenance.unknown,
        transferPermitted: false,
        error: HybridErrorCode.timeout,
      ),
    ]);
    expect(timeout.practiceOnly, isFalse);
    expect(timeout.allSimulated, isFalse);
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

  test('Live coach legs are connections, not runs or photos', () {
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.cloudAdapter, feature: 'live', kinds: kLiveLegKinds),
      leg(Provenance.cloudAdapter, feature: 'live', kinds: kLiveLegKinds),
      leg(
        Provenance.unknown,
        feature: 'live',
        kinds: kLiveLegKinds,
        transferPermitted: true,
        error: HybridErrorCode.network,
      ),
      leg(
        Provenance.unknown,
        feature: 'live',
        kinds: kLiveLegKinds,
        transferPermitted: false,
        error: HybridErrorCode.blocked,
      ),
      leg(Provenance.sdkOnDevice, feature: 'coach_lite'),
    ]);
    expect(r.liveConnections, 2);
    expect(r.runs, 1);
    expect(r.cloudRuns, 0);
    expect(r.photoRequestsSent, 0);
    expect(r.photoRequestsMaybeSent, 0);
    expect(r.unfinished, 0);
    expect(r.sent.single.count, 2);
    expect(r.sent.single.what, 'Live coach · connection');
    // Its media capability, not a claim about what it saw.
    expect(
      r.sent.single.why,
      'While connected it can receive your camera, voice and text',
    );
    expect(r.sent.single.why, isNot(contains('saw')));
    expect(r.maybeSent.single.feature, 'live');
    expect(r.summary, contains('2 Live coach connections'));
    final one = PrivacyReceipt.fromLegs([
      leg(Provenance.cloudAdapter, feature: 'live', kinds: {DataKind.audio}),
    ]);
    expect(one.summary, contains('1 Live coach connection;'));
    expect(one.sent.single.why, 'While connected it can receive your voice');
    expect(
      PrivacyReceipt.fromLegs([
        leg(Provenance.cloudAdapter, feature: 'live', kinds: const {}),
      ]).sent.single.why,
      'While connected it can receive your nothing',
    );
    expect(
      PrivacyReceipt.fromLegs([
        leg(
          Provenance.cloudAdapter,
          feature: 'live',
          kinds: {DataKind.location, DataKind.text},
        ),
      ]).sent.single.why,
      'While connected it can receive your location and text',
    );
  });

  test('a run whose result was rejected still ran, and says so', () {
    // The dispatcher's widened-mode case: a real cloud result rejected by
    // policy. It ran in the cloud (data left); its result was not used.
    final r = PrivacyReceipt.fromLegs([
      leg(
        Provenance.sdkCloud,
        feature: 'label_check',
        kinds: _photo,
        mode: HybridMode.onlyOnDevice,
        error: HybridErrorCode.failed,
      ),
      leg(Provenance.sdkOnDevice, error: HybridErrorCode.failed),
      leg(Provenance.simulated, error: HybridErrorCode.failed),
    ]);
    expect(r.cloudRuns, 1);
    expect(r.onDeviceRuns, 1);
    expect(r.practiceRuns, 1);
    expect(r.runs, 3);
    expect(r.notUsed, 3);
    expect(r.unfinished, 0);
    expect(r.photoRequestsSent, 1);
    expect(r.sent.single.count, 1);
    expect(
      r.sent.single.why,
      'Ran on Gemini in the cloud · asked for this device only · '
      'result not used',
    );
    expect(r.practiceOnly, isFalse);
  });

  test('a photo the bridge rejected before sending is not a possible send', () {
    for (final code in [
      HybridErrorCode.unsupportedInput,
      HybridErrorCode.unsupportedMode,
    ]) {
      final rejected = leg(
        Provenance.unknown,
        feature: 'label_check',
        kinds: _photo,
        transferPermitted: true,
        error: code,
      );
      expect(rejectedBeforeSend(rejected), isTrue);
      final r = PrivacyReceipt.fromLegs([
        rejected,
        // The adapter then sent it once.
        leg(Provenance.cloudAdapter, feature: 'label_check', kinds: _photo),
      ]);
      expect(r.photoRequestsSent, 1);
      expect(r.photoRequestsMaybeSent, 0);
      expect(r.maybeSent, isEmpty);
      expect(r.unfinished, 1);
    }
    // A network failure after it was allowed to leave stays uncertain.
    final network = leg(
      Provenance.unknown,
      kinds: _photo,
      transferPermitted: true,
      error: HybridErrorCode.network,
    );
    expect(rejectedBeforeSend(network), isFalse);
    expect(PrivacyReceipt.fromLegs([network]).photoRequestsMaybeSent, 1);
  });

  test('photo numbers count requests, whatever their attachments', () {
    // Legs carry data kinds, not attachment counts: one request with two
    // photos is one request that sent photos, and the label says requests.
    final r = PrivacyReceipt.fromLegs([
      leg(Provenance.cloudAdapter, feature: 'pantry_scan', kinds: _photo),
    ]);
    expect(r.photoRequestsSent, 1);
    expect(r.summary, endsWith('recorded requests that sent photos: 1.'));
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
