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

const _nearMisses = [
  // English conditions and advice
  'Stir until it is done.',
  "It's done when it coats a spoon.",
  'Look for golden edges, then check with a thermometer.',
  "Neither the camera nor this coach can confirm doneness, internal "
      'temperature, freshness or allergens. Check with a food thermometer and '
      'trusted guidance.',
  "The camera can't measure temperature; use a thermometer.",
  'Use dairy-free milk if you need to.',
  'Check the label for peanuts.',
  // Spanish conditions (subjunctive or after a condition word)
  'Cocina hasta que esté cocido.',
  'Cuando esté listo, sírvelo.',
  'Cuando está listo, el pan suena hueco.',
  'Si está fresco, úsalo.',
  'Revisa si está cocido con un termómetro.',
  'Una vez que esté hecho, retíralo.',
  'Cocina hasta que se vea dorado y revisa con un termómetro.',
  'Si se ve blanco por dentro, revisa la temperatura con un termómetro.',
  // Spanish instructions and advice
  'Usa un termómetro para revisar la temperatura interna.',
  'Revisa que alcance 74 °C con un termómetro.',
  'Guárdalo en un lugar fresco.',
  'Ten lista la mantequilla de maní.',
  'La salsa queda lista para servir cuando la pruebes.',
  'Si huele mal, está echado a perder; tíralo.',
  'Revisa la etiqueta por si contiene maní.',
  'Si no contiene maní, úsalo.',
  'Usa pan sin gluten si lo necesitas.',
  'La cámara no puede medir la temperatura; usa un termómetro.',
  'La cámara no confirma la temperatura.',
  // other meanings
  'Es seguro que te va a gustar.',
  'No es seguro comerlo sin revisarlo.',
  'No hay prisa.',
  'No hay sal en la receta.',
  'Ya está el agua hirviendo.',
  'Ya puedes cortar el tomate.',
  'Está mezclado de forma pareja.',
];

void main() {
  group('claims are caught', () {
    for (final claim in _claims) {
      test(claim, () {
        expect(certifiesFoodSafety(claim), isTrue);
        expect(coachLiteCertifies(claim), isTrue);
      });
    }
  });

  group('near misses pass', () {
    for (final text in _nearMisses) {
      test(text, () => expect(certifiesFoodSafety(text), isFalse));
    }
  });

  test('the fallback note itself certifies nothing', () {
    expect(certifiesFoodSafety(cookSafetyFallbackNote), isFalse);
    expect(certifiesFoodSafety(coachLiteSafetyNotice), isFalse);
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
    expect(payloadCertifiesFoodSafety(payload), isFalse);
    expect(
      payloadCertifiesFoodSafety({
        'timerSuggestion': {'label': 'Chicken is safe to eat'},
      }),
      isTrue,
    );
    expect(const UnsafeClaimException().message, contains('Never certify'));
  });
}
