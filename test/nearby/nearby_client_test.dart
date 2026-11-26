import 'dart:async';

import 'package:firebase_ai/firebase_ai.dart';
// SDK 5.1 exports the getters but not this constructor. This import is only
// for grounding metadata fixtures; production uses the public response API.
// ignore: implementation_imports
import 'package:firebase_ai/src/api.dart' show GroundingMetadata;
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/app/cloud_send_recorder.dart';
import 'package:soussight/nearby/nearby_client.dart';

GenerateContentResponse _response({
  String answer = 'Two pantries are nearby. Confirm hours before you go.',
  List<GroundingChunk> chunks = const [],
}) => GenerateContentResponse([
  Candidate(
    Content.text(answer),
    null,
    null,
    FinishReason.stop,
    null,
    groundingMetadata: GroundingMetadata(
      groundingChunks: chunks,
      groundingSupports: [],
      webSearchQueries: [],
    ),
  ),
], null);

GroundingChunk _maps(String? title, String? uri, {String? placeId}) =>
    GroundingChunk(
      maps: GoogleMapsGroundingChunk(title: title, uri: uri, placeId: placeId),
    );

void main() {
  test('keeps only grounded HTTPS Google Maps places, deduped and capped', () {
    final result = parseNearbyResponse(
      _response(
        answer: 'Model prose with an invented https://made-up.example link.',
        chunks: [
          _maps(
            'Pantry A',
            'https://maps.google.com/?cid=1',
            placeId: 'places/a',
          ),
          _maps(
            'Pantry A again',
            'https://maps.google.com/?cid=9',
            placeId: 'places/a',
          ),
          _maps('Insecure', 'http://maps.google.com/?cid=2'),
          _maps('Script', 'javascript:alert(1)'),
          _maps('', 'https://maps.google.com/?cid=3'),
          _maps('User info', 'https://evil@maps.google.com/?cid=4'),
          GroundingChunk(
            web: WebGroundingChunk(
              title: 'Web page',
              uri: 'https://web.example',
            ),
          ),
          for (var i = 10; i < 20; i++)
            _maps('Place $i', 'https://maps.google.com/?cid=$i'),
        ],
      ),
    );
    expect(result.places.map((p) => p.title), [
      'Pantry A',
      'Place 10',
      'Place 11',
      'Place 12',
      'Place 13',
    ]);
    expect(result.places.first.placeId, 'places/a');
    expect(result.places.first.uri.scheme, 'https');
    expect(result.simulated, isFalse);
    expect(result.answer, contains('Model prose'));
  });

  test('no grounded Maps places is an explicit no-results state', () {
    for (final response in [
      _response(),
      _response(chunks: [_maps('Insecure', 'http://maps.google.com/')]),
      GenerateContentResponse([], null),
    ]) {
      expect(
        () => parseNearbyResponse(response),
        throwsA(
          isA<NearbyException>().having(
            (e) => e.reason,
            'reason',
            NearbyFailure.noResults,
          ),
        ),
      );
    }
  });

  test(
    'sends coordinates only through retrievalConfig, typed area as text',
    () async {
      final requests = <NearbyGenerationRequest>[];
      final client = GeminiNearbyClient(
        generate: (request) async {
          requests.add(request);
          return _response(
            chunks: [_maps('Pantry', 'https://maps.google.com/?cid=1')],
          );
        },
      );
      await client.find(
        NearbyQuery(
          kind: NearbyKind.foodHelp,
          coordinates: NearbyCoordinates(28.538336, -81.379234),
        ),
      );
      await client.find(
        const NearbyQuery(
          kind: NearbyKind.groceries,
          area: ' 32801 ',
          missingItems: ['tortillas', ' '],
        ),
      );
      expect(requests[0].model, kNearbyModel);
      expect(requests[0].coordinates!.latitude, 28.54);
      expect(requests[0].prompt, contains('near my current location'));
      expect(requests[0].prompt, isNot(contains('28.5')));
      expect(nearbyToolConfig(requests[0].coordinates)!.toJson(), {
        'retrievalConfig': {
          'latLng': {'latitude': 28.54, 'longitude': -81.38},
        },
      });
      expect(requests[1].coordinates, isNull);
      expect(nearbyToolConfig(null), isNull);
      expect(requests[1].prompt, contains('near "32801"'));
      expect(requests[1].prompt, contains('"tortillas"'));
      expect(requests[1].systemInstruction, contains('Do not invent'));
    },
  );

  test('rejects missing area and maps failures to safe copy', () async {
    final client = GeminiNearbyClient(
      generate: (_) => Future.error(Exception('API key leaked: secret')),
    );
    await expectLater(
      client.find(const NearbyQuery(kind: NearbyKind.foodHelp)),
      throwsA(
        isA<NearbyException>().having(
          (e) => e.reason,
          'reason',
          NearbyFailure.invalidQuery,
        ),
      ),
    );
    await expectLater(
      client.find(
        const NearbyQuery(kind: NearbyKind.foodHelp, area: 'Orlando'),
      ),
      throwsA(
        isA<NearbyException>()
            .having((e) => e.reason, 'reason', NearbyFailure.unavailable)
            .having((e) => e.message, 'message', isNot(contains('secret'))),
      ),
    );
    final slow = GeminiNearbyClient(
      timeout: const Duration(milliseconds: 10),
      generate: (_) => Completer<GenerateContentResponse>().future,
    );
    await expectLater(
      slow.find(const NearbyQuery(kind: NearbyKind.foodHelp, area: 'Orlando')),
      throwsA(
        isA<NearbyException>().having(
          (e) => e.reason,
          'reason',
          NearbyFailure.timeout,
        ),
      ),
    );
  });

  test('fake client labels simulated places', () async {
    final result = await const FakeNearbyClient(delay: Duration.zero)
        .find(const NearbyQuery(kind: NearbyKind.foodHelp));
    expect(result.simulated, isTrue);
    expect(result.places, isNotEmpty);
    expect(result.places.every((p) => p.title.contains('(simulated)')), isTrue);
    expect(result.places.every((p) => p.uri.scheme == 'https'), isTrue);
  });

  group('Codex #221: every nearby send writes one ledger leg', () {
    final here = NearbyQuery(
      kind: NearbyKind.foodHelp,
      coordinates: NearbyCoordinates(28.5, -81.4),
    );

    test('a shared location is recorded as sent', () async {
      final ledger = InferenceLedger(sessionId: 's');
      final client = GeminiNearbyClient(
        generate: (_) async => _response(
          chunks: [_maps('Pantry', 'https://maps.google.com/?cid=1')],
        ),
        recorder: LedgerCloudSendRecorder(ledger),
      );
      await client.find(here);
      final leg = ledger.legs.single;
      expect(leg.feature, kNearbyFeature);
      expect(leg.kinds, {DataKind.text, DataKind.location});
      expect(leg.provenance, Provenance.cloudAdapter);
    });

    test(
      'a typed area sends text only; a failure is recorded as uncertain',
      () async {
        final ledger = InferenceLedger(sessionId: 's');
        final client = GeminiNearbyClient(
          generate: (_) async => throw StateError('offline'),
          recorder: LedgerCloudSendRecorder(ledger),
        );
        await expectLater(
          client.find(
            const NearbyQuery(kind: NearbyKind.foodHelp, area: '32801'),
          ),
          throwsA(isA<NearbyException>()),
        );
        final leg = ledger.legs.single;
        expect(leg.kinds, {DataKind.text});
        expect(leg.transferPermitted, isTrue);
        expect(leg.provenance, Provenance.unknown);
        expect(leg.error, isNotNull);
      },
    );

    test('a refusal raised by the sender is recorded as failed', () async {
      final ledger = InferenceLedger(sessionId: 's');
      final client = GeminiNearbyClient(
        generate: (_) async => throw const NearbyException(
          NearbyFailure.unavailable,
          'Not now.',
        ),
        recorder: LedgerCloudSendRecorder(ledger),
      );
      await expectLater(client.find(here), throwsA(isA<NearbyException>()));
      expect(ledger.entries.single.pending, isFalse);
      expect(ledger.legs.single.error, isNotNull);
    });

    test('a timeout is recorded once', () async {
      final ledger = InferenceLedger(sessionId: 's');
      final client = GeminiNearbyClient(
        generate: (_) => Completer<GenerateContentResponse>().future,
        timeout: const Duration(milliseconds: 1),
        recorder: LedgerCloudSendRecorder(ledger),
      );
      await expectLater(client.find(here), throwsA(isA<NearbyException>()));
      expect(ledger.legs, hasLength(1));
      expect(ledger.entries.single.pending, isFalse);
    });

    test('an invalid query is refused before any leg', () async {
      final ledger = InferenceLedger(sessionId: 's');
      final client = GeminiNearbyClient(
        generate: (_) async => _response(),
        recorder: LedgerCloudSendRecorder(ledger),
      );
      await expectLater(
        client.find(const NearbyQuery(kind: NearbyKind.foodHelp)),
        throwsA(isA<NearbyException>()),
      );
      expect(ledger.legs, isEmpty);
    });
  });
}
