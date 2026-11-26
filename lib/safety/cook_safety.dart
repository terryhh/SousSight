// The cook-facing safety gate (SS-106): one check for every model-written
// text the cook sees or hears — Coach Lite answers and timer labels, Live /
// GenUI panels, recipe translations and the read-aloud path. Vision and the
// models can never establish doneness, internal temperature, freshness,
// allergen absence or dietary suitability (AGENTS.md), so any text claiming
// one of these is rejected and the app shows its own wording instead.
//
// English and Spanish. A new cook language adds its patterns here.
//
// Conditions are not claims: "stir until it is done", "hasta que esté
// cocido", "cuando está listo, ...". Three kinds of claim get no such
// exemption, because the condition itself is the problem: a visual cue that
// "proves" doneness ("si se ve blanco por dentro está cocido"), a camera or
// model reading a temperature, and allergen or dietary assurances.
//
// App-authored notices never pass through this check.

/// Shown in place of a rejected answer or panel.
const cookSafetyFallbackNote =
    "Neither the camera nor the coach can confirm doneness, internal "
    'temperature, freshness or allergens. Check with a food thermometer, '
    'the package label and trusted guidance.';

const _flags = (caseSensitive: false, unicode: true);

RegExp _re(String pattern) => RegExp(
  pattern,
  caseSensitive: _flags.caseSensitive,
  unicode: _flags.unicode,
);

/// Ends a word, accented letters included.
const _end = r'(?![\p{L}])';

// ---------------------------------------------------------------- English

const _englishCondition =
    r'(?<!\b(?:when|once|until|till|if|after|before|whether)\b'
    r'[^.,;:!?]{0,40})';

final _englishClaims = _re(
  r"\bsafe to (?:eat|serve|consume)\b|"
  // "is done" / "it's safe", unless it is a condition.
  '$_englishCondition'
  r"\b(?:is|are|['\u2019]s|['\u2019]re)\s+"
  r"(?:now\s+|definitely\s+|fully\s+|already\s+|completely\s+)*"
  r"(?:safe|cooked through|fully cooked|ready to eat|"
  r"done(?!\s+(?:when|once|if|after|before|in)\b))\b|"
  r"\breached\s+(?:a\s+|an\s+|the\s+)?(?:safe|internal)\b|"
  r"\bno risk\b",
);

/// A visual cue presented as proof of doneness or safety.
final _englishVisual = _re(
  r"\b(?:looks?|looking|turns?|turned|appears?|seems?|white|opaque|golden|"
  r"brown(?:ed)?|clear|firm|no\s+(?:longer\s+)?pink)\b[^.;!?]{0,60}"
  r"\b(?:is|are|['\u2019]s|['\u2019]re|will\s+be)\s+"
  r"(?:now\s+|fully\s+|already\s+|completely\s+|definitely\s+)*"
  r"(?:done|cooked(?:\s+through)?|fully\s+cooked|safe|ready\s+to\s+eat)\b"
  r"(?!\s+(?:when|once|if|after|before|in)\b)",
);

/// A camera, photo or model reading a temperature or doneness.
final _englishCamera = _re(
  r"\b(?:the\s+)?(?:camera|picture|photo|image|video|frame)\s+"
  r"(?:clearly\s+)?(?:confirms|shows|reads|measures|detects|indicates|says|"
  r"proves)\b[^.;!?]{0,50}"
  r"(?:\d+\s*(?:°|º|degrees)|internal\s+temp\w*|temperature|"
  r"(?:is|are|['\u2019]s)\s+(?:done|cooked|safe))|"
  r"\bi\s+(?:can\s+)?see\s+(?:that\s+)?[^.;!?]{0,40}"
  r"(?:\d+\s*(?:°|º|degrees)|internal\s+temp\w*)|"
  r"\breached\s+\d+\s*(?:°|º|degrees)",
);

const _allergenWords =
    r'(?:allergen|gluten|nut|peanut|tree[- ]nut|dairy|egg|sesame|soy|wheat|'
    r'shellfish|fish|milk|lactose|mustard)';

