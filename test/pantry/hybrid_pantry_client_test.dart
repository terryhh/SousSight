import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_models.dart';
import 'package:soussight/pantry/pantry_ui.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

/// Records every task and validator; replies from a per-call script.
class _ScriptedDispatcher implements HybridDispatcher {
  final tasks = <HybridTask>[];
  final validators = <ResultValidator?>[];
  final sessions = <String>[];
  final script = <DispatchResult Function(HybridTask)>[];

  /// When set, the next send waits for this instead of the script.
  Completer<DispatchResult>? hold;

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    tasks.add(task);
    validators.add(validate);
    sessions.add(sessionId);
    if (hold case final pending?) {
      hold = null;
      return HybridOperation('op-${tasks.length}', pending.future, () {});
    }
    final next = script.removeAt(0);
    return HybridOperation(
      'op-${tasks.length}',
      Future(() => next(task)),
      () {},
    );
  }
}

InferenceLeg _leg(
  String feature,
  Provenance provenance, {
  HybridMode mode = HybridMode.preferOnDevice,
  HybridErrorCode? error,
}) => InferenceLeg(
  requestId: 'r-$feature-${provenance.name}',
  feature: feature,
  mode: mode,
  kinds: {DataKind.text},
  transferPermitted: provenance != Provenance.sdkOnDevice,
  provenance: provenance,
  error: error,
);

DispatchResult Function(HybridTask) _reply(
  String? text,
  Provenance provenance, {
  RouteReason? blocked,
}) =>
    (task) => DispatchResult(
      text: text,
      legs: [_leg(task.feature, provenance)],
      blocked: blocked,
    );

String _scan({List<String> items = const ['canned black beans']}) =>
    jsonEncode({
      'items': [
        for (final name in items) {'name': name, 'confidence': 'high'},
      ],
      'meals': [
        {
          'recipeId': 'black_bean_corn_salsa_v1',
          'why': 'Beans and corn are most of it.',
          'matched': ['black beans'],
          'missing': ['lime'],
        },
      ],
    });

String _voice(List<String> names) => jsonEncode({
  'items': [
    for (final name in names) {'name': name, 'confidence': 'medium'},
  ],
});

final _photo = Uint8List.fromList(List.filled(64, 7));
final _audio = Uint8List.fromList(List.filled(64, 3));

bool _hasAudio(HybridTask task) =>
    task.parts.any((p) => p is HybridInlineData && p.mimeType == 'audio/wav');

