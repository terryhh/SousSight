// Plain-language cloud consent copy (SS-101).
//
// Written for a pantry cook with no tech background: what may be sent, where
// it goes and what SousSight keeps. The claims are deliberately narrow:
// - "May": for a fallback route a yes permits one upload of this exact
//   payload, but the request can still finish on the device
//   (preferOnDevice), so the copy never says it was sent. Only a feature
//   whose effective mode is cloud-primary (the explicit watch cloud check,
//   unless Remote Config moves it on-device) says plainly that a yes sends.
// - Storage (verified): SousSight writes no photo or voice clip to device
//   storage, Firestore or analytics; the ledger records kinds, never content.
//   In-memory retention is stated without a lifetime: previews go through
//   Flutter's shared ImageCache, which can outlive the screen.
// - What Google keeps is governed by Google's terms; nothing is promised on
//   Google's behalf.

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_policy.dart';
import '../trust/trust_labels.dart';

/// The consent dialog's "yes": one send of this exact payload.
const kConsentAllowLabel = 'Send this once';

/// The consent dialog's "no": nothing leaves the device.
const kConsentDeclineLabel = 'Keep it on my phone';

/// What a text-only payload is, in the cook's words.
const Map<String, String> _textSubjects = {
  'pantry_scan': 'the list you typed or said',
  'recipe_draft': 'your pantry list and any note you added',
  'pantry_voice': 'what you said',
  'label_check': 'the label text you typed',
  'coach_lite': 'your question',
};

/// The text that goes with a photo, clip or location, naming everything the
/// cook provided (a pantry scan carries their typed list and the items picked
/// out of their voice note verbatim).
const Map<String, String> _textWithMedia = {
  'pantry_scan':
      "anything you typed, any items picked out from your voice note and "
      "SousSight's recipe list",
  'coach_lite': 'your question and the recipe step you are on',
  'local_watch_cloud_check': 'the recipe step you are on',
};

/// What may leave, in the cook's words: "this photo", "this voice clip",
/// "your location", or, for text alone, "this question" (or the feature's own
/// noun, such as "the list you typed or said").
String consentSubject(ConsentAsk ask) {
  final media = [
    if (ask.kinds.contains(DataKind.image)) 'this photo',
    if (ask.kinds.contains(DataKind.audio)) 'this voice clip',
    if (ask.kinds.contains(DataKind.location)) 'your location',
  ];
  if (media.isEmpty) return _textSubjects[ask.feature] ?? 'this question';
  if (media.length == 1) return media.single;
  return '${media.sublist(0, media.length - 1).join(', ')} and ${media.last}';
}

/// Feature names the cook knows from the screen, where the ledger key differs.
const Map<String, String> _featureNames = {
  'local_watch_cloud_check': 'Watch my food',
};

/// What goes with the photo, clip or location, or '' when nothing does.
String consentCompanion(ConsentAsk ask) {
  final hasMedia = ask.kinds.any((k) => k != DataKind.text);
  if (!hasMedia || !ask.kinds.contains(DataKind.text)) return '';
  return _textWithMedia[ask.feature] ?? "SousSight's short instructions";
}

/// Whether a yes sends the payload straight to the cloud: the feature's
/// effective mode (its default, after a Remote Config override, which can
/// only move it on-device) is cloud-primary, so there is no local attempt.
/// Anything else uses "may … if this device can't answer by itself", which
/// stays true whatever the route decides.
bool consentSendsDirectly(String feature, {RemoteRouting? remote}) {
  final route = featureRouteFor(feature);
  if (!route.cloudOnly) return false;
  final wanted = remote?.modeFor(feature) ?? route.defaultMode;
  return wanted == HybridMode.onlyInCloud || wanted == HybridMode.preferInCloud;
}

/// What the consent dialog shows. Pure, so it is testable without a widget.
/// [remote] is the live Remote Config routing, read when the dialog opens.
({String title, String body, String allow, String decline}) consentCopy(
  ConsentAsk ask, {
  RemoteRouting? remote,
}) {
  final subject = consentSubject(ask);
  final companion = consentCompanion(ask);
  final withText = companion.isEmpty ? '' : ', with $companion,';
  final media =
      ask.kinds.contains(DataKind.image) || ask.kinds.contains(DataKind.audio);
  final direct = consentSendsDirectly(ask.feature, remote: remote);
  final label = _featureNames[ask.feature] ?? featureLabel(ask.feature);
  final check = ask.feature == 'local_watch_cloud_check';
  final request = !direct
      ? '$label may need help from Google. If you say yes and this device '
            "can't answer by itself, SousSight sends $subject$withText to "
            "Google's servers to answer. "
      : check
      ? '$label wants a second look from Google. If you say yes, SousSight '
            "sends $subject$withText to Google's servers to check it. "
      : '$label needs Google for this. If you say yes, SousSight sends '
            "$subject$withText to Google's servers to answer. ";
  final storage = media
      ? "SousSight doesn't save photos or voice clips on this device or "
            'online, though the app may still hold them in memory for a '
            'while. '
      : '';
  return (
    title: direct
        ? 'Send $subject to Google?'
        : 'Send $subject to Google if needed?',
    body:
        '$request'
        'Your yes covers this one request only. '
        '$storage'
        "Google's own privacy terms cover what Google does with anything it "
        'receives. '
        'If you choose "$kConsentDeclineLabel", nothing from this request is '
        'sent.',
    allow: kConsentAllowLabel,
    decline: kConsentDeclineLabel,
  );
}
