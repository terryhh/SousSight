// SS-096: nearby lookups honour the `nearby` cloud route, the cook's "Keep
// Find food help on this device" switch and connectivity, read immediately
// before every send, and every attempt is a ledger leg. Fakes only: no model,
// Maps or network call is made.

import 'dart:async';
import 'dart:io';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:firebase_ai/firebase_ai.dart';
// SDK 5.1 exports the getters but not this constructor; fixtures only.
// ignore: implementation_imports
import 'package:firebase_ai/src/api.dart' show GroundingMetadata;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/app/cloud_send_recorder.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/nearby/nearby_client.dart';
import 'package:soussight/nearby/network_reachability.dart';
import 'package:soussight/nearby/network_reachability_io.dart'
    show reachableVia;
import 'package:soussight/trust/privacy_preferences.dart';

GenerateContentResponse _grounded({bool places = true}) =>
    GenerateContentResponse([
      Candidate(
        Content.text('One pantry nearby. Confirm hours before you go.'),
        null,
        null,
        FinishReason.stop,
        null,
        groundingMetadata: GroundingMetadata(
          groundingChunks: [
            if (places)
              GroundingChunk(
                maps: GoogleMapsGroundingChunk(
                  title: 'Pantry',
                  uri: 'https://maps.google.com/?cid=1',
                ),
              ),
          ],
          groundingSupports: [],
          webSearchQueries: [],
        ),
      ),
    ], null);

const _area = NearbyQuery(kind: NearbyKind.foodHelp, area: '32801');

class _Harness {
  _Harness({Set<CloudRoute> routes = const {CloudRoute.nearby}})
    : routes = CloudRoutes(routes);

  final CloudRoutes routes;
  final ledger = InferenceLedger(sessionId: 's1');
  final privacy = InMemoryPrivacyPreferences();
  var online = true;
  var reachable = true;
  final requests = <NearbyGenerationRequest>[];
  Future<GenerateContentResponse> Function() reply = () async => _grounded();

  late final gate = NearbyGate(
    cloudRoutes: routes,
    privacy: privacy,
    isOnline: () => online,
    recorder: LedgerCloudSendRecorder(ledger),
    reachable: () async => reachable,
  );

  late final client = GeminiNearbyClient(
    gate: gate,
    model: 'test-maps-model',
    timeout: const Duration(milliseconds: 50),
    generate: (request) {
      requests.add(request);
      return reply();
    },
  );
}

Matcher _fails(NearbyFailure reason, [Object? message]) => throwsA(
  isA<NearbyException>()
      .having((e) => e.reason, 'reason', reason)
      .having((e) => e.message, 'message', message ?? anything),
);