String _textOf(HybridTask task) => [
  for (final p in task.parts)
    if (p is HybridText) p.text,
].join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Recipe> recipes;
  late _ScriptedDispatcher dispatcher;
  late HybridPantryClient client;

  setUpAll(() async => recipes = await loadRecipeCatalog());
  setUp(() {
    dispatcher = _ScriptedDispatcher();
    client = HybridPantryClient(
      dispatcher: dispatcher,
      sessionId: () => 'session-1',
    );
  });

  test('photo and text go in one pantry_scan task; legs are carried', () async {
    dispatcher.script.add(_reply(_scan(), Provenance.sdkOnDevice));
    final result = await client.identify(
      PantryInput(text: 'corn', photoJpeg: _photo),
      recipes,
    );
    expect(dispatcher.tasks.map((t) => t.feature), [kPantryScanFeature]);
    expect(dispatcher.sessions, ['session-1']);
    final task = dispatcher.tasks.single;
    expect(task.hasImage, isTrue);
    expect(_hasAudio(task), isFalse);
    expect(_textOf(task), contains('"typedByCook":"corn"'));
    expect(result.meals.single.recipeId, 'black_bean_corn_salsa_v1');
    expect(result.legs.single.provenance, Provenance.sdkOnDevice);
    expect(result.notice, isNull);
  });

  test(
    'a voice clip is its own items-only task; only the scan ranks',
    () async {
      dispatcher.script
        ..add(_reply(_voice(['bread', 'peanut butter']), Provenance.sdkCloud))
        ..add(_reply(_scan(), Provenance.sdkOnDevice));
      final result = await client.identify(
        PantryInput(text: 'corn', photoJpeg: _photo, audioWav: _audio),
        recipes,
      );
      expect(dispatcher.tasks.map((t) => t.feature), [
        kPantryVoiceFeature,
        kPantryScanFeature,
      ]);
      final voice = dispatcher.tasks.first;
      expect(_hasAudio(voice), isTrue);
      expect(voice.parts.whereType<HybridInlineData>().map((p) => p.mimeType), [
        'audio/wav',
      ], reason: 'the photo stays in the scan');
      final voiceProps =
          voice.jsonSchema!['properties']! as Map<String, Object?>;
      expect(voiceProps.keys, ['items'], reason: 'the voice leg cannot rank');

      final scan = dispatcher.tasks.last;
      expect(_hasAudio(scan), isFalse, reason: 'audio is never sent twice');
      expect(scan.hasImage, isTrue);
      expect(_textOf(scan), contains('"saidByCook":["bread","peanut butter"]'));

      // Voice items stay candidates even when the ranking omits them.
      expect(result.items.map((i) => i.name), [
        'canned black beans',
        'bread',
        'peanut butter',
      ]);
      // Two legs, in order, never merged.
      expect(result.legs.map((l) => (l.feature, l.provenance)), [
        (kPantryVoiceFeature, Provenance.sdkCloud),
        (kPantryScanFeature, Provenance.sdkOnDevice),
      ]);
      expect(result.legs.map(pantryLegLabel), [
        "Voice list · sent online to Google's AI",
        'Meal match · on this device',
      ]);
      expect(result.notice, isNull);
    },
  );

  test('an unreadable voice answer is dropped and the cook is told', () async {
    dispatcher.script
      ..add(_reply('{"meals": []}', Provenance.sdkCloud))
      ..add(_reply(_scan(), Provenance.sdkOnDevice));
    final result = await client.identify(
      PantryInput(text: 'corn', audioWav: _audio),
      recipes,
    );
    expect(_textOf(dispatcher.tasks.last), isNot(contains('saidByCook')));
    expect(result.notice, kPantryVoiceSkippedNotice);
    expect(result.meals, isNotEmpty);
    expect(result.legs, hasLength(2), reason: 'the failed leg is still shown');
  });

  test('a blocked voice leg with nothing else to rank stops early', () async {
    dispatcher.script.add(
      _reply(null, Provenance.unknown, blocked: RouteReason.cloudNotApproved),
    );
    await expectLater(
      client.identify(PantryInput(audioWav: _audio), recipes),
      throwsA(isA<PantryException>()),
    );
    expect(dispatcher.tasks.map((t) => t.feature), [kPantryVoiceFeature]);
  });

  test('a voice leg that throws continues with the photo', () async {
    dispatcher.script
      ..add((_) => throw StateError('bridge gone'))
      ..add(_reply(_scan(), Provenance.sdkOnDevice));
    final result = await client.identify(
      PantryInput(photoJpeg: _photo, audioWav: _audio),
      recipes,
    );
    expect(result.notice, kPantryVoiceSkippedNotice);
    expect(result.meals, isNotEmpty);
  });

  test('the whole scan stays bound to the session it started in', () async {
    var session = 'A';
    client = HybridPantryClient(
      dispatcher: dispatcher,
      sessionId: () => session,
    );
    final voice = Completer<DispatchResult>();
    dispatcher.hold = voice;
    final scan = client.identify(
      PantryInput(photoJpeg: _photo, audioWav: _audio),
      recipes,
    );
    await Future<void>.delayed(Duration.zero);
    session = 'B';
    voice.complete(
      DispatchResult(
        text: _voice(['bread']),
        legs: [_leg(kPantryVoiceFeature, Provenance.sdkCloud)],
      ),
    );
    await expectLater(
      scan,
      throwsA(
        isA<PantryException>()
            .having((e) => e.message, 'message', contains('session changed'))
            .having((e) => e.legs.map((l) => l.provenance), 'legs', [
              Provenance.sdkCloud,
            ]),
      ),
    );
    expect(dispatcher.sessions, ['A'], reason: 'nothing is sent in B');
    expect(dispatcher.tasks.map((t) => t.feature), [kPantryVoiceFeature]);

    // Unchanged, both sends use the snapshot.
    session = 'C';
    dispatcher.script
      ..add(_reply(_voice(['bread']), Provenance.sdkCloud))
      ..add(_reply(_scan(), Provenance.sdkOnDevice));
    await client.identify(
      PantryInput(photoJpeg: _photo, audioWav: _audio),
      recipes,
    );
    expect(dispatcher.sessions.skip(1), ['C', 'C']);
  });

  test(
    'a declined ranking after a cloud voice leg reports the upload',
    () async {
      dispatcher.script
        ..add(_reply(_voice(['bread']), Provenance.sdkCloud))
        ..add(
          _reply(
            null,
            Provenance.unknown,
            blocked: RouteReason.consentDeclined,
          ),
        );
      await expectLater(
        client.identify(
          PantryInput(photoJpeg: _photo, audioWav: _audio),
          recipes,
        ),
        throwsA(
          isA<PantryException>()
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('photo and list were not sent'),
                  contains('voice clip was already sent to Google cloud'),
                  isNot(contains('nothing was sent')),
                ),
              )
              .having(
                (e) => e.legs.map((l) => (l.feature, l.provenance)).first,
                'voice leg',
                (kPantryVoiceFeature, Provenance.sdkCloud),
              ),
        ),
      );
    },
  );

  group('a declined ranking after a voice leg that may have uploaded', () {
    final maybeSent = isA<PantryException>().having(
      (e) => e.message,
      'message',
      allOf(
        contains('photo and list were not sent'),
        contains('voice clip may have been sent'),
        isNot(contains('was already sent')),
        isNot(contains('nothing was sent')),
      ),
    );
    DispatchResult declined(HybridTask task) => _reply(
      null,
      Provenance.unknown,
      blocked: RouteReason.consentDeclined,
    )(task);

    test('an unknown, transfer-permitted voice leg says "may have"', () async {
      dispatcher.script
        ..add(_reply(null, Provenance.unknown)) // e.g. a network error
        ..add(declined);
      await expectLater(
        client.identify(
          PantryInput(photoJpeg: _photo, audioWav: _audio),
          recipes,
        ),
        throwsA(
          allOf(
            maybeSent,
            isA<PantryException>().having(
              (e) => e.legs.first.provenance,
              'voice leg kept',
              Provenance.unknown,
            ),
          ),
        ),
      );
    });

    test('a voice send that threw says "may have"', () async {
      dispatcher.script
        ..add((_) => throw StateError('bridge gone'))
        ..add(declined);
      await expectLater(
        client.identify(
          PantryInput(photoJpeg: _photo, audioWav: _audio),
          recipes,
        ),
        throwsA(maybeSent),
      );
    });

    test('a voice leg blocked before sending means nothing was sent', () async {
      dispatcher.script
        ..add(
          (_) => const DispatchResult(
            legs: [],
            blocked: RouteReason.cloudNotApproved,
          ),
        )
        ..add(declined);
      await expectLater(
        client.identify(PantryInput(text: 'corn', audioWav: _audio), recipes),
        throwsA(
          isA<PantryException>().having(
            (e) => e.message,
            'message',
            contains('nothing was sent'),
          ),
        ),
      );
    });
  });

  test(
    'a declined scan with no earlier upload says nothing was sent',
    () async {
      dispatcher.script.add(
        _reply(null, Provenance.unknown, blocked: RouteReason.consentDeclined),
      );
      await expectLater(
        client.identify(const PantryInput(text: 'corn'), recipes),
        throwsA(
          isA<PantryException>().having(
            (e) => e.message,
            'message',
            contains('nothing was sent'),
          ),
        ),
      );
    },
  );

  test('a blocked scan surfaces a cook-facing message', () async {
    dispatcher.script.add(
      _reply(null, Provenance.unknown, blocked: RouteReason.localOnlySetting),
    );
    await expectLater(
      client.identify(const PantryInput(text: 'corn'), recipes),
      throwsA(
        isA<PantryException>().having(
          (e) => e.message,
          'message',
          contains('off for this feature'),
        ),
      ),
    );
  });

  test('the scan validator drives the on-device semantic retry', () async {
    dispatcher.script.add(_reply(_scan(), Provenance.sdkOnDevice));
    await client.identify(const PantryInput(text: 'corn'), recipes);
    final validate = dispatcher.validators.single!;
    expect(validate(_scan()), isNull);
    expect(validate('not json'), isNotNull);
    expect(
      validate(jsonEncode({'items': [], 'meals': []})),
      isNotNull,
      reason: 'an empty answer earns a cloud retry',
    );
    expect(
      validate(
        jsonEncode({
          'items': [],
          'meals': [
            {
              'recipeId': 'invented_lasagna',
              'why': '',
              'matched': [],
              'missing': [],
            },
          ],
        }),
      ),
      isNotNull,
      reason: 'a recipe outside the catalog is not a meal',
    );
  });

  test('empty and oversized input never reach the dispatcher', () async {
    await expectLater(
      client.identify(const PantryInput(), recipes),
      throwsA(isA<PantryException>()),
    );
    await expectLater(
      client.identify(PantryInput(text: 'x' * 1501), recipes),
      throwsA(isA<PantryException>()),
    );
    expect(dispatcher.tasks, isEmpty);
  });

  group('Android local budget', () {
    test('the largest ranking request fits $kPantryLocalTokenLimit tokens', () {
      final task = buildPantryScanTask(
        typedText: 'w' * 1500,
        spokenItems: List.filled(20, 'x' * 40),
        photoJpeg: _photo,
        recipes: recipes,
      );
      final estimate = estimateTaskTokens(task);
      printOnFailure('estimate: $estimate');
      expect(estimate, lessThanOrEqualTo(kPantryLocalTokenLimit));
    });

    test('a complete valid answer at the schema maxima fits the output '
        'budget', () {
      final ids = [for (var i = 0; i < kPantryMaxMeals; i++) 'recipe_${i}_v1'];
      final schema = pantryScanSchema(ids);
      final meals = (schema['properties']! as Map)['meals']! as Map;
      expect(meals['maxItems'], kPantryMaxMeals);
      final example = jsonEncode({
        'items': [
          for (var i = 0; i < kPantryMaxItems; i++)
            {'name': 'canned black beans $i', 'confidence': 'medium'},
        ],
        'meals': [
          for (final id in ids)
            {
              'recipeId': id,
              'why':
                  'Your beans, corn, tomato and onion cover most of this, '
                  'and it needs only a quick stir.',
              'matched': List.filled(6, 'canned black beans'),
              'missing': List.filled(6, 'tortilla chips'),
            },
        ],
        'question': 'Do you have tortilla chips or tortillas to serve it with?',
      });
      final parsed = parsePantryResult(example, ids.toSet());
      expect(parsed.items, hasLength(kPantryMaxItems));
      expect(parsed.meals, hasLength(kPantryMaxMeals));
      printOnFailure('example tokens: ${(example.length / 4).ceil()}');
      expect(
        (example.length / 4).ceil(),
        lessThanOrEqualTo(kPantryScanOutputTokens),
      );
    });

    test(
      'the cloud-only pantry instruction is not used for the local task',
      () {
        final task = buildPantryScanTask(
          typedText: 'corn',
          spokenItems: const [],
          photoJpeg: null,
          recipes: recipes,
        );
        expect(task.systemInstruction, pantryScanInstruction);
        expect(task.maxOutputTokens, lessThan(8192));
      },
    );
  });

  test('the direct Gemini client reports one cloud adapter leg', () async {
    final result = await GeminiPantryClient(generate: (_) async => _scan())
        .identify(PantryInput(text: 'corn', photoJpeg: _photo), recipes);
    expect(result.legs.single.provenance, Provenance.cloudAdapter);
    expect(result.legs.single.kinds, {DataKind.text, DataKind.image});
  });

  test('the rehearsal client labels its leg as simulated', () async {
    final result = await const FakePantryClient(delay: Duration.zero)
        .identify(const PantryInput(text: 'corn'), recipes);
    expect(result.legs.single.provenance, Provenance.simulated);
    expect(
      pantryLegLabel(result.legs.single),
      'Meal match · practice mode, pretend answer',
    );
  });

  test('an error leg that may have uploaded says so', () {
    expect(
      pantryLegLabel(
        _leg(
          kPantryScanFeature,
          Provenance.unknown,
          error: HybridErrorCode.network,
        ),
      ),
      "Meal match · may have been sent online to Google's AI · did not finish",
    );
  });
}
