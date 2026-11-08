import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/pantry/wav.dart';

const _ids = {
  'peanut_butter_sandwich_v1',
  'chickpea_wrap_v1',
  'black_bean_corn_salsa_v1',
};

String _response({String recipeId = 'black_bean_corn_salsa_v1'}) => jsonEncode({
  'items': [
    {'name': 'canned black beans', 'confidence': 'high'},
    {'name': 'lime', 'confidence': 'low'},
  ],
  'meals': [
    {
      'recipeId': recipeId,
      'why': 'Beans and lime are most of it.',
      'matched': ['black beans', 'lime'],
      'missing': ['corn'],
    },
  ],
  'question': 'Do you have chips?',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parsePantryResult', () {
    test('accepts schema-shaped output from the bundled catalog', () {
      final result = parsePantryResult(_response(), _ids);
      expect(result.items.map((i) => i.name), ['canned black beans', 'lime']);
      expect(result.items.last.confidence, PantryConfidence.low);
      expect(result.meals.single.recipeId, 'black_bean_corn_salsa_v1');
      expect(result.meals.single.missing, ['corn']);
      expect(result.question, 'Do you have chips?');
      expect(result.simulated, isFalse);
    });

    test('rejects recipes outside the reviewed catalog', () {
      expect(
        () => parsePantryResult(_response(recipeId: 'invented_lasagna'), _ids),
        throwsFormatException,
      );
    });

    test('rejects malformed confidence, duplicates and non-objects', () {
      expect(
        () => parsePantryResult(
          jsonEncode({
            'items': [
              {'name': 'rice', 'confidence': 'certain'},
            ],
            'meals': [],
          }),
          _ids,
        ),
        throwsFormatException,
      );
      final duplicate = jsonDecode(_response()) as Map<String, dynamic>;
      duplicate['meals'] = [
        ...duplicate['meals'] as List,
        ...duplicate['meals'] as List,
      ];
      expect(
        () => parsePantryResult(jsonEncode(duplicate), _ids),
        throwsFormatException,
      );
      expect(() => parsePantryResult('[]', _ids), throwsFormatException);
      expect(() => parsePantryResult(null, _ids), throwsFormatException);
    });

    test('treats a missing or blank question as no question', () {
      final data = jsonDecode(_response()) as Map<String, dynamic>
        ..remove('question');
      expect(parsePantryResult(jsonEncode(data), _ids).question, isNull);
      data['question'] = '  ';
      expect(parsePantryResult(jsonEncode(data), _ids).question, isNull);
    });
  });

  group('GeminiPantryClient', () {
    test('sends one structured request with photo, WAV and catalog', () async {
      final recipes = await loadRecipeCatalog();
      PantryGenerationRequest? sent;
      final client = GeminiPantryClient(
        model: 'test-flash',
        generate: (request) async {
          sent = request;
          return _response();
        },
      );
      final wav = pcm16ToWav(Uint8List(32000));
      final result = await client.identify(
        PantryInput(
          text: 'beans',
          photoJpeg: Uint8List.fromList([0xff, 0xd8, 0xff]),
          audioWav: wav,
        ),
        recipes,
      );
      expect(result.meals.single.recipeId, 'black_bean_corn_salsa_v1');
      expect(sent!.model, 'test-flash');
      expect(sent!.config.responseMimeType, 'application/json');
      final schema = sent!.config.responseSchema!.toJson();
      final mealId =
          ((schema['properties'] as Map)['meals'] as Map)['items'] as Map;
      expect(
        ((mealId['properties'] as Map)['recipeId'] as Map)['enum'],
        kBundledRecipeIds,
      );
      final parts = sent!.content.parts;
      expect(parts.whereType<InlineDataPart>().map((p) => p.mimeType), [
        'image/jpeg',
        'audio/wav',
      ]);
      final catalog =
          jsonDecode((parts.first as TextPart).text) as Map<String, dynamic>;
      expect(
        (catalog['catalog'] as List).map((r) => (r as Map)['recipeId']),
        kBundledRecipeIds,
      );
      expect(sent!.systemInstruction, contains('Never judge freshness'));
    });

    test(
      'maps invented recipes and provider failures to safe messages',
      () async {
        final recipes = await loadRecipeCatalog();
        final invented = GeminiPantryClient(
          generate: (_) async => _response(recipeId: 'invented_lasagna'),
        );
        await expectLater(
          invented.identify(const PantryInput(text: 'pasta'), recipes),
          throwsA(isA<PantryException>()),
        );
        final offline = GeminiPantryClient(
          generate: (_) async => throw StateError('network api key leak'),
        );
        await expectLater(
          offline.identify(const PantryInput(text: 'pasta'), recipes),
          throwsA(
            isA<PantryException>().having(
              (e) => e.message,
              'message',
              isNot(contains('api key')),
            ),
          ),
        );
        await expectLater(
          GeminiPantryClient(generate: (_) async => _response())
              .identify(const PantryInput(), recipes),
          throwsA(isA<PantryException>()),
        );
      },
    );
  });

  test('WAV header describes 16 kHz mono PCM16', () {
    final pcm = Uint8List.fromList(List.generate(3200, (i) => i % 256));
    final wav = pcm16ToWav(pcm);
    final view = ByteData.sublistView(wav);
    expect(wav.length, 44 + 3200);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(view.getUint32(4, Endian.little), 36 + 3200);
    expect(ascii.decode(wav.sublist(8, 16)), 'WAVEfmt ');
    expect(view.getUint16(20, Endian.little), 1);
    expect(view.getUint16(22, Endian.little), 1);
    expect(view.getUint32(24, Endian.little), 16000);
    expect(view.getUint32(28, Endian.little), 32000);
    expect(view.getUint16(32, Endian.little), 2);
    expect(view.getUint16(34, Endian.little), 16);
    expect(ascii.decode(wav.sublist(36, 40)), 'data');
    expect(view.getUint32(40, Endian.little), 3200);
    expect(wav.sublist(44), pcm);
    // An odd trailing byte is not half a sample.
    expect(pcm16ToWav(Uint8List(5)).length, 48);
  });
}
