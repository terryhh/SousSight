import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/label/household_allergens.dart';
import 'package:soussight/label/label_check.dart';
import 'package:soussight/label/label_check_controller.dart';
import 'package:soussight/label/label_payload_digest.dart';
import 'package:soussight/trust/privacy_preferences.dart';

import 'label_fakes.dart';

void main() {
  late FakeHybridDispatcher dispatcher;
  late InMemoryPrivacyPreferences privacy;
  late InMemoryHouseholdAllergens household;
  late ManualConsentGate gate;
  late HybridCapabilities caps;
  late bool online;

  LabelCheckController make({
    String sessionId = 's1',
    CloudRoutes cloudRoutes = const CloudRoutes({CloudRoute.hybridFallback}),
    bool withGate = true,
  }) => LabelCheckController(
    dispatcher: dispatcher,
    privacy: privacy,
    household: household,
    capabilities: () async => caps,
    sessionId: sessionId,
    consentGate: withGate ? gate : null,
    cloudRoutes: cloudRoutes,
    isOnline: () => online,
  );

  setUp(() {
    dispatcher = FakeHybridDispatcher();
    privacy = InMemoryPrivacyPreferences();
    household = InMemoryHouseholdAllergens(['peanut']);
    gate = ManualConsentGate();
    caps = webCaps;
    online = true;
  });

  group('photo on a device whose model reads images', () {
    test(
      'readable label: mentions, household matches, on-device leg',
      () async {
        final c = make();
        dispatcher.enqueue(readableWithPeanut);
        await c.checkPhoto(fakeJpeg());

        expect(gate.asks, isEmpty, reason: 'on-device: no consent prompt');
        final task = dispatcher.tasks.single;
        expect(task.feature, kLabelCheckFeature);
        expect(task.hasImage, isTrue);
        expect(task.jsonSchema, kLabelSchema);
        // Household allergens never go into the request.
        for (final part in task.parts.whereType<HybridText>()) {
          expect(part.text, isNot(contains('household')));
        }

        expect(c.phase, LabelCheckPhase.done);
        final result = c.result!;
        expect(result.source, LabelSource.photo);
        expect(result.reading.allergensMentioned, ['milk', 'peanut']);
        expect(c.matches, ['peanut']);
        expect(c.legs.single.provenance, Provenance.sdkOnDevice);
        expect(c.localModelFamily, 'Gemini Nano');

        household.setAllergen('milk', true);
        expect(c.matches, ['milk', 'peanut'], reason: 'matches are read live');
        c.dispose();
      },
    );

    test('unreadable label abstains', () async {
      final c = make();
      dispatcher.enqueue(unreadableJson);
      await c.checkPhoto(fakeJpeg());
      expect(c.result!.reading.saysNothingFound, isTrue);
      expect(c.matches, isEmpty);
      c.dispose();
    });

    test('malformed output becomes unreadable, never "no allergens"', () async {
      final c = make();
      dispatcher.enqueue(
        '{"readable": true, "allergensMentioned": ["peanut", "gluten"]}',
      );
      await c.checkPhoto(fakeJpeg());
      final reading = c.result!.reading;
      expect(reading.readable, isFalse);
      expect(reading.saysNothingFound, isTrue);
      expect(c.matches, isEmpty);
      c.dispose();
    });

    test('a blocked dispatch shows the reason and no reading', () async {
      final c = make();
      dispatcher.enqueueBlocked(RouteReason.modelDownloading);
      await c.checkPhoto(fakeJpeg());
      expect(c.result, isNull);
      expect(c.blockedReason, RouteReason.modelDownloading);
      expect(c.notice, contains('still downloading'));
      expect(c.notice, contains(kReadItYourselfWording));
      c.dispose();
    });

    test('a photo over the limits is not sent', () async {
      final c = make();
      await c.checkPhoto(fakeJpeg(width: 1600, height: 1200));
      expect(dispatcher.tasks, isEmpty);
      expect(c.notice, contains('too large'));
      c.dispose();
    });

    test('a new check clears the previous result', () async {
      final c = make();
      dispatcher.enqueue(readableWithPeanut);
      await c.checkPhoto(fakeJpeg());
      expect(c.result, isNotNull);
      dispatcher.enqueueBlocked(RouteReason.modelNotReady);
      await c.checkPhoto(fakeJpeg());
      expect(c.result, isNull);
      expect(c.matches, isEmpty);
      expect(c.blockedReason, RouteReason.modelNotReady);
      c.dispose();
    });
  });

  group('iOS (no local image input)', () {
    setUp(() => caps = iosCaps);

    test('offers the typed path and consent; sends nothing yet', () async {
      final c = make();
      await c.checkPhoto(fakeJpeg());
      expect(dispatcher.tasks, isEmpty);
      expect(gate.asks, isEmpty);
      expect(c.phase, LabelCheckPhase.awaitingChoice);
      expect(c.typedPathAvailable, isTrue);
      expect(c.cloudPhotoOffered, isTrue);
      c.dispose();
    });

    test('typed path runs as text only', () async {
      final c = make();
      await c.checkPhoto(fakeJpeg());
      c.discardPhoto();
      dispatcher.enqueue(
        '{"readable": true, "allergensMentioned": ["peanut"], '
        '"quote": "May contain peanuts"}',
      );
      await c.checkTyped('Ingredients: oats. May contain peanuts.');

      final task = dispatcher.tasks.single;
      expect(task.feature, kLabelCheckFeature);
      expect(task.hasImage, isFalse);
      expect(task.parts.single, isA<HybridText>());
      expect(
        (task.parts.single as HybridText).text,
        contains('May contain peanuts'),
      );
      expect(gate.asks, isEmpty);
      expect(c.result!.source, LabelSource.typed);
      expect(c.matches, ['peanut']);
      c.dispose();
    });

    test('typed path with no local model sends nothing', () async {
      caps = noneCaps;
      final c = make();
      await c.checkTyped('Contains: milk');
      expect(dispatcher.tasks, isEmpty);
      expect(c.notice, contains('nothing was sent'));
      c.dispose();
    });

    test(
      'consent granted: one send bound to the payload and session',
      () async {
        final c = make();
        await c.checkPhoto(fakeJpeg());
        dispatcher.enqueue(readableWithPeanut, provenance: Provenance.sdkCloud);
        final pending = c.sendPhotoToCloud();
        expect(c.phase, LabelCheckPhase.awaitingConsent);
        expect(dispatcher.tasks, isEmpty);
        final ask = gate.asks.single;
        expect(ask.feature, kLabelCheckFeature);
        expect(ask.sessionId, 's1');
        expect(ask.kinds, contains(DataKind.image));
        gate.grant();
        await pending;

        final task = dispatcher.tasks.single;
        expect(task.hasImage, isTrue);
        expect(ask.payloadDigest, labelPayloadDigest(task));
        expect(c.result!.reading.allergensMentioned, ['milk', 'peanut']);
        // The badge reflects the cloud leg, not the intent.
        expect(c.legs.single.provenance, Provenance.sdkCloud);
        expect(c.legs.single.transferPermitted, isTrue);
        c.dispose();
      },
    );

    test('consent declined: nothing sent', () async {
      final c = make();
      await c.checkPhoto(fakeJpeg());
      final pending = c.sendPhotoToCloud();
      gate.decline();
      await pending;
      expect(dispatcher.tasks, isEmpty);
      expect(c.phase, LabelCheckPhase.awaitingChoice);
      expect(c.notice, contains('stays on this device'));
      expect(c.result, isNull);
      c.dispose();
    });

    test('local-only switched on during the prompt: nothing sent', () async {
      final c = make();
      await c.checkPhoto(fakeJpeg());
      final pending = c.sendPhotoToCloud();
      privacy.setLocalOnly(kLabelCheckFeature, true);
      gate.grant();
      await pending;
      expect(dispatcher.tasks, isEmpty);
      expect(c.notice, contains('Nothing was sent'));
      expect(c.cloudPhotoOffered, isFalse);
      c.dispose();
    });

    test('going offline during the prompt: nothing sent', () async {
      final c = make();
      await c.checkPhoto(fakeJpeg());
      final pending = c.sendPhotoToCloud();
      online = false;
      gate.grant();
      await pending;
      expect(dispatcher.tasks, isEmpty);
      c.dispose();
    });

    test('local-only already on: no prompt and no send', () async {
      privacy.setLocalOnly(kLabelCheckFeature, true);
      final c = make();
      await c.checkPhoto(fakeJpeg());
      expect(c.cloudPhotoOffered, isFalse);
      await c.sendPhotoToCloud();
      expect(gate.asks, isEmpty);
      expect(dispatcher.tasks, isEmpty);
      c.dispose();
    });

    test('cloud route not approved: no prompt offered', () async {
      final c = make(cloudRoutes: const CloudRoutes({}));
      await c.checkPhoto(fakeJpeg());
      expect(c.cloudPhotoOffered, isFalse);
      await c.sendPhotoToCloud();
      expect(gate.asks, isEmpty);
      expect(dispatcher.tasks, isEmpty);
      c.dispose();
    });

    test('a grant for another payload is not used', () async {
      final c = make();
      await c.checkPhoto(fakeJpeg());
      final pending = c.sendPhotoToCloud();
      final asked = gate.asks.single;
      gate.grantFor(
        ConsentAsk(
          feature: asked.feature,
          kinds: asked.kinds,
          payloadDigest: 'other',
          sessionId: asked.sessionId,
        ),
      );
      await pending;
      expect(dispatcher.tasks, isEmpty);
      expect(c.notice, contains('different photo'));
      c.dispose();
    });

    test(
      'sheet closed during the prompt: a late grant sends nothing',
      () async {
        final c = make();
        await c.checkPhoto(fakeJpeg());
        final pending = c.sendPhotoToCloud();
        c.close();
        gate.grant();
        await pending;
        expect(dispatcher.tasks, isEmpty);
        c.dispose();
      },
    );

    test(
      'session changed during the prompt: a late grant sends nothing',
      () async {
        final c = make();
        await c.checkPhoto(fakeJpeg());
        final pending = c.sendPhotoToCloud();
        c.setSession('s2');
        gate.grant();
        await pending;
        expect(dispatcher.tasks, isEmpty);
        expect(c.phase, LabelCheckPhase.idle);
        c.dispose();
      },
    );
  });

  group('a capture outlived by its check', () {
    late Completer<Uint8List?> camera;
    Future<Uint8List?> take() => camera.future;
    setUp(() => camera = Completer<Uint8List?>());

    test('a capture completes normally and is checked', () async {
      dispatcher.enqueue(readableWithPeanut);
      final c = make();
      final pending = c.captureAndCheck(take);
      expect(c.phase, LabelCheckPhase.capturing);
      expect(c.busy, isTrue);
      camera.complete(fakeJpeg());
      await pending;
      expect(dispatcher.tasks, hasLength(1));
      expect(c.matches, ['peanut']);
      c.dispose();
    });

    test('session changed during capture: nothing is dispatched', () async {
      dispatcher.enqueue(readableWithPeanut);
      final c = make();
      final pending = c.captureAndCheck(take);
      c.setSession('s2');
      camera.complete(fakeJpeg());
      await pending;
      expect(dispatcher.tasks, isEmpty);
      expect(c.result, isNull);
      expect(c.phase, LabelCheckPhase.idle);
      c.dispose();
    });

    test('sheet closed during capture: nothing is dispatched', () async {
      final c = make();
      final pending = c.captureAndCheck(take);
      c.close();
      camera.complete(fakeJpeg());
      await pending;
      expect(dispatcher.tasks, isEmpty);
      c.dispose();
    });

    test('a newer check during capture discards the photo', () async {
      dispatcher.enqueue(unreadableJson);
      final c = make();
      final pending = c.captureAndCheck(take);
      await c.checkTyped('Contains: soy');
      camera.complete(fakeJpeg());
      await pending;
      expect(dispatcher.tasks, hasLength(1));
      expect(dispatcher.tasks.single.hasImage, isFalse);
      expect(c.result!.source, LabelSource.typed);
      c.dispose();
    });

    test('a failed or cancelled capture returns to idle', () async {
      final c = make();
      final pending = c.captureAndCheck(take);
      camera.completeError(StateError('camera blocked'));
      await pending;
      expect(dispatcher.tasks, isEmpty);
      expect(c.phase, LabelCheckPhase.idle);
      c.dispose();
    });
  });

  group('stale results', () {
    test('dropped after the sheet closes, and the send is cancelled', () async {
      dispatcher.delay = const Duration(milliseconds: 20);
      dispatcher.enqueue(readableWithPeanut);
      final c = make();
      final pending = c.checkPhoto(fakeJpeg());
      await Future<void>.delayed(Duration.zero);
      expect(c.phase, LabelCheckPhase.checking);
      c.close();
      await pending;
      expect(c.result, isNull);
      expect(dispatcher.cancelledOperations, ['op-1']);
      c.dispose();
    });

    test('dropped after the session changes', () async {
      dispatcher.delay = const Duration(milliseconds: 20);
      dispatcher.enqueue(readableWithPeanut);
      final c = make();
      final pending = c.checkPhoto(fakeJpeg());
      await Future<void>.delayed(Duration.zero);
      c.setSession('s2');
      await pending;
      expect(c.result, isNull);
      expect(c.legs, isEmpty);
      expect(c.phase, LabelCheckPhase.idle);
      expect(dispatcher.cancelledOperations, ['op-1']);
      c.dispose();
    });

    test('dropped when capabilities arrive after the sheet closed', () async {
      final c = LabelCheckController(
        dispatcher: dispatcher,
        privacy: privacy,
        household: household,
        capabilities: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return caps;
        },
        sessionId: 's1',
      );
      final pending = c.checkPhoto(fakeJpeg());
      c.close();
      await pending;
      expect(dispatcher.tasks, isEmpty);
      c.dispose();
    });

    test(
      'an older check finishing late does not replace a newer one',
      () async {
        dispatcher.delay = const Duration(milliseconds: 20);
        dispatcher.enqueue(readableWithPeanut);
        dispatcher.enqueue(unreadableJson);
        final c = make();
        final first = c.checkPhoto(fakeJpeg());
        await Future<void>.delayed(Duration.zero);
        final second = c.checkPhoto(fakeJpeg(width: 320, height: 240));
        await Future.wait([first, second]);
        expect(dispatcher.cancelledOperations, ['op-1']);
        expect(c.result!.reading.saysNothingFound, isTrue);
        c.dispose();
      },
    );
  });
}
