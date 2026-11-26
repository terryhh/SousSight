// Tonight's privacy receipt (SS-105): what tonight's AI did, counted only
// from this session's inference ledger legs.
//
// Every number here comes from `InferenceLeg.provenance`,
// `InferenceLeg.transferPermitted`, `InferenceLeg.kinds` and
// `InferenceLeg.error`. Nothing is read from settings or intent:
// - "on this device" needs `Provenance.sdkOnDevice`. `unknown` never counts
//   as on-device, and `simulated` is always "practice".
// - "sent" needs `sdkCloud` or `cloudAdapter`. An `unknown` leg that was
//   allowed to leave is "may have been sent", never "stayed here".

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show HybridMode;

import '../ai/hybrid/hybrid_types.dart';
import 'trust_labels.dart';

/// The Live coach's ledger feature (`kLiveFeature`). Its legs are sessions,
/// not answers, so they are counted on their own.
const kReceiptLiveFeature = 'live';

/// One group of legs that left (or may have left) the device: same feature,
/// same data kinds, same outcome.
class ReceiptSend {
  const ReceiptSend({
    required this.feature,
    required this.kinds,
    required this.outcome,
    required this.count,
    required this.why,
  });

  final String feature;
  final Set<DataKind> kinds;
  final LegOutcome outcome;
  final int count;

  /// Why it went, as far as the legs themselves say.
  final String why;

  /// "Label check · photo".
  String get what => '${featureLabel(feature)} · ${dataKindsPhrase(kinds)}';
}

/// The receipt's numbers. Pure; built from the legs and nothing else.
class PrivacyReceipt {
  const PrivacyReceipt._({
    required this.legCount,
    required this.onDeviceAnswers,
    required this.cloudAnswers,
    required this.practiceAnswers,
    required this.liveSessions,
    required this.cameraChecksOnDevice,
    required this.practiceCameraChecks,
    required this.photosSent,
    required this.photosMaybeSent,
    required this.unfinished,
    required this.sent,
    required this.maybeSent,
  });

  factory PrivacyReceipt.fromLegs(Iterable<InferenceLeg> legs) {
    var count = 0;
    var onDevice = 0;
    var cloud = 0;
    var practice = 0;
    var live = 0;
    var cameraOnDevice = 0;
    var cameraPractice = 0;
    var photosSent = 0;
    var photosMaybe = 0;
    var unfinished = 0;
    final sent = <String, ReceiptSend>{};
    final maybe = <String, ReceiptSend>{};

    void group(Map<String, ReceiptSend> into, InferenceLeg leg, LegOutcome o) {
      final kinds = orderedDataKinds(leg.kinds).toSet();
      final why = _why(leg, o);
      final key =
          '${leg.feature}|${kinds.map((k) => k.name).join(',')}|${o.name}|$why';
      into[key] = ReceiptSend(
        feature: leg.feature,
        kinds: kinds,
        outcome: o,
        count: (into[key]?.count ?? 0) + 1,
        why: why,
      );
    }

    for (final leg in legs) {
      count++;
      final outcome = legOutcome(leg);
      final isLive = leg.feature == kReceiptLiveFeature;
      final image = leg.kinds.contains(DataKind.image);
      final answered = leg.error == null;
      if (reportedAsSent(outcome)) {
        group(sent, leg, outcome);
        if (isLive) {
          live++;
        } else {
          if (image) photosSent++;
          if (answered) cloud++;
        }
        if (!answered && !isLive) unfinished++;
        continue;
      }
      if (outcome == LegOutcome.maybeSent) {
        group(maybe, leg, outcome);
        if (image && !isLive) photosMaybe++;
        if (!isLive) unfinished++;
        continue;
      }
      if (isLive) continue;
      if (!answered || outcome == LegOutcome.notFinishedLocal) {
        unfinished++;
        continue;
      }
      switch (outcome) {
        case LegOutcome.onDevice:
          onDevice++;
          if (image) cameraOnDevice++;
        case LegOutcome.simulated:
          practice++;
          if (image) cameraPractice++;
        // Every other outcome was handled above.
        case LegOutcome.cloudSdk ||
            LegOutcome.cloudAdapter ||
            LegOutcome.maybeSent ||
            LegOutcome.notFinishedLocal:
          break;
      }
    }

    return PrivacyReceipt._(
      legCount: count,
      onDeviceAnswers: onDevice,
      cloudAnswers: cloud,
      practiceAnswers: practice,
      liveSessions: live,
      cameraChecksOnDevice: cameraOnDevice,
      practiceCameraChecks: cameraPractice,
      photosSent: photosSent,
      photosMaybeSent: photosMaybe,
      unfinished: unfinished,
      sent: sent.values.toList(),
      maybeSent: maybe.values.toList(),
    );
  }

