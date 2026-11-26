// Plain-language cloud consent copy (SS-101).
//
// Written for a pantry cook with no tech background: what may be sent, where
// it goes and what SousSight keeps. The claims are deliberately narrow:
// - "May": a yes permits one upload of this exact payload; the request can
//   still finish on the device (preferOnDevice), so the copy never says it
//   was sent.
// - Storage (verified): SousSight writes no photo or voice clip to device
//   storage, Firestore or analytics; the ledger records kinds, never content.
//   That is stated separately from in-memory retention: the screen that took
//   the photo or clip may keep it in memory until the cook leaves it.
// - What Google keeps is governed by Google's terms; nothing is promised on
//   Google's behalf.

import '../ai/hybrid/hybrid_types.dart';
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

/// What goes with the photo, clip or location, or '' when nothing does.
String consentCompanion(ConsentAsk ask) {
  final hasMedia = ask.kinds.any((k) => k != DataKind.text);
  if (!hasMedia || !ask.kinds.contains(DataKind.text)) return '';
  return _textWithMedia[ask.feature] ?? "SousSight's short instructions";
}

/// What the consent dialog shows. Pure, so it is testable without a widget.
({String title, String body, String allow, String decline}) consentCopy(
  ConsentAsk ask,
) {
  final subject = consentSubject(ask);
  final companion = consentCompanion(ask);
  final withText = companion.isEmpty ? '' : ', with $companion,';
  final media =
      ask.kinds.contains(DataKind.image) || ask.kinds.contains(DataKind.audio);
  return (
    title: 'Send $subject to Google if needed?',
    body:
        '${featureLabel(ask.feature)} may need help from Google. '
        "If you say yes and this device can't answer by itself, SousSight "
        "sends $subject$withText to Google's servers to answer. "
        'Your yes covers this one request only. '
        '${media ? "SousSight doesn't save photos or voice clips on this "
                  'device or online. The app may keep them in memory until '
                  'you leave this screen. ' : ''}'
        "Google's own privacy terms cover what Google does with anything it "
        'receives. '
        'If you choose "$kConsentDeclineLabel", nothing from this request is '
        'sent.',
    allow: kConsentAllowLabel,
    decline: kConsentDeclineLabel,
  );
}