/// Allergen absence and dietary suitability.
final _englishAllergen = _re(
  "\\b(?:is|are|['\u2019]s|['\u2019]re|completely|totally|100%)\\s+"
  '(?:completely\\s+|totally\\s+|100%\\s+)?$_allergenWords[- ]free\\b|'
  '\\b(?:contains?|has|have)\\s+no\\s+(?:'
  r'allergens?|gluten|nuts?|peanuts?|tree\s+nuts?|dairy|eggs?|sesame|soy|'
  r'wheat|shellfish|fish|milk|mustard)\b|'
  r'\bfree\s+(?:of|from)\s+(?:allergens?|gluten|nuts?|peanuts?|dairy|eggs?|'
  r'sesame|soy|wheat|shellfish|milk)\b|'
  r'\b(?:safe|suitable|okay|ok|fine)\s+for\s+(?:celiacs?|coeliacs?|'
  r'people\s+with\s+(?:allergies|celiac|coeliac|an?\s+\w+\s+allergy)|'
  r'(?:\w+\s+)?allergies|(?:anyone|someone)\s+(?:with|who)\b|allergic)|'
  r'\b(?:celiac|coeliac|allergy|allergen)[- ]safe\b',
);

// ---------------------------------------------------------------- Spanish

/// Not a claim when a condition word comes shortly before it.
const _spanishCondition =
    r'(?<!\b(?:cuando|si|hasta\s+que|una\s+vez\s+que|en\s+cuanto|apenas|'
    r'mientras|revisa\s+si|comprueba\s+si|fíjate\s+si|para\s+ver\s+si)'
    r'\b[^.,;:!?¿¡]{0,40})';

/// "está" / "están", with or without the accent.
const _esta = r'est[áa]n?';

const _spanishClaimsPattern =
    '$_spanishCondition(?:'
    // ya está listo / ya está cocido / ya está hecho
    'ya\\s+$_esta\\s+(?:list|cocid|hech|cocinad)[oa]s?$_end|'
    // está (bien / totalmente) cocido / hecho
    '\\b$_esta\\s+(?:(?:ya|bien|totalmente|completamente|perfectamente)\\s+)*'
    '(?:cocid|hech|cocinad)[oa]s?$_end|'
    // está listo para comer / servir
    '\\b$_esta\\s+(?:ya\\s+)?list[oa]s?\\s+para\\s+(?:comer|servir|consumir)|'
    // es seguro comer(lo) / es seguro (not "es seguro que", not "no es")
    '(?<!\\bno\\s)\\b(?:es|son|$_esta)\\s+(?:(?:totalmente|completamente|'
    'perfectamente)\\s+)?segur[oa]s?$_end(?!\\s+(?:que|de\\s+que))|'
    // seguro para / de comer
    '\\bsegur[oa]s?\\s+(?:para|de)\\s+(?:comer|consumir|servir)|'
    // no hay peligro / riesgo, sin riesgo
    '\\bno\\s+hay\\s+(?:ningún\\s+|ningun\\s+)?(?:peligro|riesgo)$_end|'
    '\\bsin\\s+(?:ningún\\s+|ningun\\s+)?riesgo$_end|'
    // ya puedes comerlo / ya se puede comer
    '\\bya\\s+(?:puedes|pueden|puede|se\\s+puede)\\s+(?:comer|servir|consumir)|'
    // alcanzó / llegó a la temperatura
    '\\b(?:alcanz[óo]|alcanzaron|ha\\s+alcanzado|han\\s+alcanzado|'
    'lleg[óo]\\s+a|llegaron\\s+a)\\s+(?:la\\s+|una\\s+|su\\s+)?temperatura$_end|'
    // está fresco / no está echado a perder / no se ha echado a perder
    '\\b$_esta\\s+(?:(?:muy|bien|todavía|todavia|aún|aun)\\s+)*fresc[oa]s?$_end|'
    '\\bno\\s+$_esta\\s+(?:echad[oa]s?\\s+a\\s+perder|podrid[oa]s?|'
    'en\\s+mal\\s+estado|malo|mala)$_end|'
    '\\bno\\s+se\\s+ha\\s+echado\\s+a\\s+perder'
    ')';

