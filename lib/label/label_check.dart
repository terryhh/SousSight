// Label check (DESIGN.md §6 SS-069): which allergens a photographed or typed
// label mentions. The model only reports what the label says; it never
// decides that a food is free of an allergen or safe to serve.

import 'dart:convert';
import 'dart:typed_data';

import '../pantry/recipe_draft_client.dart' show kDraftAllergens;

/// Ledger and privacy key. The trust UI's "Label check" switch uses it.
const kLabelCheckFeature = 'label_check';

/// Allergens a label can be reported to mention, in display order.
final List<String> kLabelAllergens = List.unmodifiable(kDraftAllergens);

/// Longest typed label accepted, in characters.
const kMaxTypedLabelLength = 1500;

/// Longest quote shown back to the cook.
const kMaxQuoteLength = 240;

// ---- cook-facing wording ----------------------------------------------------

const kUnreadableWording =
    "I couldn't read an allergen statement. That doesn't mean there are none "
    '— read the label yourself.';
const kMentionsPrefix = 'The label mentions: ';
const kReadItYourselfWording = 'Read the label yourself before serving.';

/// Where the household list lives (SS-099): saved in this app on this device
/// (it may be included in the device's own backups), never sent to a model.
const kHouseholdStaysHereWording =
    'Your household list is saved in this app on this device. It is never '
    'sent to a model. Allergy answers you give the cooking coach are part of '
    'the saved cooking session.';

// ---- the request ------------------------------------------------------------

const kLabelSystemInstruction =
    'You read food packaging. Report only which of the listed allergens the '
    'label text explicitly names, in an ingredients list or a "contains" or '
    '"may contain" statement. Do not guess from the product type. If you '
    'cannot read an allergen or ingredients statement, set readable to false '
    'and allergensMentioned to an empty list. quote is the short label phrase '
    'you read (at most 200 characters), or an empty string.';

/// JSON Schema subset (DESIGN.md §4): lowercase types, enum, required.
final Map<String, Object?> kLabelSchema = Map.unmodifiable({
  'type': 'object',
  'properties': {
    'readable': {'type': 'boolean'},
    'allergensMentioned': {
      'type': 'array',
      'items': {'type': 'string', 'enum': kLabelAllergens},
      'maxItems': kLabelAllergens.length,
    },
    'quote': {'type': 'string'},
  },
  'required': ['readable', 'allergensMentioned', 'quote'],
});

String buildPhotoPrompt() =>
    'Read the allergen statement on this label. Allergens to look for: '
    '${kLabelAllergens.join(', ')}. Answer as JSON.';

String buildTypedPrompt(String labelText) =>
    'The cook typed this label text:\n"""\n$labelText\n"""\n'
    'Which of these allergens does it name: ${kLabelAllergens.join(', ')}? '
    'Answer as JSON.';

// ---- the answer ---------------------------------------------------------------

/// What the model reported, after strict validation.
class LabelReading {
  const LabelReading._({
    required this.readable,
    required this.allergensMentioned,
    required this.quote,
  });

  /// The cautious answer: used for an unreadable label and for any output
  /// that fails validation. Never "no allergens".
  static const unreadable = LabelReading._(
    readable: false,
    allergensMentioned: [],
    quote: '',
  );

  final bool readable;

  /// Members of [kLabelAllergens], deduplicated, in display order.
  final List<String> allergensMentioned;
  final String quote;

  /// True when the cook gets the "couldn't read" wording: unreadable, or
  /// readable with nothing found. An empty list is never "allergen-free".
  bool get saysNothingFound => !readable || allergensMentioned.isEmpty;

  /// Household allergens this label mentions, in display order.
  List<String> matches(Set<String> household) => [
    for (final a in allergensMentioned)
      if (household.contains(a)) a,
  ];
}

/// Parses model output. Anything other than exactly
/// `{readable: bool, allergensMentioned: [known allergen...], quote: string}`
/// becomes [LabelReading.unreadable].
LabelReading parseLabelReading(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(_stripFence(text));
  } on FormatException {
    return LabelReading.unreadable;
  }
  if (decoded is! Map) return LabelReading.unreadable;
  final readable = decoded['readable'];
  final mentioned = decoded['allergensMentioned'];
  final quote = decoded['quote'];
  if (readable is! bool || mentioned is! List || quote is! String) {
    return LabelReading.unreadable;
  }
  final found = <String>{};
  for (final value in mentioned) {
    if (value is! String) return LabelReading.unreadable;
    final normalized = value.trim().toLowerCase();
    // An allergen outside the list means the model ignored the schema; its
    // other claims are not trusted either.
    if (!kDraftAllergens.contains(normalized)) return LabelReading.unreadable;
    found.add(normalized);
  }
  // "Unreadable" with allergens is self-contradictory: abstain.
  if (!readable) return LabelReading.unreadable;
  final trimmed = quote.trim();
  return LabelReading._(
    readable: true,
    allergensMentioned: [
      for (final a in kLabelAllergens)
        if (found.contains(a)) a,
    ],
    quote: trimmed.length > kMaxQuoteLength
        ? '${trimmed.substring(0, kMaxQuoteLength)}…'
        : trimmed,
  );
}

/// iOS local prompting appends the schema to the prompt and some models wrap
/// JSON in a Markdown fence. Only a whole-answer fence is removed.
String _stripFence(String text) {
  final t = text.trim();
  final match = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(t);
  return match == null ? t : match.group(1)!;
}

// ---- the photo ----------------------------------------------------------------

/// Attachment limits for every route (DESIGN.md §4).
const kMaxLabelPhotoBytes = 1024 * 1024;
const kMaxLabelPhotoDimension = 768;

/// Why a photo cannot be sent, or null when it fits: a JPEG of at most
/// [kMaxLabelPhotoBytes] whose longer side is at most
/// [kMaxLabelPhotoDimension] px. The app's camera frames already meet this
/// (`web/soussight_live.js` scales to 768 px); this rejects anything else
/// rather than resizing it.
String? labelPhotoProblem(Uint8List bytes) {
  if (bytes.length > kMaxLabelPhotoBytes) {
    return 'That photo is too large. Try again with the camera here.';
  }
  final size = jpegSize(bytes);
  if (size == null) {
    return "That photo couldn't be used. Try again with the camera here.";
  }
  if (size.width > kMaxLabelPhotoDimension ||
      size.height > kMaxLabelPhotoDimension) {
    return 'That photo is too large. Try again with the camera here.';
  }
  return null;
}

/// Width and height from a JPEG's start-of-frame marker, or null when the
/// bytes are not a JPEG this can read.
({int width, int height})? jpegSize(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 3 < b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2; // markers without a length
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null; // no frame header first
    final length = (b[i + 2] << 8) | b[i + 3];
    if (length < 2) return null;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (i + 8 >= b.length) return null;
      final height = (b[i + 5] << 8) | b[i + 6];
      final width = (b[i + 7] << 8) | b[i + 8];
      if (width == 0 || height == 0) return null;
      return (width: width, height: height);
    }
    i += 2 + length;
  }
  return null;
}
