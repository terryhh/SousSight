// The cook-facing safety gate (SS-106).
//
// Vision and the models can never establish doneness, internal temperature,
// freshness, allergen status or dietary suitability (AGENTS.md). Phrase
// lists always miss the next phrasing, so this gate is deliberately
// conservative: model-written text that so much as *mentions* that
// vocabulary, in English or Spanish, is not shown. The caller shows the
// recipe's own step and cue with a thermometer / label note instead.
// Over-blocking a harmless sentence is acceptable; missing a claim is not.
//
// Visual-only coaching stays allowed: golden, bubbling, crisp edges, glossy,
// dorado, burbujas, brillante.
//
// Checked surfaces (see the PR for the list of paths it does not cover):
// Coach Lite answers and timer labels, the Coach Lite read-aloud, Live /
// GenUI panels (show_cooking_ui), Live timer labels, readiness observations,
// ask_cook questions, watch goals, dinner-ready drafts, and recipe
// translations (source lines and translated lines).
//
// App-authored text (the fallback notes, recipe text shown as written)
// never passes through this gate.

/// Shown in place of a rejected answer, panel or observation.
const cookSafetyFallbackNote =
    'Neither the camera nor the coach can confirm doneness, internal '
    'temperature, freshness or allergens. Check with a food thermometer, '
    'the package label and trusted guidance.';

RegExp _words(List<String> words) => RegExp(
  '(?<![\\p{L}\\p{N}])(?:${words.join('|')})(?![\\p{L}\\p{N}])',
  caseSensitive: false,
  unicode: true,
);

/// English doneness, temperature, freshness, safety and allergen-status
/// vocabulary.
final _english = _words([
  r'done(?:ness)?',
  r'(?:un|under|over)?cooked',
  r'cook(?:ed|s)?\s+through',
  r'ready',
  r'(?:un)?safe(?:ly|ty)?',
  r'fresh(?:ness)?',
  r'stale',
  r'spoil(?:ed|t|s|age)?',
  r'rotten',
  r'go(?:ne)?\s+(?:bad|off)',
  r'expir(?:ed|es|y|ation)',
  r'mou?ld(?:y)?',
  r'temp(?:erature)?s?',
  r'degrees?',
  r'juices',
  r'pink(?:ish|ness)?',
  r'raw',
  r'(?:in)?edible',
  r'allerg(?:en|ens|y|ies|ic)',
  r'contains?',
  r'gluten',
  r'c(?:o)?eliacs?',
  r'[\p{L}]+[- ]free',
  r'free\s+(?:of|from)',
  r'bacteri(?:a|al)',
  r'salmonella',
  r'listeria',
  r'e\.?\s?coli',
  r'poison(?:ing|ous)?',
  r'internal',
  r'leftovers?',
  r'reheat(?:ed|ing)?',
  r'risk(?:y|s)?',
  r'hypoallergenic',
  r'(?:can|may)\s+(?:now\s+)?(?:eat|serve)',
  // Absence of an allergen: "no peanuts in this dish", "without nuts".
  r'(?:no|without|zero|not\s+any)\s+(?:\w+\s+)?(?:peanuts?|nuts?|'
      r'tree\s+nuts?|gluten|dairy|milk|eggs?|wheat|soy|sesame|shellfish|'
      r'fish|mustard|allergens?|lactose)',
]);

/// Spanish doneness, temperature, freshness, safety and allergen-status
/// vocabulary.
final _spanish = _words([
  r'list[oa]s?',
  r'cocid[oa]s?',
  r'(?:bien\s+)?cocinad[oa]s?',
  r'crud[oa]s?',
  r'hech[oa]s?',
  r'(?:in)?segur[oa]s?',
  r'seguridad',
  r'fresc[oa]s?',
  r'frescura',
  r'podrid[oa]s?',
  r'echad[oa]s?\s+a\s+perder',
  r'caducad[oa]s?',
  r'vencid[oa]s?',
  r'moho',
  r'temperaturas?',
  r'grados?',
  r'jugos',
  r'rosad[oa]s?',
  r'(?:in)?comestibles?',
  r'al[ée]rgen[oa]s?',
  r'alergias?',
  r'al[ée]rgic[oa]s?',
  r'contienen?',
  r'gluten',
  r'cel[íi]ac[oa]s?',
  // Absence of an allergen, synonyms included: "sin cacahuates",
  // "no lleva maní".
  r'(?:sin|no|ning[úu]n|ninguna|cero)\s+(?:\w+\s+)?(?:tacc|gluten|'
      r'l[áa]cteos|leche|huevos?|man[íi]|manises|cacahuates?|cacahuetes?|'
      r'nueces|frutos\s+secos|trigo|soya|soja|mariscos|pescado|'
      r'ajonjol[íi]|s[ée]samo|mostaza|al[ée]rgenos?|lactosa|az[úu]car)',
  r'libres?\s+de',
  r'apt[oa]s?',
  r'bacterias?',
  r'salmonela',
  r'intoxicaci[óo]n',
  r'inocu[oa]s?',
  r'peligros[oa]s?',
  r'peligro',
  r'interna',
  r'sobras',
  r'recalent\w*',
  r'riesgos?',
  r'mal\s+estado',
  r'hipoal[ée]rg[ée]nic[oa]s?',
  r'(?:puedes|puede|pueden|se\s+puede)\s+(?:ya\s+)?(?:comer|servir|consumir)\w*',
]);

/// Symbols that only appear with temperatures, and a number written as a
/// temperature without one ("165F", "74 C", "74 grados").
final _symbols = RegExp('[°º℉℃]');
final _bareTemperature = RegExp(
  r'\d+(?:[.,]\d+)?\s*(?:[FC]|grados|degrees)(?![\p{L}])',
  caseSensitive: false,
  unicode: true,
);

/// True when [text] touches doneness, temperature, freshness, safety or
/// allergen status in English or Spanish. Deliberately broad: it decides
/// that model text is not shown, never that something is safe.
bool touchesFoodSafety(String text) =>
    _symbols.hasMatch(text) ||
    _bareTemperature.hasMatch(text) ||
    _english.hasMatch(text) ||
    _spanish.hasMatch(text);

/// The cook-facing strings in a model JSON payload: every string value
/// except structural keys (ids, component names, children, actions).
Iterable<String> cookFacingStrings(Object? json) sync* {
  const structural = {'id', 'component', 'children', 'action', 'stepId'};
  if (json is String) {
    yield json;
  } else if (json is List) {
    for (final v in json) {
      yield* cookFacingStrings(v);
    }
  } else if (json is Map) {
    for (final e in json.entries) {
      if (structural.contains(e.key)) continue;
      yield* cookFacingStrings(e.value);
    }
  }
}

/// True when any cook-facing string in [json] touches food safety. Strings
/// in [reviewed] (the recipe's own reviewed text, quoted verbatim) are not
/// model claims and pass.
bool payloadTouchesFoodSafety(
  Object? json, {
  Set<String> reviewed = const {},
}) =>
    cookFacingStrings(json)
        .any((s) => !reviewed.contains(s.trim()) && touchesFoodSafety(s));

/// Thrown when model-written text touches food safety. The caller shows
/// app-authored text instead.
class UnsafeClaimException extends FormatException {
  const UnsafeClaimException()
    : super(
        'It mentioned doneness, temperature, freshness, safety or allergen '
        'status. Never certify these; describe only what is visible and tell '
        'the cook what to check with a thermometer or the package label.',
      );
}
