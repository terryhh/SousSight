// The languages a cook can choose for recipe content and AI answers (SS-106).
//
// Adding a language is one entry in [cookLanguages]. Without a
// [CookLanguage.unitWords] entry its translations must keep every unit word
// exactly as the English source wrote it, and without a
// [CookLanguage.certificationPattern] it relies on the English checks only,
// so a new entry starts strict and can be relaxed with care.
//
// The shell's own strings stay English; only recipe content and AI answers
// use the chosen language.

/// One language a cook can cook in.
class CookLanguage {
  const CookLanguage({
    required this.code,
    required this.nativeName,
    required this.modelName,
    this.unitWords = const {},
    this.certificationPattern,
  });

  /// BCP 47 primary tag, e.g. `es`. Also what the dispatcher's language
  /// check reads.
  final String code;

  /// The name the cook sees, in that language (e.g. "Español").
  final String nativeName;

  /// How prompts name the language to the model.
  final String modelName;

  /// Unit words in this language, by canonical unit (see [englishUnitWords]).
  /// A translation may use these or the English source's own unit word.
  final Map<String, List<String>> unitWords;

  /// Phrases in this language that would certify doneness, temperature or
  /// safety. Model text that matches is never shown.
  final String? certificationPattern;

  /// The recipe's own language: nothing to translate.
  bool get isSource => code == sourceLanguage.code;

  @override
  bool operator ==(Object other) => other is CookLanguage && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'CookLanguage($code)';
}

/// Recipes are written in English.
const sourceLanguage = CookLanguage(
  code: 'en',
  nativeName: 'English',
  modelName: 'English',
);

const spanish = CookLanguage(
  code: 'es',
  nativeName: 'Español',
  modelName: 'Spanish (plain, everyday words a home cook uses)',
  unitWords: {
    'minute': ['min', 'minuto', 'minutos'],
    'hour': ['h', 'hora', 'horas'],
    'second': ['s', 'seg', 'segundo', 'segundos'],
    'cup': ['taza', 'tazas'],
    'tbsp': ['cda', 'cdas', 'cucharada', 'cucharadas'],
    'tsp': ['cdta', 'cdtas', 'cdita', 'cditas', 'cucharadita', 'cucharaditas'],
    'oz': ['onza', 'onzas'],
    'lb': ['libra', 'libras'],
    'g': ['gr', 'gramo', 'gramos'],
    'kg': ['kilo', 'kilos', 'kilogramo', 'kilogramos'],
    'ml': ['mililitro', 'mililitros'],
    'l': ['litro', 'litros'],
    'inch': ['pulgada', 'pulgadas'],
    'cm': ['centímetro', 'centímetros'],
    'mm': ['milímetro', 'milímetros'],
    'quart': ['cuarto', 'cuartos'],
    'pint': ['pinta', 'pintas'],
    'gallon': ['galón', 'galones'],
  },
  // Statements, not conditions: Spanish puts conditions in the subjunctive
  // ("hasta que esté cocido"), so the indicative "está cocido" is a claim.
  certificationPattern:
      r'\bsegur[oa]s?\s+(para\s+)?(comer|consumir|servir)\b|'
      r'\b(es|está|están|son|estan)\s+'
      r'((ya|totalmente|completamente|bien)\s+)*'
      r'(segur[oa]s?|cocid[oa]s?|hech[oa]s?|list[oa]s?\s+para\s+(comer|servir))\b|'
      r'\b(libres?|sin)\s+de\s+'
      r'(alérgenos?|alergenos?|gluten|nueces|maní|mani|cacahuates?|lácteos|lacteos|huevos?)\b|'
      r'\bsin\s+(ningún\s+)?riesgo\b|'
      r'\b(alcanzó|alcanzaron|alcanzado|llegó\s+a)\s+(la\s+|una\s+)?temperatura\s+(segura|interna)\b',
);

/// Every language a cook can choose, in display order. Add one entry here.
const cookLanguages = <CookLanguage>[sourceLanguage, spanish];

/// The registered language for [code] (primary subtag), or null.
CookLanguage? cookLanguageFor(String code) {
  final primary = code.toLowerCase().split(RegExp('[-_]')).first;
  for (final language in cookLanguages) {
    if (language.code == primary) return language;
  }
  return null;
}

/// Canonical units and the English words for them. Single letters that are
/// also ordinary words or ambiguous (t, T, c, s, h, in) are left out, so a
/// line using them is compared by number alone.
const englishUnitWords = <String, List<String>>{
  'minute': ['min', 'mins', 'minute', 'minutes'],
  'hour': ['hr', 'hrs', 'hour', 'hours'],
  'second': ['sec', 'secs', 'second', 'seconds'],
  'cup': ['cup', 'cups'],
  'tbsp': ['tbsp', 'tbs', 'tablespoon', 'tablespoons'],
  'tsp': ['tsp', 'teaspoon', 'teaspoons'],
  'oz': ['oz', 'ounce', 'ounces'],
  'lb': ['lb', 'lbs', 'pound', 'pounds'],
  'g': ['g', 'gram', 'grams'],
  'kg': ['kg', 'kilogram', 'kilograms'],
  'ml': ['ml', 'milliliter', 'milliliters', 'millilitre', 'millilitres'],
  'l': ['l', 'liter', 'liters', 'litre', 'litres'],
  'inch': ['inch', 'inches'],
  'cm': ['cm', 'centimeter', 'centimeters'],
  'mm': ['mm', 'millimeter', 'millimeters'],
  'quart': ['qt', 'quart', 'quarts'],
  'pint': ['pt', 'pint', 'pints'],
  'gallon': ['gal', 'gallon', 'gallons'],
};

/// The instruction added to an AI feature's system prompt so it answers in
/// [language]. Empty for the source language.
String answerLanguageDirective(CookLanguage language) => language.isSource
    ? ''
    : 'Write every cook-facing word of your answer (titles, body text, '
          'labels, questions) in ${language.modelName}. Keep JSON keys, ids, '
          'enum values and numbers exactly as specified. Keep every number, '
          'time and temperature in digits, and when you name an allergen '
          'ingredient, add its English name in parentheses.';

/// [instruction] with the answer-language directive for [language] appended.
/// Use it for the Live coach's system instruction (generated panels).
String withAnswerLanguage(String instruction, CookLanguage language) {
  final directive = answerLanguageDirective(language);
  return directive.isEmpty ? instruction : '$instruction\n\n$directive';
}
