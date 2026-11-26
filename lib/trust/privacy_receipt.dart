// Tonight's privacy receipt (SS-105): what tonight's AI did, counted only
// from this session's inference ledger legs.
//
// Every number here comes from `InferenceLeg.provenance`,
// `InferenceLeg.transferPermitted`, `InferenceLeg.kinds`, `InferenceLeg.mode`
// and `InferenceLeg.error`. Nothing is read from settings or intent, and every
// claim is about the requests the ledger recorded, nothing wider:
// - "on this device" needs `Provenance.sdkOnDevice`. `unknown` never counts
//   as on-device, and `simulated` is always "practice".
// - "sent" needs `sdkCloud` or `cloudAdapter`. An `unknown` leg that was
//   allowed to leave is "may have been sent": still running if it has no
//   error yet, unclear if it stopped.
// - A finished leg is a "run", not an "answer": the feature may still have
//   rejected its output.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show HybridMode;

import '../ai/hybrid/hybrid_types.dart';
import 'trust_labels.dart';

/// The Live coach's ledger feature (`kLiveFeature`). Its legs are
/// connections (each connect and each resume), not runs.
const kReceiptLiveFeature = 'live';

/// One group of legs that left (or may have left) the device: same feature,
/// same data kinds, same outcome, same explanation.
class ReceiptSend {
  const ReceiptSend({
    required this.feature,
    required this.kinds,
    required this.outcome,
    required this.count,
    required this.why,
    this.pending = false,
  });

  final String feature;
  final Set<DataKind> kinds;
  final LegOutcome outcome;
  final int count;

  /// What the legs themselves say about where it went and why.
  final String why;

  /// Allowed to leave and not finished yet.
  final bool pending;

  /// "Label check · photo", or "Live coach · connection".
  String get what => feature == kReceiptLiveFeature
      ? '${featureLabel(feature)} · connection'
      : '${featureLabel(feature)} · ${dataKindsPhrase(kinds)}';
}

/// The receipt's numbers. Pure; built from the legs and nothing else.
class PrivacyReceipt {
  const PrivacyReceipt._({
    required this.legCount,
    required this.allSimulated,
    required this.onDeviceRuns,
    required this.cloudRuns,
    required this.practiceRuns,
    required this.liveConnections,
    required this.cameraChecksOnDevice,
    required this.practiceCameraChecks,
    required this.photosSent,
    required this.photosMaybeSent,
    required this.unfinished,
    required this.inProgress,
    required this.sent,
    required this.maybeSent,
  });

  factory PrivacyReceipt.fromLegs(Iterable<InferenceLeg> legs) {
    var count = 0;
    var simulated = 0;
    var onDevice = 0;
    var cloud = 0;
    var practice = 0;
    var live = 0;
    var cameraOnDevice = 0;
    var cameraPractice = 0;
    var photosSent = 0;
    var photosMaybe = 0;
    var unfinished = 0;
    var inProgress = 0;
    final sent = <String, ReceiptSend>{};
    final maybe = <String, ReceiptSend>{};

    void group(
      Map<String, ReceiptSend> into,
      InferenceLeg leg,
      LegOutcome outcome, {
      bool pending = false,
    }) {
      final kinds = orderedDataKinds(leg.kinds).toSet();
      final why = _why(leg, outcome, pending: pending);
      final key =
          '${leg.feature}|${kinds.map((k) => k.name).join(',')}|'
          '${outcome.name}|$pending|$why';
      into[key] = ReceiptSend(
        feature: leg.feature,
        kinds: kinds,
        outcome: outcome,
        count: (into[key]?.count ?? 0) + 1,
        why: why,
        pending: pending,
      );
    }

    for (final leg in legs) {
      count++;
      if (leg.provenance == Provenance.simulated) simulated++;
      final outcome = legOutcome(leg);
      final isLive = leg.feature == kReceiptLiveFeature;
      final image = leg.kinds.contains(DataKind.image);
      final finished = leg.error == null;
      if (reportedAsSent(outcome)) {
        group(sent, leg, outcome);
        if (isLive) {
          live++;
        } else {
          if (image) photosSent++;
          if (finished) {
            cloud++;
          } else {
            unfinished++;
          }
        }
        continue;
      }
      if (outcome == LegOutcome.maybeSent) {
        // No error yet means the request has not finished: still running.
        group(maybe, leg, outcome, pending: finished);
        if (!isLive) {
          if (image) photosMaybe++;
          if (finished) {
            inProgress++;
          } else {
            unfinished++;
          }
        }
        continue;
      }
      if (isLive) continue;
      if (outcome == LegOutcome.notFinishedLocal) {
        if (finished) {
          inProgress++;
        } else {
          unfinished++;
        }
        continue;
      }
      if (!finished) {
        unfinished++;
        continue;
      }
      if (outcome == LegOutcome.onDevice) {
        onDevice++;
        if (image) cameraOnDevice++;
      } else {
        // The only outcome left is simulated.
        practice++;
        if (image) cameraPractice++;
      }
    }

    return PrivacyReceipt._(
      legCount: count,
      allSimulated: count > 0 && simulated == count,
      onDeviceRuns: onDevice,
      cloudRuns: cloud,
      practiceRuns: practice,
      liveConnections: live,
      cameraChecksOnDevice: cameraOnDevice,
      practiceCameraChecks: cameraPractice,
      photosSent: photosSent,
      photosMaybeSent: photosMaybe,
      unfinished: unfinished,
      inProgress: inProgress,
      sent: sent.values.toList(),
      maybeSent: maybe.values.toList(),
    );
  }

