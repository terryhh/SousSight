import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/label/household_allergens.dart';
import 'package:soussight/label/label_check.dart';
import 'package:soussight/label/label_payload_digest.dart';
import 'package:soussight/pantry/recipe_draft_client.dart';

import 'label_fakes.dart';

void main() {
  group('parseLabelReading', () {
    test('accepts a valid reading, normalised to display order', () {
      final r = parseLabelReading(
        '{"readable": true, "allergensMentioned": ["Soy ", "milk", "soy"], '
        '"quote": "Contains milk and soy"}',
      );
      expect(r.readable, isTrue);
      expect(r.allergensMentioned, ['milk', 'soy']);
      expect(r.quote, 'Contains milk and soy');
      expect(r.saysNothingFound, isFalse);
      expect(r.matches({'soy', 'egg'}), ['soy']);
    });

    test('readable with an empty list still says nothing was found', () {
      final r = parseLabelReading(
        '{"readable": true, "allergensMentioned": [], "quote": "Sugar"}',
      );
      expect(r.saysNothingFound, isTrue);
    });

    test('accepts a whole-answer Markdown fence', () {
      final r = parseLabelReading('```json\n$readableWithPeanut\n```');
      expect(r.allergensMentioned, ['milk', 'peanut']);
    });

    for (final (name, text) in [
      ('not JSON', 'Contains peanuts'),
      ('an array', '["peanut"]'),
      ('missing readable', '{"allergensMentioned": ["peanut"], "quote": ""}'),
      ('missing list', '{"readable": true, "quote": "x"}'),
      ('missing quote', '{"readable": true, "allergensMentioned": ["egg"]}'),
      (
        'string readable',
        '{"readable": "yes", "allergensMentioned": ["egg"], "quote": ""}',
      ),
      (
        'list as string',
        '{"readable": true, "allergensMentioned": "egg", "quote": ""}',
      ),
      (
        'non-string item',
        '{"readable": true, "allergensMentioned": [1], "quote": ""}',
      ),
      (
        'unknown allergen',
        '{"readable": true, "allergensMentioned": ["egg", "mustard"], "quote": ""}',
      ),
      (
        'null quote',
        '{"readable": true, "allergensMentioned": ["egg"], "quote": null}',
      ),
      (
        'unreadable with allergens',
        '{"readable": false, "allergensMentioned": ["egg"], "quote": ""}',
      ),
    ]) {
      test('$name abstains as unreadable', () {
        final r = parseLabelReading(text);
        expect(r.readable, isFalse);
        expect(r.allergensMentioned, isEmpty);
        expect(r.saysNothingFound, isTrue);
      });
    }

    test('long quotes are shortened', () {
      final r = parseLabelReading(
        jsonEncode({
          'readable': true,
          'allergensMentioned': ['egg'],
          'quote': 'x' * 500,
        }),
      );
      expect(r.quote.length, kMaxQuoteLength + 1);
    });
  });

  test('schema enum is exactly kDraftAllergens', () {
    final props = kLabelSchema['properties']! as Map;
    final items = (props['allergensMentioned'] as Map)['items'] as Map;
    expect(items['enum'], kDraftAllergens.toList());
    expect(kLabelSchema['required'], [
      'readable',
      'allergensMentioned',
      'quote',
    ]);
  });

  test('wording never claims a food is free of an allergen or safe', () {
    for (final text in [
      kUnreadableWording,
      kMentionsPrefix,
      kReadItYourselfWording,
      kHouseholdStaysHereWording,
    ]) {
      expect(text.toLowerCase(), isNot(contains('safe')));
      expect(text.toLowerCase(), isNot(contains('free')));
    }
    expect(kUnreadableWording, contains("doesn't mean there are none"));
  });

  group('sha256Hex', () {
    test('matches the standard test vectors', () {
      Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
      expect(
        sha256Hex(b('')),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex(b('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        sha256Hex(
          b('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('payload digest changes with any photo byte', () {
      HybridTask task(Uint8List photo) => HybridTask(
        feature: kLabelCheckFeature,
        parts: [
          const HybridText('read'),
          HybridInlineData(photo, 'image/jpeg'),
        ],
        maxOutputTokens: 10,
        timeout: const Duration(seconds: 1),
      );
      final a = fakeJpeg();
      final b = Uint8List.fromList(a)..[a.length - 3] ^= 1;
      expect(labelPayloadDigest(task(a)), labelPayloadDigest(task(a)));
      expect(labelPayloadDigest(task(a)), isNot(labelPayloadDigest(task(b))));
    });
  });

  group('photo limits', () {
    test('reads JPEG dimensions', () {
      expect(jpegSize(fakeJpeg(width: 768, height: 432)), (
        width: 768,
        height: 432,
      ));
      expect(labelPhotoProblem(fakeJpeg(width: 768, height: 768)), isNull);
    });

    test('rejects oversize, non-JPEG and over-1 MB photos', () {
      expect(labelPhotoProblem(fakeJpeg(width: 1024, height: 768)), isNotNull);
      expect(labelPhotoProblem(fakeJpeg(width: 600, height: 900)), isNotNull);
      expect(
        labelPhotoProblem(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
        isNotNull,
      );
      expect(
        labelPhotoProblem(fakeJpeg(padTo: kMaxLabelPhotoBytes + 1)),
        isNotNull,
      );
    });
  });

  test('household allergens ignore unknown values and notify on change', () {
    final household = InMemoryHouseholdAllergens(['peanut', 'mustard']);
    var notified = 0;
    household.addListener(() => notified++);
    expect(household.allergens, {'peanut'});
    household.setAllergen('mustard', true);
    household.setAllergen('peanut', true);
    expect(notified, 0);
    household.setAllergen('sesame', true);
    expect(household.allergens, {'peanut', 'sesame'});
    expect(notified, 1);
  });
}
