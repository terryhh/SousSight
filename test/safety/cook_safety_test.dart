// The shared cook-facing safety gate (SS-106): table tests for claims and
// near misses in English and Spanish, and the payload helpers. Pure Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/safety/cook_safety.dart';

const _claims = [
  // English doneness / safety (unchanged behaviour)
  "It's safe to eat.",
  'The chicken is cooked through.',
  'It is done.',
  'The chicken reached a safe temperature.',
  'No risk here.',
  // English visual proof (no condition exemption)
  "If it looks white inside, it's cooked.",
  'Once the juices run clear it is done.',
  'When it turns golden, it is safe to serve.',
  // English camera / temperature claims
  'The camera confirms 165°F.',
  'The camera shows the chicken is done.',
  'The photo shows an internal temperature of 74 °C.',
  'I can see it is at 165 degrees.',
  'It reached 165°F.',
  // English allergen / dietary assurances
  'This salad is sesame-free.',
  "It's completely nut-free.",
  'The sauce contains no peanuts.',
  'It is free of allergens.',
  'This is safe for celiacs.',
  'Suitable for people with allergies.',
  'A celiac-safe dish.',
  // Spanish doneness
  'Ya está listo.',
  'ya está lista, sírvela',
  'Ya están cocidos.',
  'Ya está hecho.',
  'El pollo está bien cocido.',
  'La carne está cocida.',
  'Está totalmente cocinado.',
  'Esta cocido',
  'Está listo para comer.',
  'Están listas para servir.',
  // Spanish safety
  'Es seguro comerlo.',
  'es seguro comer',
  'Es seguro.',
  'Son seguros para comer.',
  'Es seguro para comer.',
  'No hay peligro.',
  'No hay ningún riesgo.',
  'Lo puedes servir sin riesgo.',
  'Ya puedes comerlo.',
  'Ya se puede comer.',
  // Spanish temperature
  'Alcanzó la temperatura.',
  'El pollo ya alcanzó la temperatura segura.',
  'Llegó a la temperatura interna correcta.',
  'Ha alcanzado su temperatura.',
  'Alcanzó 74 °C.',
  // Spanish freshness
  'Está fresco.',
  'La leche todavía está fresca.',
  'No está echado a perder.',
  'No está en mal estado.',
  'No se ha echado a perder.',
  // Spanish visual proof: the condition is the problem
  'Si se ve blanco por dentro está cocido.',
  'Cuando se ve dorado, ya está listo.',
  'Si los jugos salen transparentes, está cocido.',
  // Spanish camera
  'La cámara confirma 74 °C.',
  'La cámara confirma que es seguro para comer.',
  'La foto muestra que está cocido.',
  'Veo que está a 74 °C.',
  // Spanish allergen / dietary
  'Es libre de gluten.',
  'Esta salsa no contiene maní.',
  'No contiene alérgenos.',
  'Es sin gluten.',
  'Este plato es apto para celíacos.',
  'Apta para alérgicos.',
  'Es sin TACC.',
  'Es hipoalergénico.',
  'Es seguro para personas con alergia.',
];

/// Visual-only coaching stays allowed.
const _allowed = [
  'Stir until golden.',
  'Spread it in a thin, even layer.',
  'Look for bubbling at the edges and crisp edges.',
  'Fold from the bottom up until evenly mixed.',
  'Cocina hasta que se vea dorado.',
  'Revuelve hasta que salgan burbujas.',
  'Los bordes quedan crujientes y brillantes.',
  'Corta en cubitos parejos.',
  'Ten a la mano la mantequilla de maní.',
  'Unta una capa delgada.',
];

/// Harmless sentences the conservative gate blocks on purpose: they use
/// the vocabulary, and over-blocking is the accepted cost.
const _overBlocked = [
  'Stir until it is done.',
  "It's done when it coats a spoon.",
  'Have your peanut butter ready.',
  "The camera can't measure temperature; use a thermometer.",
  'Use dairy-free milk if you need to.',
  'Cocina hasta que esté cocido.',
  'Cuando esté listo, sírvelo.',
  'Guárdalo en un lugar fresco.',
  'Usa pan sin gluten si lo necesitas.',
  'Revisa la etiqueta por si contiene maní.',
];

void main() {
  group('claims are caught', () {
    for (final claim in _claims) {
      test(claim, () {
        expect(touchesFoodSafety(claim), isTrue);
        expect(coachLiteCertifies(claim), isTrue);
      });
    }
  });

  group('visual-only coaching passes', () {
    for (final text in _allowed) {
      test(text, () => expect(touchesFoodSafety(text), isFalse));
    }
  });

  group('harmless but over-blocked on purpose', () {
    for (final text in _overBlocked) {
      test(text, () => expect(touchesFoodSafety(text), isTrue));
    }
  });

  test('second-round Codex probes are blocked', () {
    for (final text in [
      'The chicken is done when the juices run clear',
      'El pollo está a 74 °C según la cámara',
      'The milk is fresh',
      'Sesame-free',
    ]) {
      expect(touchesFoodSafety(text), isTrue, reason: text);
    }
  });

  test('the recipe\'s own reviewed text may be quoted verbatim', () {
    final panel = {
      'components': [
        {
          'id': 'cue',
          'component': 'stepCue',
          'title': 'Step',
          'body': 'Have your peanut butter ready.',
        },
      ],
    };
    expect(payloadTouchesFoodSafety(panel), isTrue);
    expect(
      payloadTouchesFoodSafety(
        panel,
        reviewed: {'Have your peanut butter ready.'},
      ),
      isFalse,
    );
    // Anything the model adds to it is still checked.
    expect(
      payloadTouchesFoodSafety(
        {'body': 'Have your peanut butter ready. It is safe.'},
        reviewed: {'Have your peanut butter ready.'},
      ),
      isTrue,
    );
  });

  test('payload helpers read cook-facing strings only', () {
    final payload = {
      'components': [
        {
          'id': 'safe_to_eat',
          'component': 'stepCue',
          'children': ['is done'],
          'title': 'Tip',
          'body': 'Stir gently.',
        },
      ],
      'timerSuggestion': {'label': 'Simmer', 'seconds': 60},
    };
    expect(cookFacingStrings(payload), ['Tip', 'Stir gently.', 'Simmer']);
    expect(payloadTouchesFoodSafety(payload), isFalse);
    expect(
      payloadTouchesFoodSafety({
        'timerSuggestion': {'label': 'Chicken is safe to eat'},
      }),
      isTrue,
    );
    expect(const UnsafeClaimException().message, contains('Never certify'));
  });
}