final _spanishClaims = _re(_spanishClaimsPattern);

/// A visual cue presented as proof: "si se ve blanco por dentro está
/// cocido". No condition exemption.
final _spanishVisual = _re(
  r'\b(?:se\s+ven?|luce|lucen|parecen?|veas|ves|se\s+ponen?|'
  r'blanc[oa]s?|dorad[oa]s?|opac[oa]s?|transparentes?|firmes?|'
  r'ya\s+no\s+est[áa]n?\s+rosad[oa]s?|sin\s+rosa)'
  '$_end'
  r'[^.;!?]{0,60}\b(?:est[áa]n?|estar[áa]n?|es|son)\s+'
  r'(?:(?:ya|bien|totalmente|completamente)\s+)*'
  r'(?:cocid|hech|list|segur|cocinad)[oa]s?'
  '$_end',
);

/// A camera or photo reading a temperature or doneness.
final _spanishCamera = _re(
  r'\b(?:la\s+c[áa]mara|la\s+foto|la\s+imagen|el\s+video)\s+(?:ya\s+)?'
  r'(?:confirma|muestra|indica|mide|detecta|marca|dice|demuestra)'
  '$_end'
  r'[^.;!?]{0,50}(?:\d+\s*(?:°|º|grados)|temperatura|'
  r'est[áa]n?\s+(?:cocid|list|segur|hech)[oa]s?)|'
  r'\b(?:veo|puedo\s+ver)\s+que\b[^.;!?]{0,40}'
  r'(?:\d+\s*(?:°|º|grados)|temperatura\s+interna)|'
  r'\b(?:alcanz[óo]|lleg[óo]\s+a)\s+(?:los\s+)?\d+\s*(?:°|º|grados)',
);

const _spanishAllergenWords =
    r'(?:alérgenos?|alergenos?|gluten|nueces|maní|mani|cacahuates?|lácteos|'
    r'lacteos|huevos?|trigo|soya|soja|mariscos|ajonjolí|ajonjoli|sésamo|'
    r'sesamo|mostaza|leche|pescado)';

/// Allergen absence and dietary suitability. No condition exemption.
final _spanishAllergen = _re(
  '\\blibres?\\s+de\\s+$_spanishAllergenWords$_end|'
  '(?<!\\bsi\\s)\\bno\\s+contiene(?:n)?\\s+(?:ningún\\s+|ningun\\s+)?'
  '$_spanishAllergenWords$_end|'
  '\\b(?:es|son)\\s+(?:100\\s*%\\s+)?sin\\s+$_spanishAllergenWords$_end|'
  r'\bapt[oa]s?\s+para\s+(?:celíac|celiac|alérgic|alergic|intolerantes|'
  r'personas\s+con\s+alergia)|'
  r'\bsin\s+tacc\b|'
  r'\bhipoalerg[ée]nic[oa]s?'
  '$_end|'
  r'\bsegur[oa]s?\s+para\s+(?:celíac|celiac|alérgic|alergic|'
  r'personas\s+con\s+alergia|niños\s+con\s+alergia)',
);

final _all = [
  _englishClaims,
  _englishVisual,
  _englishCamera,
  _englishAllergen,
  _spanishClaims,
  _spanishVisual,
  _spanishCamera,
  _spanishAllergen,
];

/// True when [text] would certify doneness, temperature, freshness, allergen
/// absence or dietary suitability, in English or Spanish.
bool certifiesFoodSafety(String text) => _all.any((r) => r.hasMatch(text));

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

/// True when any cook-facing string in [json] certifies.
bool payloadCertifiesFoodSafety(Object? json) =>
    cookFacingStrings(json).any(certifiesFoodSafety);

/// Thrown when model-written UI would certify food safety. The caller shows
/// app-authored text instead.
class UnsafeClaimException extends FormatException {
  const UnsafeClaimException()
    : super(
        'It claimed doneness, temperature, freshness, allergen absence or '
        'dietary suitability. Never certify these; describe what is visible '
        'and tell the cook what to check with a thermometer or the label.',
      );
}