void main() {
  group('route', () {
    test('off: no request, an unsent leg, and a friendly message', () async {
      final h = _Harness(routes: const {CloudRoute.hybridFallback});
      expect(h.client.offered, isFalse);
      expect(h.client.precheck()?.message, nearbyRouteOffMessage);
      await expectLater(
        h.client.find(_area),
        _fails(NearbyFailure.blocked, nearbyRouteOffMessage),
      );
      expect(h.requests, isEmpty);
      final entry = h.ledger.entries.single;
      expect(entry.leg.feature, kNearbyFeature);
      expect(entry.leg.kinds, {DataKind.location, DataKind.text});
      expect(entry.leg.transferPermitted, isFalse);
      expect(entry.leg.error, HybridErrorCode.blocked);
      expect(entry.reportedSent, isFalse);
      expect(entry.pending, isFalse);
    });

    test('on: offered, and the precheck passes', () {
      final h = _Harness();
      expect(h.client.offered, isTrue);
      expect(h.client.precheck(), isNull);
    });

    test('a refused tap records exactly one unsent leg; precheck records '
        'nothing (Codex P2)', () {
      final h = _Harness();
      expect(h.client.refuseIfBlocked(), isNull);
      expect(h.ledger.entries, isEmpty, reason: 'allowed: nothing to record');

      h.privacy.setLocalOnly(kNearbyFeature, true);
      expect(h.client.precheck()?.message, nearbyKeptOnDeviceMessage);
      expect(h.ledger.entries, isEmpty);
      expect(h.client.refuseIfBlocked()?.message, nearbyKeptOnDeviceMessage);
      final entry = h.ledger.entries.single;
      expect(entry.leg.feature, kNearbyFeature);
      expect(entry.leg.transferPermitted, isFalse);
      expect(entry.leg.error, HybridErrorCode.blocked);
      expect(entry.reportedSent, isFalse);
      expect(h.requests, isEmpty);
    });
  });

  group('"Keep Find food help on this device"', () {
    test('blocks the send, read live at every send', () async {
      final h = _Harness();
      await h.client.find(_area);
      expect(h.requests, hasLength(1));

      h.privacy.setLocalOnly(kNearbyFeature, true);
      expect(h.client.offered, isTrue, reason: 'the cook can still see why');
      expect(h.client.precheck()?.message, nearbyKeptOnDeviceMessage);
      await expectLater(
        h.client.find(
          NearbyQuery(
            kind: NearbyKind.foodHelp,
            coordinates: NearbyCoordinates(28.5, -81.3),
          ),
        ),
        _fails(NearbyFailure.blocked, nearbyKeptOnDeviceMessage),
      );
      expect(h.requests, hasLength(1), reason: 'no location was sent');
      expect(h.ledger.entries.last.leg.transferPermitted, isFalse);
      expect(h.ledger.entries.last.leg.error, HybridErrorCode.blocked);

      h.privacy.setLocalOnly(kNearbyFeature, false);
      await h.client.find(_area);
      expect(h.requests, hasLength(2));
    });

    test('is one of the cook\'s privacy switches, labelled as asked', () {
      final nearby = privacyFeatures.singleWhere(
        (f) => f.feature == kNearbyFeature,
      );
      expect(
        'Keep ${nearby.label} on this device',
        'Keep Find food help on this device',
      );
    });
  });

  test('offline: nothing sent, an unsent leg, a friendly message', () async {
    final h = _Harness()..online = false;
    expect(h.client.precheck()?.reason, NearbyFailure.offline);
    await expectLater(
      h.client.find(_area),
      _fails(NearbyFailure.offline, nearbyOfflineMessage),
    );
    expect(h.requests, isEmpty);
    expect(h.ledger.entries.single.leg.transferPermitted, isFalse);
    expect(h.ledger.entries.single.leg.error, HybridErrorCode.network);
  });

  // Codex P2: on Android and iOS `isOnline` has no signal; the native probe
  // is what sees airplane mode.
  test(
    'no reachable network (native probe): nothing sent, an unsent leg',
    () async {
      final h = _Harness()..reachable = false;
      await expectLater(
        h.client.find(_area),
        _fails(NearbyFailure.offline, nearbyOfflineMessage),
      );
      expect(h.requests, isEmpty);
      final entry = h.ledger.entries.single;
      expect(entry.leg.transferPermitted, isFalse);
      expect(entry.leg.error, HybridErrorCode.network);
      expect(entry.reportedSent, isFalse);
    },
  );

  // Codex P2: begin() notifies ledger listeners synchronously; a listener
  // that turns on local-only must still stop the send.
  test('local-only turned on by a ledger listener during begin: not sent, '
      'and the pending leg is settled unsent', () async {
    final h = _Harness();
    h.ledger.addListener(() {
      if (h.ledger.entries.any((e) => e.pending)) {
        h.privacy.setLocalOnly(kNearbyFeature, true);
      }
    });
    await expectLater(
      h.client.find(_area),
      _fails(NearbyFailure.blocked, nearbyKeptOnDeviceMessage),
    );
    expect(h.requests, isEmpty, reason: 'the ZIP never reached Gemini');
    final entry = h.ledger.entries.single;
    expect(entry.pending, isFalse);
    expect(entry.leg.transferPermitted, isFalse);
    expect(entry.leg.error, HybridErrorCode.blocked);
    expect(entry.reportedSent, isFalse);
    expect(entry.uploadUnknown, isFalse);
  });

  test(
    'a failed send logs a category only, never the provider message',
    () async {
      final h = _Harness()
        ..reply = () => Future.error(
          const FormatException('echo: 32801 black beans AIzaSecretSecret'),
        );
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => logs.add('$message');
      addTearDown(() => debugPrint = previous);
      await expectLater(
        h.client.find(_area),
        _fails(NearbyFailure.unavailable),
      );
      debugPrint = previous;
      expect(logs.single, contains('malformed-response'));
      expect(logs.single, isNot(contains('32801')));
      expect(logs.single, isNot(contains('black beans')));
      expect(logs.single, isNot(contains('AIza')));
    },
  );

  test('nearbyErrorCategory maps errors to fixed labels', () {
    expect(nearbyErrorCategory(StateError('x 32801')), 'other');
    expect(nearbyErrorCategory(TimeoutException('t')), 'timeout');
    expect(
      nearbyErrorCategory(const FormatException('f')),
      'malformed-response',
    );
  });

  test('an invalid query is refused locally and recorded unsent', () async {
    final h = _Harness();
    await expectLater(
      h.client.find(const NearbyQuery(kind: NearbyKind.foodHelp)),
      _fails(NearbyFailure.invalidQuery),
    );
    expect(h.requests, isEmpty);
    final leg = h.ledger.entries.single.leg;
    expect(leg.transferPermitted, isFalse);
    expect(leg.error, HybridErrorCode.unsupportedInput);
  });

  test('a send is pending before it leaves and confirmed after', () async {
    final h = _Harness();
    final reply = Completer<GenerateContentResponse>();
    h.reply = () => reply.future;
    final result = h.client.find(_area);
    await pumpEventQueue(); // past the reachability probe
    // The leg exists while the request is in flight.
    expect(h.requests, hasLength(1));
    final pending = h.ledger.entries.single;
    expect(pending.pending, isTrue);
    expect(pending.leg.transferPermitted, isTrue);
    expect(pending.leg.kinds, {DataKind.location, DataKind.text});
    reply.complete(_grounded());
    expect((await result).places.single.title, 'Pantry');
    final done = h.ledger.entries.single;
    expect(done.pending, isFalse);
    expect(done.reportedSent, isTrue);
    expect(done.leg.provenance, Provenance.cloudAdapter);
    expect(done.leg.modelLabel, 'test-maps-model');
  });

  test('no grounded places: still a confirmed send', () async {
    final h = _Harness()..reply = () async => _grounded(places: false);
    await expectLater(h.client.find(_area), _fails(NearbyFailure.noResults));
    expect(h.ledger.entries.single.reportedSent, isTrue);
  });

  test('a failed send stays "may have been sent"', () async {
    final h = _Harness()..reply = () => Future.error(StateError('socket'));
    await expectLater(h.client.find(_area), _fails(NearbyFailure.unavailable));
    final entry = h.ledger.entries.single;
    expect(entry.pending, isFalse);
    expect(entry.reportedSent, isFalse);
    expect(entry.uploadUnknown, isTrue);
    expect(entry.leg.provenance, Provenance.unknown);
    expect(entry.leg.error, HybridErrorCode.network);
  });

  test('a timed-out send stays "may have been sent"', () async {
    final h = _Harness()
      ..reply = () => Completer<GenerateContentResponse>().future;
    await expectLater(h.client.find(_area), _fails(NearbyFailure.timeout));
    final entry = h.ledger.entries.single;
    expect(entry.uploadUnknown, isTrue);
    expect(entry.leg.error, HybridErrorCode.timeout);
  });

  group('wiring', () {
    HybridRuntime runtime(String routes) => HybridRuntime.create(
      inference: FakeHybridInference(),
      cloudRoutes: CloudRoutes.parse(routes),
      isOnline: () => true,
      cloudModel: 'test-model',
    );

    test('forRuntime reads the shared routes, switches and ledger', () async {
      final hybrid = runtime('nearby');
      final client = nearbyClientFor(isDemo: false, hybrid: hybrid);
      expect(client, isA<GeminiNearbyClient>());
      expect(nearbyOffered(client), isTrue);
      hybrid.privacy.setLocalOnly(kNearbyFeature, true);
      await expectLater(
        client!.find(_area),
        _fails(NearbyFailure.blocked, nearbyKeptOnDeviceMessage),
      );
      expect(hybrid.ledger.legs.single.feature, kNearbyFeature);
      expect(hybrid.ledger.legs.single.transferPermitted, isFalse);
    });

    test('production wiring uses the platform network probe', () {
      final gate = NearbyGate.forRuntime(runtime('nearby'));
      expect(identical(gate.reachable, networkReachable), isTrue);
    });

    test(
      'the native probe: a routable address is reachable; none, or only '
      'loopback and link-local, is not; an error is unknown (reachable)',
      () async {
        Future<List<NetworkInterface>> Function() with_(
          List<List<String>> addresses,
        ) =>
            () async => [
              for (final (i, list) in addresses.indexed)
                _Interface('if$i', [for (final a in list) _Address(a)]),
            ];
        expect(await reachableVia(with_([])), isFalse);
        expect(
          await reachableVia(
            with_([
              ['127.0.0.1'],
              ['fe80::1', '169.254.3.4'],
            ]),
          ),
          isFalse,
        );
        expect(
          await reachableVia(
            with_([
              ['fe80::1'],
              ['192.168.1.20'],
            ]),
          ),
          isTrue,
        );
        expect(await reachableVia(() => Future.error(StateError('x'))), isTrue);
        // On the test VM the platform probe really runs against the host.
        expect(await networkReachable(), isA<bool>());
      },
    );

    test('route off in the runtime: the client is not offered', () {
      expect(
        nearbyOffered(nearbyClientFor(isDemo: false, hybrid: runtime(''))),
        isFalse,
      );
    });

    test('rehearsal is simulated; no runtime means no client', () {
      expect(nearbyClientFor(isDemo: true), isA<FakeNearbyClient>());
      expect(nearbyOffered(nearbyClientFor(isDemo: true)), isTrue);
      expect(nearbyClientFor(isDemo: false), isNull);
      expect(nearbyOffered(null), isFalse);
    });
  });
}

class _Interface implements NetworkInterface {
  _Interface(this.name, this.addresses);
  @override
  final String name;
  @override
  final List<InterfaceAddress> addresses;
  @override
  int get index => 0;
}

class _Address implements InterfaceAddress {
  _Address(String address) : _address = InternetAddress(address);
  final InternetAddress _address;
  @override
  bool get isLoopback => _address.isLoopback;
  @override
  bool get isLinkLocal => _address.isLinkLocal;
  @override
  int get prefixLength => 0;
  @override
  InternetAddress? get broadcast => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
