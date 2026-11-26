// Spanish phrases that would certify doneness, temperature, freshness or
// food safety (SS-106). The Spanish counterpart of Coach Lite's English
// certification check: AI answers in Spanish that match are never shown or
// read aloud. No imports, so any checker can use it.
//
// Spanish puts most conditions in the subjunctive ("hasta que esté cocido"),
// which these indicative patterns do not match. Habitual conditions in the
// indicative ("cuando está listo", "si está fresco") are excluded by the
// look-behind, as the English check excludes "when it is done".

/// Not a claim when a condition word comes shortly before it.
const _notACondition =
    r'(?<!\b(?:cuando|si|hasta\s+que|una\s+vez\s+que|en\s+cuanto|apenas|'
    r'mientras|revisa\s+si|comprueba\s+si|fíjate\s+si|para\s+ver\s+si)'
    r'\b[^.,;:!?¿¡]{0,40})';

/// "está" / "están", with or without the accent.
const _esta = r'est[áa]n?';

/// Ends a word, accented letters included.
const _end = r'(?![\p{L}])';

const spanishCertificationPattern =
    '$_notACondition(?:'
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
    '\\bno\\s+se\\s+ha\\s+echado\\s+a\\s+perder|'
    // libre de gluten / no contiene maní / es sin gluten
    '\\blibres?\\s+de\\s+(?:alérgenos?|alergenos?|gluten|nueces|maní|mani|'
    'cacahuates?|lácteos|lacteos|huevos?|trigo|soya|soja|mariscos)$_end|'
    '\\bno\\s+contiene(?:n)?\\s+(?:ningún\\s+|ningun\\s+)?(?:alérgenos?|alergenos?|'
    'gluten|nueces|maní|mani|cacahuates?|lácteos|lacteos|huevos?|trigo|soya|'
    'soja|mariscos)$_end|'
    '\\b(?:es|son)\\s+sin\\s+(?:gluten|lácteos|lacteos|nueces|maní|mani)$_end'
    ')';

final _spanishCertification = RegExp(
  spanishCertificationPattern,
  caseSensitive: false,
  unicode: true,
);

/// True when [text] would certify doneness, temperature, freshness or
/// safety in Spanish.
bool spanishCertifies(String text) => _spanishCertification.hasMatch(text);
