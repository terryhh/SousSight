// The languages a cook can choose for recipe content and AI answers (SS-106).
//
// Adding a language is one entry in [cookLanguages]. Without
// [CookLanguage.unitWords] its translations must keep every unit word exactly
// as the English source wrote it, and without [CookLanguage.numberWords] a
// written number ("two") must stay a digit or an English word, so a new entry
// starts strict. Its safety-claim patterns belong in the shared gate,
// lib/safety/cook_safety.dart, before the language is offered to cooks.
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
    this.numberWords = const {},
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

  /// Written numbers in this language, by value ("dos" → 2). Articles that
  /// double as "one" are left out.
  final Map<String, num> numberWords;

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
  numberWords: {
    'dos': 2,
    'tres': 3,
    'cuatro': 4,
    'cinco': 5,
    'seis': 6,
    'siete': 7,
    'ocho': 8,
    'nueve': 9,
    'diez': 10,
    'once': 11,
    'doce': 12,
    'docena': 12,
    'trece': 13,
    'catorce': 14,
    'quince': 15,
    'dieciséis': 16,
    'diecisiete': 17,
    'dieciocho': 18,
    'diecinueve': 19,
    'veinte': 20,
    'treinta': 30,
    'cuarenta': 40,
    'cincuenta': 50,
    'sesenta': 60,
    'setenta': 70,
    'ochenta': 80,
    'media': 0.5,
    'medio': 0.5,
    'mitad': 0.5,
    'noventa': 90,
    'cien': 100,
  },
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