  /// Every leg tonight, of any kind.
  final int legCount;

  /// The SDK reported an on-device run, and it finished.
  final int onDeviceAnswers;

  /// The SDK or SousSight's own client reported a cloud run, and it
  /// finished. Live coach sessions are counted in [liveSessions] instead.
  final int cloudAnswers;

  /// Rehearsal answers: no model ran.
  final int practiceAnswers;

  /// Live coach connects and resumes reported as sent.
  final int liveSessions;

  /// Finished on-device answers that looked at a photo or camera frame.
  final int cameraChecksOnDevice;

  /// Rehearsal camera checks. Never counted as on-device.
  final int practiceCameraChecks;

  /// Non-Live legs with a photo that were reported as sent.
  final int photosSent;

  /// Non-Live legs with a photo that were allowed to leave and then stopped
  /// without saying whether they were sent.
  final int photosMaybeSent;

  /// Non-Live legs that did not produce an answer (stopped, blocked, failed
  /// or still running).
  final int unfinished;

  /// What was reported as sent, grouped.
  final List<ReceiptSend> sent;

  /// What may have been sent, grouped.
  final List<ReceiptSend> maybeSent;

  int get answers => onDeviceAnswers + cloudAnswers + practiceAnswers;

  /// No leg was reported as sent and none may have been.
  bool get nothingLeft => sent.isEmpty && maybeSent.isEmpty;

  /// Every finished answer tonight was a rehearsal one.
  bool get practiceOnly =>
      practiceAnswers > 0 &&
      onDeviceAnswers == 0 &&
      cloudAnswers == 0 &&
      liveSessions == 0 &&
      nothingLeft;

  /// Headline for the receipt, e.g. "7 answers tonight".
  String get headline {
    if (answers == 0) return 'No AI answers tonight';
    final noun = answers == 1 ? 'answer' : 'answers';
    return practiceOnly
        ? '$answers practice $noun tonight'
        : '$answers $noun tonight';
  }

  /// One sentence for screen readers and the shared image's alt text.
  String get summary {
    final parts = <String>[headline];
    if (onDeviceAnswers > 0) parts.add('$onDeviceAnswers on this device');
    if (cloudAnswers > 0) parts.add('$cloudAnswers from the cloud');
    if (practiceAnswers > 0 && !practiceOnly) {
      parts.add('$practiceAnswers practice');
    }
    if (liveSessions > 0) {
      parts.add(
        '$liveSessions Live coach ${liveSessions == 1 ? 'session' : 'sessions'}',
      );
    }
    final photos = photosMaybeSent > 0
        ? 'photos sent: $photosSent, and $photosMaybeSent may have been sent'
        : 'photos sent: $photosSent';
    return '${parts.join(', ')}; $photos.';
  }
}

/// Why a leg went to the cloud, from the leg alone (its feature, mode and
/// outcome). Never claims a reason the leg does not carry.
String _why(InferenceLeg leg, LegOutcome outcome) {
  if (outcome == LegOutcome.maybeSent) {
    return "Allowed to leave, then stopped: we can't tell if it was sent";
  }
  return switch (leg.feature) {
    kReceiptLiveFeature => 'The Live coach hears and sees while it is on',
    'research' => 'Grounded answers search the web',
    'nearby' => 'Finding places near you',
    _ => switch (leg.mode) {
      HybridMode.preferOnDevice =>
        'Tried this device first; Gemini in the cloud answered',
      _ => 'Sent to Gemini in the cloud',
    },
  };
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
