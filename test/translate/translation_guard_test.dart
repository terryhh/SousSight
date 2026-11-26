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
  allergenNames: allergens,
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
      expect(
        const Quantity('1', null).compareTo(const Quantity('2', null)),
        lessThan(0),
      );
      expect('${const Quantity('2', 'cup')}', '2 cup');
      expect('${const Quantity('2', null)}', '2');
    });
  });

  group('checkTranslatedLine', () {
    test('accepts a faithful translation', () {
      expect(
        _check(
          'Simmer for 10 minutes at 350°F with 1/2 cup water.',
          'Cocina a fuego lento 10 minutos a 350°F con 1/2 taza de agua.',
        ),
        isNull,
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
        _check('Add two eggs', 'Agrega 2 huevos'),
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
      // Conditions in the subjunctive are instructions, not claims.
      expect(
        _check('Cook until done.', 'Cocina hasta que esté cocido.'),
        isNull,
      );
    });

    test(
      'a certification already in the source is not the model adding it',
      () {
        expect(
          _check(
            'The sauce is done when it coats a spoon; it is safe to eat.',
            'La salsa: es seguro para comer.',
          ),
          isNull,
        );
      },
    );

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
      expect(certifiesIn('zz cocido', plain), isFalse);
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
