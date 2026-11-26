// Checks a translated line before the cook sees it (SS-106).
//
// A translated line is shown only when:
// - every number, temperature, time and quantity in the English source line
//   appears unchanged in it, in the same order (so each stays with its own
//   instruction), with the same sign and the same kind of unit, and written
//   numbers ("two") keep their value;
// - every allergen ingredient the source line mentions (by name or a known
//   alias, e.g. "mayo") keeps its English name visible, in parentheses;
// - it passes the shared safety gate (lib/safety/cook_safety.dart) on its own
//   terms, whatever the source line says;
// - and it adds no link or markup.
// Anything else keeps the original English line.

import '../safety/cook_safety.dart';
import 'cook_language.dart';

/// One number in a line and the unit that follows it, if any.
///
/// [number] is the exact text, with its sign (`-18`; a Unicode minus reads
/// as `-`): `1/2`, `½`, `1.5` and `1,5` are all different. A written number
/// ("two", "dos") is stored as its digits. [unit] is canonical (`minute`,
/// `temp_f`, `percent`, ...), so "10 minutes" and "10 minutos" agree while
/// "10 horas" does not.
class Quantity {
  const Quantity(this.number, this.unit);
  final String number;
  final String? unit;

  String get key => '$number|${unit ?? ''}';

  @override
  bool operator ==(Object other) => other is Quantity && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => unit == null ? number : '$number $unit';
}

/// English number words. "one"/"a" are left out: they double as articles,
/// and a dropped or added "one" cannot be told from grammar.
const englishNumberWords = <String, int>{
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'dozen': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'ninety': 90,
  'hundred': 100,
};

