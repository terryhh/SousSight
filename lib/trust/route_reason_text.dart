// Cook-facing wording for routing decisions (DESIGN.md §5, card SS-070).
// One short, honest sentence per RouteReason. Never claim more than the
// ledger knows: "stayed here" only where nothing was sent.

import '../ai/hybrid/hybrid_types.dart';

const Map<RouteReason, String> routeReasonText = {
  RouteReason.onDevice: 'Ran on this device — nothing left it.',
  RouteReason.localOnlySetting:
      "You asked to keep this on your device, and it can't run here right now.",
  RouteReason.cloudNotApproved: 'Cloud help is off in this build.',
  RouteReason.audioNeedsCloud:
      'Voice clips need the cloud; your photo stayed here.',
  RouteReason.imageNeedsCloud:
      "This device's model can't read photos, so the photo needs the cloud.",
  RouteReason.tooLargeForDevice:
      'This was too big for the on-device model, so it needed the cloud.',
  RouteReason.languageNotSupported: "The on-device model doesn't speak this language yet, so it needed the cloud.",
  RouteReason.modelNotReady: "The on-device model isn't set up yet. You can set it up from On-device AI.",
  RouteReason.modelDownloading:
      'The on-device model is still downloading. Try again when it finishes.',
  RouteReason.noLocalModel: "This device doesn't have an on-device model.",
  RouteReason.offline: "You're offline, and this needs the cloud. It will work when you reconnect.",
  RouteReason.consentDeclined: 'You said no, so nothing was sent.',
  RouteReason.cancelled: 'Stopped. Nothing more will be sent for this.',
  RouteReason.cloudRetryAfterCheck: "The on-device answer didn't pass our checks, so we asked the cloud once.",
};

/// The sentence for [reason]. Every enum value has one; a test enforces it.
String routeReasonSentence(RouteReason reason) =>
    routeReasonText[reason] ?? 'SousSight chose where this ran.';