  /// Every leg tonight, of any kind.
  final int legCount;

  /// There is at least one leg and every leg is `Provenance.simulated`.
  final bool allSimulated;

  /// The SDK reported an on-device run, and it finished without an error.
  /// The feature may still have rejected the output.
  final int onDeviceRuns;

  /// The SDK or SousSight's own client reported a cloud run, and it
  /// finished without an error. Live coach legs are in [liveConnections].
  final int cloudRuns;

  /// Rehearsal runs: no model ran.
  final int practiceRuns;

  /// Live coach connects and resumes reported as sent. A resume is a
  /// connection of its own; the ledger does not say which session it was.
  final int liveConnections;

  /// Finished on-device runs that looked at a photo or camera frame.
  final int cameraChecksOnDevice;

  /// Rehearsal camera checks. Never counted as on-device.
  final int practiceCameraChecks;

  /// Non-Live legs with a photo that were reported as sent.
  final int photosSent;

  /// Non-Live legs with a photo that were allowed to leave and are not
  /// confirmed either way (still running, or stopped without saying).
  final int photosMaybeSent;

  /// Non-Live legs that stopped with an error and were not reported as sent.
  final int unfinished;

  /// Non-Live legs that have not finished yet.
  final int inProgress;

  /// What was reported as sent, grouped.
  final List<ReceiptSend> sent;

  /// What may have been sent, grouped.
  final List<ReceiptSend> maybeSent;

  int get runs => onDeviceRuns + cloudRuns + practiceRuns;

  /// No recorded leg was reported as sent and none may have been. This says
  /// nothing about sends the ledger did not record.
  bool get nothingRecordedLeft => sent.isEmpty && maybeSent.isEmpty;

  /// Every recorded leg was a rehearsal one: no model ran for any of them.
  bool get practiceOnly => allSimulated;

  /// Headline for the receipt, e.g. "7 AI runs tonight".
  String get headline {
    if (runs == 0) return 'No finished AI runs recorded tonight';
    final noun = runs == 1 ? 'run' : 'runs';
    return practiceOnly
        ? '$runs practice $noun tonight'
        : '$runs AI $noun tonight';
  }

  /// One sentence for screen readers and the shared image's alt text.
  String get summary {
    final parts = <String>[headline];
    if (onDeviceRuns > 0) parts.add('$onDeviceRuns on this device');
    if (cloudRuns > 0) parts.add('$cloudRuns in the cloud');
    if (practiceRuns > 0 && !practiceOnly) parts.add('$practiceRuns practice');
    if (liveConnections > 0) {
      parts.add(
        '$liveConnections Live coach '
        '${liveConnections == 1 ? 'connection' : 'connections'}',
      );
    }
    final photos = photosMaybeSent > 0
        ? 'recorded photos sent: $photosSent, and $photosMaybeSent may have '
              'been sent'
        : 'recorded photos sent: $photosSent';
    return '${parts.join(', ')}; $photos.';
  }
}

/// Where a leg went and why, from the leg alone: its observed outcome first,
/// then the routing it asked for. Never claims what the leg does not carry.
String _why(InferenceLeg leg, LegOutcome outcome, {required bool pending}) {
  if (outcome == LegOutcome.maybeSent) {
    return pending
        ? 'Still running: allowed to leave, not finished yet'
        : "Allowed to leave, then stopped: we can't tell if it was sent";
  }
  if (leg.feature == kReceiptLiveFeature) {
    return 'While connected it can receive your ${_liveMedia(leg.kinds)}';
  }
  final observed = switch (outcome) {
    LegOutcome.cloudSdk => 'Ran on Gemini in the cloud',
    _ => "Sent by SousSight's cloud client",
  };
  final purpose = switch (leg.feature) {
    'research' => ' to search the web',
    'nearby' => ' to find places near you',
    _ => '',
  };
  final asked = switch (leg.mode) {
    HybridMode.preferOnDevice => ' · asked to prefer this device',
    HybridMode.onlyOnDevice => ' · asked for this device only',
    HybridMode.preferInCloud => ' · asked to prefer the cloud',
    HybridMode.onlyInCloud => ' · asked for the cloud',
    null => '',
  };
  return '$observed$purpose$asked';
}

String _liveMedia(Set<DataKind> kinds) {
  final words = [
    for (final k in orderedDataKinds(kinds))
      switch (k) {
        DataKind.image => 'camera',
        DataKind.audio => 'voice',
        DataKind.location => 'location',
        DataKind.text => 'text',
      },
  ];
  if (words.isEmpty) return 'nothing';
  if (words.length == 1) return words.single;
  return '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';
}

/// "Thu 26 Nov · 7:42 pm" without a locale dependency.
String receiptDateLine(DateTime at) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final minute = at.minute.toString().padLeft(2, '0');
  final half = at.hour < 12 ? 'am' : 'pm';
  return '${days[at.weekday - 1]} ${at.day} ${months[at.month - 1]} · '
      '$hour:$minute $half';
}
