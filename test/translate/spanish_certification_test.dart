// Spanish no-certification check (SS-106): table tests for claims and
// near misses, and that Coach Lite's own check (parse and read-aloud) uses
// it while the English behaviour is unchanged.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/coach_lite/coach_lite.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/spanish_certification.dart';
import 'package:soussight/translate/translation_guard.dart';

const _claims = [
  // doneness
  'Ya está listo.',
  'ya está lista, sírvela',
  'Ya están cocidos.',
  'Ya está hecho.',
  'El pollo está bien cocido.',
  'La carne está cocida.',
  'Está totalmente cocinado.',
  'Esta cocido', // no accent
  'Está listo para comer.',
  'Están listas para servir.',
  // safety
  'Es seguro comerlo.',
  'es seguro comer',
  'Es seguro.',
  'Son seguros para comer.',
  'Es seguro para comer.',
  'Está seguro de comer.',
  'No hay peligro.',
  'No hay ningún riesgo.',
  'Lo puedes servir sin riesgo.',
  'Ya puedes comerlo.',
  'Ya se puede comer.',
  // temperature
  'Alcanzó la temperatura.',
  'El pollo ya alcanzó la temperatura segura.',
  'Llegó a la temperatura interna correcta.',
  'Ha alcanzado su temperatura.',
  // freshness
  'Está fresco.',
  'La leche todavía está fresca.',
  'No está echado a perder.',
  'No está en mal estado.',
  'No se ha echado a perder.',
  // allergens
  'Es libre de gluten.',
  'Esta salsa no contiene maní.',
  'No contiene alérgenos.',
  'Es sin gluten.',
];

const _nearMisses = [
  // conditions (subjunctive or after a condition word)
  'Cocina hasta que esté cocido.',
  'Cuando esté listo, sírvelo.',
  'Cuando está listo, el pan suena hueco.',
  'Si está fresco, úsalo.',
  'Revisa si está cocido con un termómetro.',
  'Una vez que esté hecho, retíralo.',
  // instructions and advice
  'Usa un termómetro para revisar la temperatura interna.',
  'Revisa que alcance 74 °C con un termómetro.',
  'Guárdalo en un lugar fresco.',
  'Ten lista la mantequilla de maní.',
  'La salsa queda lista para servir cuando la pruebes.',
  'Si huele mal, está echado a perder; tíralo.',
  'Revisa la etiqueta por si contiene maní.',
  'Usa pan sin gluten si lo necesitas.',
  // other meanings
  'Es seguro que te va a gustar.',
  'No es seguro comerlo sin revisarlo.',
  'No hay prisa.',
  'No hay sal en la receta.',
  'Ya está el agua hirviendo.',
  'Ya puedes cortar el tomate.',
  'Está mezclado de forma pareja.',
];

String _coachAnswer(String body) => jsonEncode({
  'components': [
    {
      'id': 'root',
      'component': 'CookingColumn',
      'children': ['tip'],
    },
    {'id': 'tip', 'component': 'stepCue', 'title': 'Consejo', 'body': body},
  ],
});

void main() {
  group('Spanish claims are caught', () {
    for (final claim in _claims) {
      test(claim, () {
        expect(spanishCertifies(claim), isTrue);
        expect(coachLiteCertifies(claim), isTrue);
        expect(certifiesIn(claim, spanish), isTrue);
      });
    }
  });

  group('near misses pass', () {
    for (final text in _nearMisses) {
      test(text, () {
        expect(spanishCertifies(text), isFalse);
        expect(coachLiteCertifies(text), isFalse);
      });
    }
  });

  test('English behaviour is unchanged', () {
    expect(coachLiteCertifies("It's safe to eat."), isTrue);
    expect(coachLiteCertifies('The chicken is cooked through.'), isTrue);
    expect(coachLiteCertifies('Stir until it is done.'), isFalse);
    expect(coachLiteCertifies("It's done when it coats a spoon."), isFalse);
  });

  test('Coach Lite rejects a Spanish claim and accepts plain advice', () {
    expect(
      () => parseCoachLiteResponse(_coachAnswer('Ya está cocido.')),
      throwsFormatException,
    );
    expect(
      validateCoachLiteResponse(_coachAnswer('Ya puedes comerlo.')),
      isNotNull,
    );
    expect(
      parseCoachLiteResponse(
        _coachAnswer('Revuelve hasta que esté dorado y usa un termómetro.'),
      ).components,
      isNotEmpty,
    );
  });

  test('the Spanish language entry uses the same pattern', () {
    expect(spanish.certificationPattern, spanishCertificationPattern);
  });
}
