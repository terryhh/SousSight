import 'dart:async';
import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart'
    show HybridErrorCode, HybridMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/payload_digest.dart' show sha256Hex;
import 'package:soussight/app/cloud_send_recorder.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/trust/privacy_preferences.dart';
import 'package:soussight/illustrations/illustration_controller.dart';
import 'package:soussight/illustrations/illustration_generator.dart';
import 'package:soussight/illustrations/illustration_prompts.dart';

import 'fakes.dart';

const grate = StepTarget('grate');
const stir = StepTarget('stir');

Harness bound({
  Set<CloudRoute> routes = const {CloudRoute.images},
  Set<String> localOnly = const {},
  int cap = 4,
}) {
  final h = Harness(routes: routes, localOnly: localOnly, cap: cap);
  h.controller.bind(sessionId: 's1', recipeId: 'draft_abc', stepId: 'grate');
  return h;
}

void main() {
  final recipe = draftRecipe();

  test(
    'a granted request sends once, caches, and records one cloud leg',
    () async {
      final h = bound();
      expect(h.controller.availability(), isNull);
      expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
      await h.controller.request(recipe, grate);

      final state = h.controller.stateFor(grate);
      expect(state, isA<IllustrationReady>());
      expect((state as IllustrationReady).image.bytes, fakePng);
      expect(h.generator.prompts, hasLength(1));
      expect(h.generator.prompts.single, contains('Fine shreds of cucumber.'));

      // Consent was for this exact prompt, in this session, text only.
      final ask = h.consent.asks.single;
      expect(ask.feature, kIllustrationFeature);
      expect(ask.kinds, {DataKind.text});
      expect(ask.sessionId, 's1');
      expect(
        ask.payloadDigest,
        sha256Hex(utf8.encode(h.generator.prompts.single)),
      );

      final leg = h.ledger.entries.single;
      expect(leg.pending, isFalse);
      expect(leg.leg.feature, kIllustrationFeature);
      expect(leg.leg.kinds, {DataKind.text});
      expect(leg.leg.mode, HybridMode.onlyInCloud);
      expect(leg.leg.transferPermitted, isTrue);
      expect(leg.leg.provenance, Provenance.cloudAdapter);
      expect(leg.leg.modelLabel, 'fake-image-model (text→image)');
      expect(leg.leg.error, isNull);
      expect(h.controller.used, 1);
      expect(h.controller.remaining, 3);
      expect(h.controller.model, 'fake-image-model');
    },
  );

  test('a cache hit makes no call and asks nothing', () async {
    final h = bound();
    await h.controller.request(recipe, grate);
    await h.controller.request(recipe, grate);
    expect(h.generator.prompts, hasLength(1));
    expect(h.consent.asks, hasLength(1));
    expect(h.ledger.entries, hasLength(1));
    // Moving to another step and back keeps the session cache.
    h.controller.bind(sessionId: 's1', recipeId: 'draft_abc', stepId: 'stir');
    h.controller.bind(sessionId: 's1', recipeId: 'draft_abc', stepId: 'grate');
    expect(h.controller.stateFor(grate), isA<IllustrationReady>());
    await h.controller.request(recipe, grate);
    expect(h.generator.prompts, hasLength(1));
  });

  test('the per-session cap stops further sends', () async {
    final h = bound(cap: 2);
    await h.controller.request(recipe, grate);
    await h.controller.request(recipe, stir);
    expect(h.controller.remaining, 0);
    expect(h.controller.availability(), IllustrationBlock.capReached);
    await h.controller.request(recipe, const PlateTarget());
    expect(
      (h.controller.stateFor(
        const PlateTarget(),
      ) as IllustrationBlocked).reason,
      IllustrationBlock.capReached,
    );
    expect(h.generator.prompts, hasLength(2));
    expect(h.ledger.entries, hasLength(2));
    // A new session resets the cap and the cache.
    h.controller.bind(sessionId: 's2', recipeId: 'draft_abc', stepId: 'grate');
    expect(h.controller.remaining, 2);
    expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
  });

  test('a failed send still counts against the cap', () async {
    final h = bound(cap: 1);
    h.generator.error = const IllustrationException(HybridErrorCode.quota, 'q');
    await h.controller.request(recipe, grate);
    expect(
      (h.controller.stateFor(grate) as IllustrationFailed).code,
      HybridErrorCode.quota,
    );
    expect(h.controller.remaining, 0);
    final leg = h.ledger.entries.single;
    expect(leg.leg.transferPermitted, isTrue);
    expect(leg.leg.provenance, Provenance.unknown); // may have been sent
    expect(leg.leg.error, HybridErrorCode.quota);
  });

  test('an unexpected error fails closed and settles the leg', () async {
    final h = bound();
    h.generator.error = StateError('boom');
    await h.controller.request(recipe, grate);
    expect(
      (h.controller.stateFor(grate) as IllustrationFailed).code,
      HybridErrorCode.failed,
    );
    expect(lastLegError(h.ledger), HybridErrorCode.failed);
  });

  group('blocked before anything is sent', () {
    Future<void> expectBlocked(
      Harness h,
      IllustrationBlock reason, {
      bool asked = false,
    }) async {
      await h.controller.request(recipe, grate);
      final state = h.controller.stateFor(grate);
      expect(state, isA<IllustrationBlocked>());
      expect((state as IllustrationBlocked).reason, reason);
      expect(h.generator.prompts, isEmpty);
      expect(h.ledger.entries, isEmpty);
      expect(h.consent.asks, asked ? isNotEmpty : isEmpty);
      expect(h.controller.used, 0);
    }

    test('without the images route', () async {
      final h = bound(routes: const {CloudRoute.hybridFallback});
      expect(h.controller.availability(), IllustrationBlock.cloudNotApproved);
      await expectBlocked(h, IllustrationBlock.cloudNotApproved);
    });

    test('when the cook keeps illustrations on this device', () async {
      await expectBlocked(
        bound(localOnly: const {kIllustrationFeature}),
        IllustrationBlock.localOnly,
      );
    });

    test('when the cook keeps recipe drafting on this device', () async {
      await expectBlocked(
        bound(localOnly: const {'recipe_draft'}),
        IllustrationBlock.localOnly,
      );
    });

    test('offline', () async {
      final h = bound()..online = false;
      await expectBlocked(h, IllustrationBlock.offline);
    });

    test('when the cook declines', () async {
      final h = bound()..consent.allow = false;
      await expectBlocked(h, IllustrationBlock.consentDeclined, asked: true);
    });

    test('when the consent prompt fails', () async {
      final h = bound()..consent.error = StateError('no navigator');
      await expectBlocked(h, IllustrationBlock.consentDeclined, asked: true);
    });

    test('when the grant is for another payload, session or feature', () async {
      for (final forged in [
        const ConsentAsk(
          feature: kIllustrationFeature,
          kinds: {DataKind.text},
          payloadDigest: 'other',
          sessionId: 's1',
        ),
        ConsentAsk(
          feature: kIllustrationFeature,
          kinds: const {DataKind.audio},
          payloadDigest: sha256Hex(
            utf8.encode(illustrationPrompt(recipe, grate)!.text),
          ),
          sessionId: 's1',
        ),
        ConsentAsk(
          feature: kIllustrationFeature,
          kinds: const {DataKind.text, DataKind.image},
          payloadDigest: sha256Hex(
            utf8.encode(illustrationPrompt(recipe, grate)!.text),
          ),
          sessionId: 's1',
        ),
        ConsentAsk(
          feature: 'research',
          kinds: const {DataKind.text},
          payloadDigest: sha256Hex(utf8.encode('x')),
          sessionId: 's1',
        ),
      ]) {
        final h = bound()..consent.forge = forged;
        await expectBlocked(h, IllustrationBlock.consentDeclined, asked: true);
      }
      final h = bound();
      h.consent.whileOpen = () => h.consent.forge = ConsentAsk(
        feature: kIllustrationFeature,
        kinds: const {DataKind.text},
        payloadDigest: h.consent.asks.single.payloadDigest,
        sessionId: 'other-session',
      );
      await expectBlocked(h, IllustrationBlock.consentDeclined, asked: true);
    });

    test('when a recipe step has no picture', () async {
      final h = bound();
      final eggs = draftRecipe(
        ingredients: const [Ingredient(id: 'e', name: 'Eggs', qty: '2')],
      );
      await h.controller.request(eggs, const PlateTarget());
      expect(
        (h.controller.stateFor(
          const PlateTarget(),
        ) as IllustrationBlocked).reason,
        IllustrationBlock.noPicture,
      );
      expect(h.generator.prompts, isEmpty);
      expect(h.consent.asks, isEmpty);
    });
  });

  group('settings are re-read at send time, after consent', () {
    for (final (name, change, reason)
        in <(String, void Function(Harness), IllustrationBlock)>[
          (
            'local-only turned on',
            (h) => h.privacy.setLocalOnly(kIllustrationFeature, true),
            IllustrationBlock.localOnly,
          ),
          (
            'recipe draft local-only turned on',
            (h) => h.privacy.setLocalOnly('recipe_draft', true),
            IllustrationBlock.localOnly,
          ),
          ('went offline', (h) => h.online = false, IllustrationBlock.offline),
        ]) {
      test(name, () async {
        final h = bound();
        h.consent.whileOpen = () => change(h);
        await h.controller.request(recipe, grate);
        expect(
          (h.controller.stateFor(grate) as IllustrationBlocked).reason,
          reason,
        );
        expect(h.generator.prompts, isEmpty);
        expect(h.ledger.entries, isEmpty);
        expect(h.controller.used, 0);
      });
    }

    test('the route withdrawn while the prompt is open', () async {
      final h = Harness();
      var allowed = true;
      final routes = _SwitchRoutes(() => allowed);
      final controller = IllustrationController(
        cloudRoutes: routes,
        privacy: h.privacy,
        isOnline: () => true,
        consent: h.consent,
        recorder: LedgerCloudSendRecorder(h.ledger),
        generator: h.generator,
      )..bind(sessionId: 's1', recipeId: 'draft_abc', stepId: 'grate');
      h.consent.whileOpen = () => allowed = false;
      await controller.request(recipe, grate);
      expect(
        (controller.stateFor(grate) as IllustrationBlocked).reason,
        IllustrationBlock.cloudNotApproved,
      );
      expect(h.generator.prompts, isEmpty);
    });
  });

  group('stale results are dropped', () {
    test('a step change while generating drops the late image', () async {
      final h = bound()..generator.hold = true;
      final pending = h.controller.request(recipe, grate);
      await pumpEventQueue();
      expect(
        h.controller.stateFor(grate),
        isA<IllustrationLoading>().having((s) => s.sending, 'sending', isTrue),
      );
      h.controller.bind(sessionId: 's1', recipeId: 'draft_abc', stepId: 'stir');
      h.generator.release();
      await pending;
      expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
      // The send happened, so its leg is still settled.
      expect(h.ledger.entries.single.pending, isFalse);
      expect(h.ledger.entries.single.leg.provenance, Provenance.cloudAdapter);
    });

    test(
      'a step change while the consent prompt is open sends nothing',
      () async {
        final h = bound()..consent.gate = Completer<void>();
        final pending = h.controller.request(recipe, grate);
        await pumpEventQueue();
        h.controller.bind(
          sessionId: 's1',
          recipeId: 'draft_abc',
          stepId: 'stir',
        );
        h.consent.gate!.complete();
        await pending;
        expect(h.generator.prompts, isEmpty);
        expect(h.ledger.entries, isEmpty);
        expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
      },
    );

    test('session end drops the late image and empties the cache', () async {
      final h = bound();
      await h.controller.request(recipe, stir);
      h.generator.hold = true;
      final pending = h.controller.request(recipe, grate);
      await pumpEventQueue();
      h.controller.endSession();
      h.generator.release();
      await pending;
      expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
      expect(h.controller.stateFor(stir), isA<IllustrationIdle>());
      expect(h.controller.used, 0);
      // Without a session nothing can be requested.
      await h.controller.request(recipe, grate);
      expect(h.generator.prompts, hasLength(2));
      h.controller.endSession(); // a second end is a no-op
    });

    test('a failure after a step change shows nothing', () async {
      final h = bound()..consent.gate = Completer<void>();
      h.generator.error = const IllustrationException(
        HybridErrorCode.network,
        'n',
      );
      final pending = h.controller.request(recipe, grate);
      await pumpEventQueue();
      h.consent.gate!.complete();
      h.controller.bind(sessionId: 's1', recipeId: 'draft_abc', stepId: 'stir');
      await pending;
      expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
    });

    test('dispose drops the late image', () async {
      final h = bound()..generator.hold = true;
      final pending = h.controller.request(recipe, grate);
      await pumpEventQueue();
      h.controller.dispose();
      h.generator.release();
      await pending;
      expect(h.ledger.entries.single.pending, isFalse);
      // Calls after dispose are ignored.
      h.controller.bind(sessionId: 's9', recipeId: 'draft_abc', stepId: 'x');
      h.controller.endSession();
      await h.controller.request(recipe, grate);
      expect(h.generator.prompts, hasLength(1));
    });
  });

  test(
    'an image that does not decode is a failure, not a blank "ready"',
    () async {
      final h = bound()..decodes = false;
      await h.controller.request(recipe, grate);
      expect(
        (h.controller.stateFor(grate) as IllustrationFailed).code,
        HybridErrorCode.failed,
      );
      expect(h.decoded.single, fakePng);
      // The cloud did answer, so the leg is a confirmed send.
      expect(h.ledger.entries.single.leg.provenance, Provenance.cloudAdapter);
      expect(h.controller.used, 1);
    },
  );

  test('the leg is admitted before the generator is invoked', () async {
    final h = bound();
    final order = <String>[];
    String state() => switch (h.controller.stateFor(grate)) {
      IllustrationLoading(:final sending) => 'loading(sending=$sending)',
      IllustrationReady() => 'ready',
      final other => '${other.runtimeType}',
    };
    h.ledger.addListener(
      () => order.add(
        'ledger(pending=${h.ledger.entries.last.pending}), '
        'prompts=${h.generator.prompts.length}',
      ),
    );
    h.controller.addListener(
      () => order.add('${state()}, prompts=${h.generator.prompts.length}'),
    );
    await h.controller.request(recipe, grate);
    expect(order, [
      'loading(sending=false), prompts=0', // consent prompt opens
      'ledger(pending=true), prompts=0', // admitted, not yet dispatched
      'loading(sending=true), prompts=1',
      'ledger(pending=false), prompts=1', // confirmed
      'ready, prompts=1',
    ]);
  });

  test('a setting changed by a ledger observer at admission cancels the '
      'send', () async {
    final h = bound();
    h.ledger.addListener(() {
      if (h.ledger.entries.last.pending) {
        h.privacy.setLocalOnly('recipe_draft', true);
      }
    });
    await h.controller.request(recipe, grate);
    expect(h.generator.prompts, isEmpty);
    expect(
      (h.controller.stateFor(grate) as IllustrationBlocked).reason,
      IllustrationBlock.localOnly,
    );
    final leg = h.ledger.entries.single;
    expect(leg.pending, isFalse);
    expect(leg.leg.error, HybridErrorCode.cancelled);
    expect(h.controller.used, 0, reason: 'nothing was sent');
  });

  test(
    'a session rebind during admission leaves the new session clean',
    () async {
      final h = bound();
      h.ledger.addListener(() {
        if (h.ledger.entries.last.pending) {
          h.controller.bind(
            sessionId: 's2',
            recipeId: 'draft_abc',
            stepId: 'grate',
          );
        }
      });
      await h.controller.request(recipe, grate);
      expect(h.generator.prompts, isEmpty);
      expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
      expect(h.controller.used, 0);
      expect(h.controller.remaining, 4);
      expect(h.ledger.entries.single.leg.error, HybridErrorCode.cancelled);
    },
  );

  test('a rebind while generating never writes stale loading state', () async {
    final h = bound()..generator.hold = true;
    final pending = h.controller.request(recipe, grate);
    await pumpEventQueue();
    h.controller.bind(sessionId: 's2', recipeId: 'draft_abc', stepId: 'grate');
    h.generator.release();
    await pending;
    expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
    expect(h.controller.remaining, 4);
    expect(h.ledger.entries.single.pending, isFalse);
    h.generator.hold = false;
    await h.controller.request(recipe, grate);
    expect(h.controller.stateFor(grate), isA<IllustrationReady>());
    expect(h.controller.remaining, 3);
  });

  test('a ready image keeps its cloud source from the leg', () async {
    final h = bound();
    await h.controller.request(recipe, grate);
    final ready = h.controller.stateFor(grate) as IllustrationReady;
    expect(ready.source.provenance, Provenance.cloudAdapter);
    expect(ready.source.modelLabel, h.ledger.entries.single.leg.modelLabel);
    expect(ready.source.describe(), contains("Google's cloud"));
    expect(ready.source.describe(), contains('fake-image-model'));
    expect(
      const IllustrationSource(
        modelLabel: 'm',
        provenance: Provenance.unknown,
      ).describe(),
      isNot(contains('cloud')),
    );
  });

  test('privacy changes re-notify the panel; dispose unsubscribes', () {
    final prefs = InMemoryPrivacyPreferences();
    final h = Harness();
    final controller = IllustrationController(
      cloudRoutes: h.routes,
      privacy: prefs,
      isOnline: () => true,
      consent: h.consent,
      recorder: LedgerCloudSendRecorder(h.ledger),
      generator: h.generator,
      settingsChanges: prefs,
    );
    var notified = 0;
    controller.addListener(() => notified++);
    prefs.setLocalOnly('recipe_draft', true);
    expect(notified, 1);
    expect(controller.availability(), IllustrationBlock.localOnly);
    controller.dispose();
    prefs.setLocalOnly('recipe_draft', false);
  });

  test(
    'a setting changed by an observer before the final check blocks',
    () async {
      final h = bound();
      // The "waiting for consent" notice is the last notification before the
      // final check; a change made there must stop the send.
      var first = true;
      h.controller.addListener(() {
        if (first) h.privacy.setLocalOnly('recipe_draft', true);
        first = false;
      });
      await h.controller.request(recipe, grate);
      expect(
        (h.controller.stateFor(grate) as IllustrationBlocked).reason,
        IllustrationBlock.localOnly,
      );
      expect(h.generator.prompts, isEmpty);
      expect(h.ledger.entries, isEmpty);
    },
  );

  test('a generator that throws synchronously still settles its leg', () async {
    final h = Harness(cap: 4);
    final controller = IllustrationController(
      cloudRoutes: h.routes,
      privacy: h.privacy,
      isOnline: () => true,
      consent: h.consent,
      recorder: LedgerCloudSendRecorder(h.ledger),
      generator: _ThrowingGenerator(),
    )..bind(sessionId: 's1', recipeId: 'draft_abc', stepId: 'grate');
    await controller.request(recipe, grate);
    expect(controller.stateFor(grate), isA<IllustrationFailed>());
    expect(h.ledger.entries.single.leg.error, HybridErrorCode.failed);
  });

  test('a request in flight is not repeated', () async {
    final h = bound()..generator.hold = true;
    final first = h.controller.request(recipe, grate);
    await pumpEventQueue();
    await h.controller.request(recipe, grate);
    h.generator.release();
    await first;
    expect(h.generator.prompts, hasLength(1));
  });

  test('requests for another recipe or before binding are ignored', () async {
    final h = Harness();
    await h.controller.request(recipe, grate);
    expect(h.consent.asks, isEmpty);
    h.controller.bind(sessionId: 's1', recipeId: 'draft_other', stepId: 'a');
    await h.controller.request(recipe, grate);
    expect(h.consent.asks, isEmpty);
  });

  test('rebinding to the same place keeps state and does not notify', () {
    final h = bound();
    var notified = 0;
    h.controller.addListener(() => notified++);
    h.controller.bind(sessionId: 's1', recipeId: 'draft_abc', stepId: 'grate');
    expect(notified, 0);
  });

  test('a recipe change resets cache and cap', () async {
    final h = bound();
    await h.controller.request(recipe, grate);
    h.controller.bind(sessionId: 's1', recipeId: 'draft_xyz', stepId: 'grate');
    expect(h.controller.used, 0);
    expect(h.controller.stateFor(grate), isA<IllustrationIdle>());
  });

  test(
    'every block has cook-facing text; local-only says it needs the cloud',
    () {
      for (final b in IllustrationBlock.values) {
        expect(illustrationBlockText(b), isNotEmpty);
      }
      expect(
        illustrationBlockText(IllustrationBlock.localOnly),
        contains('need the cloud'),
      );
      expect(
        illustrationBlockText(IllustrationBlock.noPicture),
        kIllustrationNoDonenessCopy,
      );
    },
  );
}

class _SwitchRoutes extends CloudRoutes {
  _SwitchRoutes(this._on) : super(const {CloudRoute.images});
  final bool Function() _on;
  @override
  bool allows(CloudRoute route) => route == CloudRoute.images && _on();
}

class _ThrowingGenerator implements IllustrationGenerator {
  @override
  String get model => 'throws';
  @override
  Future<GeneratedIllustration> generate(String prompt) =>
      throw StateError('sync');
}
