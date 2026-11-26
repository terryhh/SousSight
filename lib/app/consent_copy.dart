// Plain-language cloud consent copy (SS-101).
//
// Written for a pantry cook with no tech background: what would be sent, where
// it goes and what SousSight keeps. The claims are deliberately narrow:
// SousSight holds the payload only in memory for this one request (the ledger
// records kinds, never content, and no payload is written to Firestore,
// analytics or device storage). What Google keeps is governed by Google's
// terms, so the copy does not promise anything on Google's behalf.

import '../ai/hybrid/hybrid_types.dart';
import '../trust/trust_labels.dart';

/// The consent dialog's "yes": one send of this exact payload.
const kConsentAllowLabel = 'Send this once';

/// The consent dialog's "no": nothing leaves the device.
const kConsentDeclineLabel = 'Keep it on my phone';

/// Text-only payloads that are not a question, in the cook's words.
const Map<String, String> _textSubjects = {
  'pantry_scan': 'this pantry list',
  'recipe_draft': 'this pantry list',
  'pantry_voice': 'what you said',
};

/// What would leave, in the cook's words: "this photo", "this voice clip",
/// "your location", or, for text alone, "this question" (or the feature's own
/// noun, such as "this pantry list").
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

/// What the consent dialog shows. Pure, so it is testable without a widget.
({String title, String body, String allow, String decline}) consentCopy(
  ConsentAsk ask,
) {
  final subject = consentSubject(ask);
  final hasMedia = ask.kinds.any((k) => k != DataKind.text);
  // With a photo, clip or location, the text part is SousSight's short
  // written request saying what to look for; say so rather than hide it.
  final note = hasMedia && ask.kinds.contains(DataKind.text)
      ? ', with a short written request,'
      : '';
  return (
    title: 'Send $subject to Google?',
    body:
        '${featureLabel(ask.feature)} needs help from Google. '
        "If you say yes, SousSight sends $subject$note to Google's servers "
        'to answer. It goes this one time only. '
        "SousSight doesn't save it. Google's own privacy terms cover what "
        'Google does with it. '
        'If you choose "$kConsentDeclineLabel", nothing is sent.',
    allow: kConsentAllowLabel,
    decline: kConsentDeclineLabel,
  );
}
