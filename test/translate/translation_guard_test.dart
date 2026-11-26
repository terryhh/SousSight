// Line checks for recipe translation (SS-106). Pure Dart; no model.

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/translation_guard.dart';

LineRejection? _check(
  String source,
  String translated, {
  List<String> allergens = const [],
  CookLanguage language = spanish,
}) => checkTranslatedLine(
  source: source,
  translated: translated,
  language: language,
  allergens: [for (final a in allergens) allergenIngredient(a)],
);

void main() {
  group('extractQuantities', () {
    test('reads numbers with canonical units', () {
      expect(
        extractQuantities('Bake at 350°F for 20 to 25 minutes, then 1/2 cup.'),
        const [
          Quantity('350', 'temp_f'),
          Quantity('20', null),
          Quantity('25', 'minute'),
          Quantity('1/2', 'cup'),
        ],
      );
    });

    test('temperatures in words, bare degrees and percent', () {
      expect(extractQuantities('Heat to 180 degrees Celsius'), const [
        Quantity('180', 'temp_c'),
      ]);
      expect(extractQuantities('about 200 degrees and'), const [
        Quantity('200', 'temp'),
      ]);
      expect(extractQuantities('350F oven, 2% milk'), const [
        Quantity('350', 'temp_f'),
        Quantity('2', 'percent'),
      ]);
      expect(extractQuantities('180 °C'), const [Quantity('180', 'temp_c')]);
    });

    test('unicode fractions, decimals, hyphenated units, ranges', () {
      expect(extractQuantities('1½ tbsp and 1.5 oz, a 15-ounce can, 3-4 min'), [
        const Quantity('1', null),
        const Quantity('½', 'tbsp'),
        const Quantity('1.5', 'oz'),
        const Quantity('15', 'oz'),
        const Quantity('3', null),
        const Quantity('4', 'minute'),
      ]);
    });

    test('digits inside words are not quantities', () {
      expect(extractQuantities('Recipe v2 uses 2 eggs'), const [
        Quantity('2', null),
      ]);
    });

    test('Spanish unit words map to the same canonical units', () {
      expect(
        extractQuantities(
          'Hornea 20 minutos, 2 cucharadas, 1 cdta. y 3 horas',
          units: unitWordsFor(spanish),
        ),
        const [
          Quantity('20', 'minute'),
          Quantity('2', 'tbsp'),
          Quantity('1', 'tsp'),
          Quantity('3', 'hour'),
        ],
      );
    });

    test('Quantity equality, order and text', () {
      expect(const Quantity('2', 'cup'), const Quantity('2', 'cup'));
      expect(
        const Quantity('2', 'cup').hashCode,
        const Quantity('2', 'cup').hashCode,
      );
      expect('${const Quantity('2', 'cup')}', '2 cup');
      expect('${const Quantity('2', null)}', '2');
    });
  });

  group('checkTranslatedLine', () {
    test('accepts a faithful translation', () {
      expect(
        _check(
          'Simmer for 10 minutes with 1/2 cup water.',
          'Cocina a fuego lento 10 minutos con 1/2 taza de agua.',
        ),
        isNull,
      );
      // A temperature in a translation is gated, whatever the source says
      // (such lines stay in the reviewed English before translation).
      expect(
        _check('Bake at 350°F.', 'Hornea a 350°F.'),
        LineRejection.certifies,
      );
      expect(_check('about 2 tbsp', 'unas 2 cdas'), isNull);
      expect(_check('2 slices', '2 rebanadas'), isNull);
    });

    test('accepts the English unit kept as written', () {
      expect(_check('2 tbsp butter', 'mantequilla, 2 tbsp'), isNull);
    });

    test('rejects a changed, dropped, added or converted number', () {
      expect(
        _check('Bake 20 minutes', 'Hornea 25 minutos'),
        LineRejection.numbersChanged,
      );
      expect(
        _check('Bake 20 minutes', 'Hornea un rato'),
        LineRejection.numbersChanged,
      );
      expect(
        _check('Add two eggs', 'Agrega 3 huevos'),
        LineRejection.numbersChanged,
      );
      expect(
        _check('Add eggs', 'Agrega 2 huevos'),
        LineRejection.numbersChanged,
      );
      expect(
        _check('Bake at 350°F', 'Hornea a 175 °C'),
        LineRejection.numbersChanged,
      );
      expect(_check('Use 1/2 cup', 'Usa ½ taza'), LineRejection.numbersChanged);
      expect(
        _check('Use 1.5 cups', 'Usa 1,5 tazas'),
        LineRejection.numbersChanged,
      );
    });

    test('rejects a changed unit or a dropped temperature scale', () {
      expect(
        _check('Rest 10 minutes', 'Reposa 10 horas'),
        LineRejection.numbersChanged,
      );
      expect(
        _check('Bake at 350°F', 'Hornea a 350'),
        LineRejection.numbersChanged,
      );
      expect(
        _check('2 tsp salt', '2 cucharadas de sal'),
        LineRejection.numbersChanged,
      );
    });

    test('allergen names keep the English in parentheses', () {
      const allergens = ['Peanut butter', 'Bread'];
      expect(
        _check(
          'Spread the peanut butter on the bread.',
          'Unta la mantequilla de maní (peanut butter) en el pan (bread).',
          allergens: allergens,
        ),
        isNull,
      );
      expect(
        _check(
          'Spread the peanut butter on the bread.',
          'Unta la mantequilla de maní en el pan (bread).',
          allergens: allergens,
        ),
        LineRejection.allergenNameMissing,
      );
      // A line that names no allergen ingredient needs no parentheses.
      expect(
        _check(
          'Close the sandwich.',
          'Cierra el sándwich.',
          allergens: allergens,
        ),
        isNull,
      );
    });

    test('rejects added certification in English or Spanish', () {
      expect(
        _check('Cook the chicken.', 'El pollo está cocido.'),
        LineRejection.certifies,
      );
      expect(
        _check('Cook the chicken.', 'Si se ve blanco por dentro está cocido.'),
        LineRejection.certifies,
      );
      expect(
        _check('Serve.', 'Este plato es apto para celíacos.'),
        LineRejection.certifies,
      );
      expect(
        _check('Serve.', 'Es seguro para comer.'),
        LineRejection.certifies,
      );
      expect(
        _check('Serve.', 'Sirve; está libre de gluten.'),
        LineRejection.certifies,
      );
      expect(
        _check('Serve.', "Serve, it's safe to eat."),
        LineRejection.certifies,
      );
      // The gate over-blocks: even a condition using the vocabulary.
      expect(
        _check('Cook until done.', 'Cocina hasta que esté cocido.'),
        LineRejection.certifies,
      );
    });

    test('a disclaimer in the source never exempts the translation', () {
      // Codex #1: the reversed camera disclaimer.
      expect(
        _check(
          'The camera cannot tell whether this is safe to eat. Use a '
              'thermometer.',
          'La cámara confirma que es seguro para comer.',
        ),
        LineRejection.certifies,
      );
      expect(
        _check(
          'The camera cannot tell whether this is safe to eat. Use a '
              'thermometer.',
          'La cámara no puede saber si es seguro para comer. Usa un '
              'termómetro.',
        ),
        LineRejection.certifies,
      );
      // In the translator such a source line is never sent at all.
      expect(
        needsReviewedEnglish(
          'The camera cannot tell whether this is safe to eat.',
        ),
        isTrue,
      );
    });

    test('signs are kept, and a range is not a sign', () {
      expect(
        _check('Set the dial to -2.', 'Pon el selector en 2.'),
        LineRejection.numbersChanged,
      );
      expect(_check('Set the dial to -2.', 'Pon el selector en −2.'), isNull);
      expect(_check('Set the dial to −2.', 'Pon el selector en -2.'), isNull);
      expect(_check('Bake 3-4 minutes', 'Hornea 3-4 minutos'), isNull);
      expect(_check('Bake 3-4 minutes', 'Hornea 3 a 4 minutos'), isNull);
      expect(
        _check('Bake 3-4 minutes', 'Hornea 3 a -4 minutos'),
        LineRejection.numbersChanged,
      );
      expect(extractQuantities('at -18°C, 3-4 min, 3 - 4 min'), const [
        Quantity('-18', 'temp_c'),
        Quantity('3', null),
        Quantity('4', 'minute'),
        Quantity('3', null),
        Quantity('4', 'minute'),
      ]);
    });

    test('each quantity stays with its own instruction', () {
      // Codex #8: durations swapped between two actions.
      expect(
        _check(
          'Cool for 20 minutes, then bake for 5 minutes.',
          'Hornea 5 minutos y luego enfría 20 minutos.',
        ),
        LineRejection.numbersChanged,
      );
      expect(
        _check(
          'Cool for 20 minutes, then bake for 5 minutes.',
          'Enfría 20 minutos y luego hornea 5 minutos.',
        ),
        isNull,
      );
    });

    test('written numbers keep their value', () {
      expect(
        _check('Place two slices.', 'Pon diez rebanadas.'),
        LineRejection.numbersChanged,
      );
      expect(_check('Place two slices.', 'Pon dos rebanadas.'), isNull);
      expect(_check('Place two slices.', 'Pon 2 rebanadas.'), isNull);
      // "Ten" is Spanish for "have", not 10.
      expect(_check('Keep it close.', 'Ten todo a la mano.'), isNull);
      expect(
        extractQuantities(
          'dos tazas',
          units: unitWordsFor(spanish),
          numberWords: numberWordsFor(spanish),
        ),
        const [Quantity('2', 'cup')],
      );
    });

    test('allergen aliases need the English too', () {
      // Codex #9: "mayo" and "mustard" in the chickpea wrap step.
      const ingredients = ['Mayonnaise', 'Dijon mustard', 'Flour tortillas'];
      expect(
        _check(
          'Add mayo, mustard and lemon juice.',
          'Agrega mayonesa, mostaza y jugo de limón.',
          allergens: ingredients,
        ),
        LineRejection.allergenNameMissing,
      );
      expect(
        _check(
          'Add mayo, mustard and lemon juice.',
          'Agrega mayonesa (mayo), mostaza (mustard) y jugo de limón.',
          allergens: ingredients,
        ),
        isNull,
      );
      // The same word in both languages already shows the English.
      expect(
        _check(
          'Roll the tortilla.',
          'Enrolla la tortilla.',
          allergens: ingredients,
        ),
        isNull,
      );
      expect(
        allergenIngredient('Tortilla chips or tortillas').aliases,
        containsAll(['Tortilla chips', 'tortillas', 'tortilla']),
      );
      expect(allergenIngredient('Mayonnaise').aliases, ['Mayonnaise', 'mayo']);
    });

    test('rejects empty, runaway and markup output', () {
      expect(_check('Stir.', '   '), LineRejection.empty);
      expect(_check('Stir.', 'Revuelve. ' * 20), LineRejection.tooLong);
      expect(_check('Stir.', 'Revuelve <b>bien</b>.'), LineRejection.markup);
      expect(
        _check('Stir.', 'Revuelve: https://x.example'),
        LineRejection.markup,
      );
    });

    test('a language without a lexicon must keep English unit words', () {
      const plain = CookLanguage(code: 'xx', nativeName: 'X', modelName: 'X');
      expect(
        _check('Rest 10 minutes', 'zz 10 minutes', language: plain),
        isNull,
      );
      expect(
        _check('Rest 10 minutes', 'zz 10 minutos', language: plain),
        LineRejection.numbersChanged,
      );
      expect(certifiesIn('it is safe to eat', plain), isTrue);
      // The shared check covers English and Spanish for every language.
      expect(certifiesIn('está cocido', plain), isTrue);
      expect(certifiesIn('zz zz', plain), isFalse);
    });
  });

  group('second Codex round', () {
    test('safety, allergen, warning and multi-timing lines stay reviewed', () {
      for (final line in [
        // P1 #1: the bundled tortilla wheat warning.
        'Tortilla chips or tortillas, for serving (flour tortillas contain '
            'wheat; check labels)',
        'Bake at 350°F.',
        'Do not press hard enough to tear the bread.',
        'Check the label for allergens.',
        'Cool for 20 minutes, then bake for 5 minutes.',
        'The chicken is done when the juices run clear.',
      ]) {
        expect(needsReviewedEnglish(line), isTrue, reason: line);
      }
      for (final line in [
        'Toast the bread for 5 minutes.',
        'Warm the tortilla 15–20 seconds in a dry pan.',
        'Spread the peanut butter on the bread.',
      ]) {
        expect(needsReviewedEnglish(line), isFalse, reason: line);
      }
    });

    test('leading decimals and written quantities are compared', () {
      expect(
        _check('Add .5 cups', 'Agrega .9 tazas'),
        LineRejection.numbersChanged,
      );
      expect(_check('Add .5 cups', 'Agrega .5 tazas'), isNull);
      expect(
        _check('Cook for thirty minutes', 'Cocina durante veinte horas'),
        LineRejection.numbersChanged,
      );
      expect(
        _check('Cook for twenty minutes', 'Cocina durante veinte minutos'),
        isNull,
      );
    });

    test('allergen English must sit in parentheses after the word', () {
      const ingredients = ['Mayonnaise', 'Dijon mustard'];
      // "En mayo" is "in May": the mayonnaise was dropped.
      expect(
        _check(
          'Add mayo and mustard.',
          'En mayo añade mostaza (mustard).',
          allergens: ingredients,
        ),
        LineRejection.allergenNameMissing,
      );
      expect(
        _check(
          'Add mayo and mustard.',
          'Agrega mayonesa (mayo) y mostaza (mustard).',
          allergens: ingredients,
        ),
        isNull,
      );
      // A parenthesis with nothing before it explains nothing.
      expect(
        _check('Add mayo.', '(mayo) agrega.', allergens: ['Mayonnaise']),
        LineRejection.allergenNameMissing,
      );
    });
  });

  test('every rejection has a cook-facing sentence', () {
    for (final r in LineRejection.values) {
      expect(lineRejectionSentence(r), isNotEmpty);
    }
  });

  test('withEnglishName adds the English name once', () {
    expect(
      withEnglishName('Mantequilla de maní', 'Peanut butter'),
      'Mantequilla de maní (Peanut butter)',
    );
    expect(withEnglishName('Pan (bread)', 'Bread'), 'Pan (bread)');
  });

  test('allergenNamesIn matches whole words only', () {
    expect(allergenNamesIn('Add the eggplant', ['Egg']), isEmpty);
    expect(allergenNamesIn('Add the egg', ['Egg', ' ']), ['Egg']);
  });

  group('languages', () {
    test('English is the source; Spanish is registered', () {
      expect(sourceLanguage.isSource, isTrue);
      expect(spanish.isSource, isFalse);
      expect(cookLanguages, containsAllInOrder([sourceLanguage, spanish]));
      expect(cookLanguageFor('es-MX'), spanish);
      expect(cookLanguageFor('EN'), sourceLanguage);
      expect(cookLanguageFor('fr'), isNull);
      expect(spanish, isNot(sourceLanguage));
      expect(spanish.hashCode, 'es'.hashCode);
      expect('$spanish', 'CookLanguage(es)');
    });

    test('answer directive only for a non-source language', () {
      expect(answerLanguageDirective(sourceLanguage), isEmpty);
      expect(withAnswerLanguage('Base.', sourceLanguage), 'Base.');
      final es = withAnswerLanguage('Base.', spanish);
      expect(es, startsWith('Base.\n\n'));
      expect(es, contains(spanish.modelName));
      expect(es, contains('English name in parentheses'));
    });
  });
}
