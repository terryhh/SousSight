// Checks a translated line before the cook sees it (SS-106).
//
// A translated line is shown only when every number, temperature, time and
// quantity in the English source line appears unchanged in it, every allergen
// ingredient the source line names keeps its English name in parentheses,
// and it adds no certification, link or markup. Anything else keeps the
// original English line.

import '../coach_lite/coach_lite.dart' show coachLiteCertifies;
import 'cook_language.dart';

/// One number in a line and the unit that follows it, if any.
///
/// [number] is the exact text: `1/2`, `½`, `1.5` and `1,5` are all
/// different. [unit] is canonical (`minute`, `temp_f`, `percent`, ...), so
/// "10 minutes" and "10 minutos" agree while "10 horas" does not.
class Quantity implements Comparable<Quantity> {
  const Quantity(this.number, this.unit);
  final String number;
  final String? unit;

  String get key => '$number|${unit ?? ''}';

  @override
  bool operator ==(Object other) => other is Quantity && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  int compareTo(Quantity other) => key.compareTo(other.key);

  @override
  String toString() => unit == null ? number : '$number $unit';
}

final _number = RegExp(
  r'(?<![\p{L}\p{N}])\d+(?:[.,]\d+)*(?:/\d+)?|[¼½¾⅓⅔⅛⅜⅝⅞]',
  unicode: true,
);

final _temperature = RegExp(
  r'[\s-]?\s*(?:°|º|degrees?\b|grados?\b)\s*'
  r'(fahrenheit|celsius|centígrados|centigrados|f|c)?(?![\p{L}])',
  caseSensitive: false,
  unicode: true,
);

final _percent = RegExp(r'\s?%');

final _word = RegExp(r'[\s-]?\s*([\p{L}]+)\.?', unicode: true);

/// Every number in [text] with its canonical unit, read with [units]
/// (canonical unit → words).
List<Quantity> extractQuantities(
  String text, {
  Map<String, List<String>> units = englishUnitWords,
}) {
  final lookup = <String, String>{
    for (final e in units.entries)
      for (final w in e.value) w.toLowerCase(): e.key,
  };
  final found = <Quantity>[];
  for (final m in _number.allMatches(text)) {
    found.add(Quantity(m[0]!, _unitAfter(text, m.end, lookup)));
  }
  return found;
}

String? _unitAfter(String text, int at, Map<String, String> lookup) {
  final temp = _temperature.matchAsPrefix(text, at);
  if (temp != null) {
    final scale = temp[1]?.toLowerCase();
    if (scale == null) return 'temp';
    return scale.startsWith('f') ? 'temp_f' : 'temp_c';
  }
  if (_percent.matchAsPrefix(text, at) != null) return 'percent';
  final word = _word.matchAsPrefix(text, at);
  if (word == null) return null;
  final w = word[1]!.toLowerCase();
  // "350F" / "180C" with no degree sign.
  if (w == 'f') return 'temp_f';
  if (w == 'c') return 'temp_c';
  return lookup[w];
}

/// Words [language] may use for units: its own plus the English ones, so a
/// unit kept exactly as the source wrote it always passes.
Map<String, List<String>> unitWordsFor(CookLanguage language) => {
  for (final unit in {...englishUnitWords.keys, ...language.unitWords.keys})
    unit: [...?englishUnitWords[unit], ...?language.unitWords[unit]],
};

/// Why a translated line cannot be shown, or null when it can.
enum LineRejection {
  empty,
  tooLong,
  numbersChanged,
  allergenNameMissing,
  certifies,
  markup,

  /// The model returned nothing usable for this line, or it was not sent.
  noTranslation,
}

/// One cook-facing phrase per [LineRejection], for the "kept in English" note.
String lineRejectionSentence(LineRejection reason) => switch (reason) {
  LineRejection.empty => 'The translation was empty.',
  LineRejection.tooLong ||
  LineRejection.markup => "The translation didn't match the original.",
  LineRejection.numbersChanged =>
    'A number, time or temperature did not match the original.',
  LineRejection.allergenNameMissing =>
    'An allergen name did not keep its English name.',
  LineRejection.certifies =>
    'The translation added a safety claim the recipe does not make.',
  LineRejection.noTranslation => 'No translation came back for this line.',
};

final _markup = RegExp(r'<[a-z/!]|https?:|www\.|```', caseSensitive: false);

/// Checks [translated] against [source]. [allergenNames] are the English
/// names of ingredients that carry an allergen; each one the source names
/// must appear in parentheses in the translation.
LineRejection? checkTranslatedLine({
  required String source,
  required String translated,
  required CookLanguage language,
  List<String> allergenNames = const [],
}) {
  final text = translated.trim();
  if (text.isEmpty) return LineRejection.empty;
  if (text.length > source.length * 3 + 60) return LineRejection.tooLong;
  if (_markup.hasMatch(text) && !_markup.hasMatch(source)) {
    return LineRejection.markup;
  }
  final want = extractQuantities(source)..sort();
  final got = extractQuantities(text, units: unitWordsFor(language))..sort();
  if (want.length != got.length) return LineRejection.numbersChanged;
  for (var i = 0; i < want.length; i++) {
    if (want[i] != got[i]) return LineRejection.numbersChanged;
  }
  for (final name in allergenNamesIn(source, allergenNames)) {
    if (!hasEnglishInParentheses(text, name)) {
      return LineRejection.allergenNameMissing;
    }
  }
  if (!coachLiteCertifies(source) && certifiesIn(text, language)) {
    return LineRejection.certifies;
  }
  return null;
}

/// True when [text] would certify doneness, temperature or safety in English
/// or in [language].
bool certifiesIn(String text, CookLanguage language) {
  if (coachLiteCertifies(text)) return true;
  final pattern = language.certificationPattern;
  return pattern != null &&
      RegExp(pattern, caseSensitive: false, unicode: true).hasMatch(text);
}

/// The [names] that [source] mentions, as whole words, ignoring case.
List<String> allergenNamesIn(String source, List<String> names) => [
  for (final name in names)
    if (name.trim().isNotEmpty &&
        RegExp(
          '(?<![\\p{L}])${RegExp.escape(name.trim())}(?![\\p{L}])',
          caseSensitive: false,
          unicode: true,
        ).hasMatch(source))
      name.trim(),
];

/// True when [text] has [name] (any case) inside a pair of parentheses.
bool hasEnglishInParentheses(String text, String name) => RegExp(
  '\\([^()]*(?<![\\p{L}])${RegExp.escape(name)}(?![\\p{L}])[^()]*\\)',
  caseSensitive: false,
  unicode: true,
).hasMatch(text);

/// An ingredient name with its English name in parentheses, added by the app
/// when the translation does not already carry it.
String withEnglishName(String translated, String english) {
  final t = translated.trim();
  return hasEnglishInParentheses(t, english.trim())
      ? t
      : '$t (${english.trim()})';
}