/// A unary sign: a minus (ASCII or Unicode) not preceded by a digit or
/// letter, so "3-4" is a range and "-18" is negative.
final _number = RegExp(
  r'(?<![\p{L}\p{N}.,/])(?:(?<![\p{N}]\s?)([-−‒–]))?'
  r'(\d+(?:[.,]\d+)*(?:/\d+)?|[.,]\d+)|'
  r'([¼½¾⅓⅔⅛⅜⅝⅞])|'
  r'(?<![\p{L}])([\p{L}]+)(?![\p{L}])',
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

/// Every number in [text], in order, with its canonical unit, read with
/// [units] (canonical unit → words) and [numberWords].
List<Quantity> extractQuantities(
  String text, {
  Map<String, List<String>> units = englishUnitWords,
  Map<String, int> numberWords = englishNumberWords,
}) {
  final lookup = <String, String>{
    for (final e in units.entries)
      for (final w in e.value) w.toLowerCase(): e.key,
  };
  final words = {
    for (final e in numberWords.entries) e.key.toLowerCase(): e.value,
  };
  final found = <Quantity>[];
  for (final m in _number.allMatches(text)) {
    final String number;
    if (m[2] case final digits?) {
      // A sign only when it is unary: at the start or after a space or
      // opening bracket, never right after a digit (a range).
      final sign = m[1] != null && _unary(text, m.start) ? '-' : '';
      number = '$sign$digits';
    } else if (m[3] case final fraction?) {
      number = fraction;
    } else {
      final value = words[m[4]!.toLowerCase()];
      if (value == null) continue;
      number = '$value';
    }
    found.add(Quantity(number, _unitAfter(text, m.end, lookup)));
  }
  return found;
}

bool _unary(String text, int signAt) {
  if (signAt == 0) return true;
  final before = text.substring(0, signAt).trimRight();
  if (before.isEmpty) return true;
  final last = before[before.length - 1];
  return !RegExp(r'[\p{N}]', unicode: true).hasMatch(last);
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

/// Number words a translation into [language] may use: its own, or the
/// English ones for a language without any. Never both: English words are
/// ordinary words elsewhere (Spanish "ten" means "have").
Map<String, int> numberWordsFor(CookLanguage language) =>
    language.numberWords.isEmpty ? englishNumberWords : language.numberWords;

final _warning = RegExp(
  r"(?<![\p{L}])(?:warning|caution|careful|never|do\s+not|don['\u2019]t|"
  r'avoid|labels?)(?![\p{L}])',
  caseSensitive: false,
  unicode: true,
);

const _criticalUnits = {'minute', 'hour', 'second', 'temp', 'temp_f', 'temp_c'};

/// True when [source] must stay in the reviewed English and never be sent
/// for translation: it touches food safety, allergen status or temperature
/// (the shared gate's vocabulary), carries a warning or label instruction,
/// or ties more than one time or temperature to its actions, where a
/// translation could reassign them.
bool needsReviewedEnglish(String source) {
  if (touchesFoodSafety(source) || _warning.hasMatch(source)) return true;
  final critical = extractQuantities(source)
      .where((q) => _criticalUnits.contains(q.unit));
  return critical.length > 1;
}

/// Why a translated line cannot be shown, or null when it can.
enum LineRejection {
  /// The source carries a safety, allergen, temperature or timing warning:
  /// it is kept in the reviewed English and was never sent.
  reviewedEnglish,

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
  LineRejection.reviewedEnglish =>
    'Safety, allergen, temperature or timing details stay in the '
        'reviewed English.',
  LineRejection.empty => 'The translation was empty.',
  LineRejection.tooLong ||
  LineRejection.markup => "The translation didn't match the original.",
  LineRejection.numbersChanged =>
    'A number, time or temperature did not match the original.',
  LineRejection.allergenNameMissing =>
    'An allergen name did not keep its English name.',
  LineRejection.certifies =>
    'The translation made a safety claim, so the original is shown.',
  LineRejection.noTranslation => 'No translation came back for this line.',
};

final _markup = RegExp(r'<[a-z/!]|https?:|www\.|```', caseSensitive: false);

/// One allergen ingredient as the guard sees it: its English names.
class AllergenIngredient {
  const AllergenIngredient(this.aliases);

  /// The first is the ingredient's own short name.
  final List<String> aliases;
  String get name => aliases.first;
}

/// Known short names cooks and recipes use (lowercase key name → aliases).
const allergenAliases = <String, List<String>>{
  'mayonnaise': ['mayo'],
  'dijon mustard': ['mustard', 'dijon'],
  'flour tortillas': ['tortillas', 'tortilla'],
};

/// English food words Spanish writes the same way, reviewed: a translation
/// that keeps one of these as a word already shows the English name.
const sharedIngredientWords = {'tortilla', 'tortillas'};

/// [name]'s English aliases: the name, the alternatives in an "A or B" name,
/// the singular or plural, and [allergenAliases].
AllergenIngredient allergenIngredient(String name) {
  final key = name.trim();
  final out = <String>[key];
  void add(String a) {
    final t = a.trim();
    if (t.isNotEmpty && !out.any((o) => o.toLowerCase() == t.toLowerCase())) {
      out.add(t);
    }
  }

  for (final part in key.split(RegExp(r'\s+or\s+', caseSensitive: false))) {
    add(part);
  }
  for (final a in [...out]) {
    if (a.toLowerCase().endsWith('s')) add(a.substring(0, a.length - 1));
  }
  for (final a in allergenAliases[key.toLowerCase()] ?? const <String>[]) {
    add(a);
  }
  return AllergenIngredient(out);
}

/// Checks [translated] against [source]. [allergens] are the recipe's
/// allergen ingredients; for each one the source mentions, the translation
/// must keep one of its English names visible (in parentheses, or as the
/// same word when the languages share it, like "tortilla").
LineRejection? checkTranslatedLine({
  required String source,
  required String translated,
  required CookLanguage language,
  List<AllergenIngredient> allergens = const [],
}) {
  final text = translated.trim();
  if (text.isEmpty) return LineRejection.empty;
  if (text.length > source.length * 3 + 60) return LineRejection.tooLong;
  if (_markup.hasMatch(text) && !_markup.hasMatch(source)) {
    return LineRejection.markup;
  }
  final want = extractQuantities(source);
  final got = extractQuantities(
    text,
    units: unitWordsFor(language),
    numberWords: numberWordsFor(language),
  );
  if (want.length != got.length) return LineRejection.numbersChanged;
  for (var i = 0; i < want.length; i++) {
    if (want[i] != got[i]) return LineRejection.numbersChanged;
  }
  for (final ingredient in allergensIn(source, allergens)) {
    if (!keepsEnglishName(text, ingredient)) {
      return LineRejection.allergenNameMissing;
    }
  }
  // The translation is judged on its own: a disclaimer in the source never
  // exempts a claim in the translation.
  if (touchesFoodSafety(text)) return LineRejection.certifies;
  return null;
}

/// True when [text] would certify doneness, temperature, freshness or
/// allergen safety. [language] is accepted for call sites that have one;
/// the shared gate covers every supported language.
bool certifiesIn(String text, CookLanguage language) => touchesFoodSafety(text);

bool _mentions(String text, String word) => RegExp(
  '(?<![\\p{L}])${RegExp.escape(word.trim())}(?![\\p{L}])',
  caseSensitive: false,
  unicode: true,
).hasMatch(text);

/// The [allergens] that [source] mentions by any alias, as whole words.
List<AllergenIngredient> allergensIn(
  String source,
  List<AllergenIngredient> allergens,
) => [
  for (final a in allergens)
    if (a.aliases.any((alias) => _mentions(source, alias))) a,
];

/// Back-compatible form: the plain [names] that [source] mentions.
List<String> allergenNamesIn(String source, List<String> names) => [
  for (final name in names)
    if (name.trim().isNotEmpty && _mentions(source, name)) name.trim(),
];

/// True when [text] has [name] (any case) inside a pair of parentheses.
bool hasEnglishInParentheses(String text, String name) => RegExp(
  '\\([^()]*(?<![\\p{L}])${RegExp.escape(name)}(?![\\p{L}])[^()]*\\)',
  caseSensitive: false,
  unicode: true,
).hasMatch(text);

/// True when one of [ingredient]'s English names stays visible in [text]:
/// in parentheses right after a word (the translated name it explains), or
/// as a reviewed shared word ("tortilla"). A bare English word elsewhere
/// does not count: "mayo" is a month in Spanish.
bool keepsEnglishName(String text, AllergenIngredient ingredient) =>
    ingredient.aliases.any(
      (a) =>
          _parenthesizedAfterWord(text, a) ||
          (sharedIngredientWords.contains(a.toLowerCase()) &&
              _mentions(text, a)),
    );

bool _parenthesizedAfterWord(String text, String name) => RegExp(
  '\\p{L}\\s*\\(\\s*${RegExp.escape(name)}\\s*\\)',
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
