// Cook-facing wording for routing decisions (DESIGN.md §5, card SS-070).
// One short, honest sentence per RouteReason. Never claim more than the
// ledger knows: "stayed here" only where nothing was sent.

import '../ai/hybrid/hybrid_types.dart';

const Map<RouteReason, String> routeReasonText = {
  RouteReason.onDevice: 'Ran on this device — nothing left it.',
  RouteReason.localOnlySetting:
      "You asked to keep this on your device, and it can't run here right now.",
  RouteReason.cloudNotApproved: "Sending online is off in this build.",
  // Reasons only: whether anything was sent is shown from the request's own
  // legs, never claimed here (Codex #221).
  RouteReason.audioNeedsCloud:
      'Voice clips need online processing; your photo stayed here.',
  RouteReason.imageNeedsCloud: "This device can't read photos on its own.",
  RouteReason.tooLargeForDevice:
      'This was too big for this device to handle on its own.',
  RouteReason.languageNotSupported:
      "This device doesn't handle this language on its own yet.",
  RouteReason.modelNotReady:
      "Help on this device isn't set up yet. You can set it up from "
      '"On this device".',
  RouteReason.modelDownloading:
      'Help on this device is still downloading. Try again when it finishes.',
  RouteReason.noLocalModel: "This device can't run this on its own.",
  RouteReason.offline:
      "You're offline, and this has to be sent online. It will work when you "
      'reconnect.',
  RouteReason.consentDeclined: 'You said no, so nothing was sent.',
  RouteReason.cancelled: 'Stopped. Nothing more will be sent for this.',
  RouteReason.cloudRetryAfterCheck:
      "The answer from this device didn't pass our checks, so we asked "
      "Google's AI online once.",
};

/// The sentence for [reason]. Every enum value has one; a test enforces it.
String routeReasonSentence(RouteReason reason) =>
    routeReasonText[reason] ?? 'SousSight chose where this ran.';
