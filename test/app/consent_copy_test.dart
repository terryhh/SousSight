// SS-101: the plain-language cloud consent dialog. The wording names what is
// sent (from the payload kinds), where it goes and what SousSight keeps; a
// decline or a cancelled dialog never sends and never authorizes a later
// send. Every model here is a fake; nothing reaches a real service.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/pantry/pantry_client.dart';

ConsentAsk _ask(String feature, Set<DataKind> kinds) => ConsentAsk(
  feature: feature,
  kinds: kinds,
  payloadDigest: 'digest',
  sessionId: 'session',
);

class _CountingCloud implements CloudFallbackSender {
  int sends = 0;
  @override
  Future<HybridResult> send(HybridRequest request) async {
    sends++;
    return HybridResult(
      requestId: request.requestId,
      text: 'cloud answer',
      source: InferenceSource.cloud,
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

void main() {
  group('consent wording', () {
    for (final (feature, kinds, subject) in [
      ('nearby', {DataKind.text}, 'this question'),
      ('coach_lite', {DataKind.text}, 'your question'),
      ('label_check', {DataKind.image, DataKind.text}, 'this photo'),
      ('pantry_voice', {DataKind.audio, DataKind.text}, 'this voice clip'),
      ('nearby', {DataKind.location, DataKind.text}, 'your location'),
      (
        'pantry_scan',
        {DataKind.image, DataKind.audio, DataKind.text},
        'this photo and this voice clip',
      ),
      (
        'nearby',
        {DataKind.image, DataKind.audio, DataKind.location},
        'this photo, this voice clip and your location',
      ),
      (
        'recipe_draft',
        {DataKind.text},
        'your pantry list and any note you added',
      ),
      ('pantry_scan', {DataKind.text}, 'the list you typed or said'),
      ('pantry_voice', {DataKind.text}, 'what you said'),
      ('label_check', {DataKind.text}, 'the label text you typed'),
    ]) {
      test('$feature $kinds says "$subject"', () {
        final ask = _ask(feature, kinds);
        expect(consentSubject(ask), subject);
        final copy = consentCopy(ask);
        // Cloud-only features (pantry voice) send on a yes; the rest only
        // if this device can't answer.
        final direct = feature == 'pantry_voice';
        expect(
          copy.title,
          direct
              ? 'Send $subject to Google?'
              : 'Send $subject to Google if needed?',
        );
        if (direct) {
          expect(
            copy.body,
            startsWith('Pantry voice note needs Google for this.'),
          );
        }
        expect(copy.body, contains('sends $subject'));
        expect(copy.body, contains("to Google's servers to answer"));
        expect(
          copy.body,
          contains('"Keep it on my phone", nothing from this request is sent'),
        );
        expect(copy.allow, 'Send this once');
        expect(copy.decline, 'Keep it on my phone');
      });
    }

    test('names everything that goes with a photo', () {
      expect(
        consentCopy(_ask('label_check', {DataKind.image, DataKind.text})).body,
        contains(
          "sends this photo, with SousSight's short instructions, to Google",
        ),
      );
      expect(
        consentCopy(_ask('pantry_scan', {DataKind.image, DataKind.text})).body,
        contains(
          'sends this photo, with anything you typed, any items picked out '
          "from your voice note and SousSight's recipe list, to Google",
        ),
      );
      expect(
        consentCopy(_ask('coach_lite', {DataKind.image, DataKind.text})).body,
        contains('with your question and the recipe step you are on'),
      );
      expect(
        consentCopy(_ask('label_check', {DataKind.image})).body,
        contains('sends this photo to Google'),
      );
      expect(consentCompanion(_ask('coach_lite', {DataKind.text})), isEmpty);
    });

    test('says Google may receive it, never that it was sent', () {
      final copy = consentCopy(
        _ask('pantry_scan', {DataKind.image, DataKind.text}),
      );
      expect(copy.title, endsWith('if needed?'));
      expect(copy.body, startsWith('Pantry scan may need help from Google.'));
      expect(
        copy.body,
        contains("If you say yes and this device can't answer"),
      );
      expect(copy.body, contains('Your yes covers this one request only.'));
      for (final claim in [
        'It goes',
        'is sent to',
        'will be sent',
        'needs help',
      ]) {
        expect(copy.body, isNot(contains(claim)));
      }
    });

    test('the explicit watch cloud check says a yes sends this photo', () {
      final copy = consentCopy(
        _ask('local_watch_cloud_check', {DataKind.image, DataKind.text}),
      );
      expect(copy.title, 'Send this photo to Google?');
      expect(
        copy.body,
        startsWith(
          'Watch my food wants a second look from Google. If you say yes, '
          'SousSight sends this photo, with the recipe step you are on, to '
          "Google's servers to check it.",
        ),
      );
      expect(copy.body, isNot(contains("can't answer by itself")));
      expect(copy.body, isNot(contains('if needed')));
      // The pantry fallback keeps the conditional wording.
      final pantry = consentCopy(
        _ask('pantry_scan', {DataKind.image, DataKind.text}),
      );
      expect(pantry.title, endsWith('if needed?'));
      expect(pantry.body, contains("this device can't answer by itself"));
    });

    test('storage: no saved media, stated apart from in-memory retention', () {
      final photo = consentCopy(
        _ask('label_check', {DataKind.image, DataKind.text}),
      ).body;
      expect(
        photo,
        contains(
          "SousSight doesn't save photos or voice clips on this device or "
          'online, though the app may still hold them in memory for a while.',
        ),
      );
      expect(photo, isNot(contains('only in memory for')));
      // No lifetime is promised: image previews share Flutter's ImageCache.
      expect(photo, isNot(contains('leave this screen')));
      expect(photo, isNot(contains('this one time only')));
      // Text alone: no storage claim is made either way.
      final text = consentCopy(_ask('coach_lite', {DataKind.text})).body;
      expect(text, isNot(contains('save')));
    });

    test('names the feature and uses no technical jargon', () {
      final copy = consentCopy(
        _ask('label_check', {DataKind.image, DataKind.text}),
      );
      expect(copy.body, startsWith('Label check may need help from Google.'));
      for (final jargon in [
        'Firebase',
        'AI Logic',
        'cloud AI',
        'Gemini',
        'model',
        'payload',
      ]) {
        expect('${copy.title} ${copy.body}', isNot(contains(jargon)));
      }
    });

    test('does not promise anything on Google\'s behalf', () {
      final body = consentCopy(_ask('coach_lite', {DataKind.text})).body;
      expect(body, contains("Google's own privacy terms cover"));
      expect(body, isNot(contains("Google doesn't")));
      expect(body, isNot(contains('deleted')));
    });
  });

  group('consent dialog', () {
    Future<({GlobalKey<NavigatorState> key, DialogConsentGate gate})> pumpGate(
      WidgetTester tester,
    ) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      return (
        key: key,
        gate: DialogConsentGate(navigatorKey: key, cloudModel: 'm'),
      );
    }

    testWidgets('shows the plain copy and both buttons', (tester) async {
      final (:key, :gate) = await pumpGate(tester);
      final ask = _ask('pantry_voice', {DataKind.audio, DataKind.text});
      unawaited(gate.request(ask));
      await tester.pumpAndSettle();
      expect(find.text('Send this voice clip to Google?'), findsOneWidget);
      expect(find.text(consentCopy(ask).body), findsOneWidget);
      expect(find.text('Send this once'), findsOneWidget);
      expect(find.text('Keep it on my phone'), findsOneWidget);
      expect(find.textContaining('Firebase'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('consent-decline')));
      await tester.pumpAndSettle();
    });

    testWidgets('shows the exact photo with the photo copy', (tester) async {
      final (:key, :gate) = await pumpGate(tester);
      final png = Uint8List.fromList(const [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0A,
        0x49,
        0x44,
        0x41,
        0x54,
        0x78,
        0x9C,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);
      final framed = FramePreviewConsentGate(gate, () => png);
      ConsentGrant? grant;
      unawaited(
        framed
            .request(_ask('label_check', {DataKind.image, DataKind.text}))
            .then((g) => grant = g),
      );
      await tester.pumpAndSettle();
      expect(find.text('Send this photo to Google if needed?'), findsOneWidget);
      expect(find.byKey(const ValueKey('consent-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('consent-allow')));
      await tester.pumpAndSettle();
      expect(grant, isNotNull);
    });

    testWidgets('a dialog closed without an answer is a decline', (
      tester,
    ) async {
      final (:key, :gate) = await pumpGate(tester);
      ConsentGrant? grant;
      var done = false;
      unawaited(
        gate
            .request(_ask('coach_lite', {DataKind.text}))
            .then((g) => (grant, done) = (g, true)),
      );
      await tester.pumpAndSettle();
      // The app closes the route (e.g. the screen goes away): no answer.
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(grant, isNull);
    });
  });

  group('decline never sends', () {
    // A photo needs a per-payload grant (text alone may fall back without a
    // prompt, per the feature's UploadConsent).
    final task = HybridTask(
      feature: 'pantry_scan',
      parts: [
        const HybridText('List the food in this photo.'),
        HybridInlineData(Uint8List.fromList(const [1, 2, 3]), 'image/jpeg'),
      ],
      maxOutputTokens: 64,
      timeout: const Duration(seconds: 5),
    );

    Future<
      ({
        HybridRuntime hybrid,
        FakeHybridInference inference,
        _CountingCloud cloud,
      })
    >
    pumpRuntime(WidgetTester tester) async {
      // No on-device model, so the only way to answer is the cloud, which
      // needs the cook's consent for each exact payload.
      final inference = FakeHybridInference(
        capabilities: const HybridCapabilities.none(),
        textAvailability: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
        ),
        imageAvailability: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
        ),
      );
      final cloud = _CountingCloud();
      final hybrid = HybridRuntime.create(
        inference: inference,
        cloudRoutes: CloudRoutes.parse('hybridFallback'),
        cloudFallback: cloud,
        isOnline: () => true,
        cloudModel: 'test-cloud-model',
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: hybrid.navigatorKey, home: const SizedBox()),
      );
      return (hybrid: hybrid, inference: inference, cloud: cloud);
    }

    Future<DispatchResult> run(
      WidgetTester tester,
      HybridRuntime hybrid, {
      required String? tap,
      bool closeInstead = false,
    }) async {
      DispatchResult? result;
      unawaited(
        hybrid.dispatcher
            .start(task, sessionId: hybrid.sessionId)
            .result
            .then((r) => result = r),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('consent-dialog')), findsOneWidget);
      expect(find.text('Send this photo to Google if needed?'), findsOneWidget);
      if (closeInstead) {
        hybrid.navigatorKey.currentState!.pop();
      } else {
        await tester.tap(find.byKey(ValueKey(tap!)));
      }
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      return result!;
    }

    testWidgets('declining sends nothing and authorizes nothing later', (
      tester,
    ) async {
      final (:hybrid, :inference, :cloud) = await pumpRuntime(tester);

      final declined = await run(tester, hybrid, tap: 'consent-decline');
      expect(declined.ok, isFalse);
      expect(declined.blocked, RouteReason.consentDeclined);
      expect(cloud.sends, 0);
      expect(inference.requests, isEmpty);

      // The same payload again: the earlier decline is not remembered as a
      // yes, and it is not remembered as a standing no either. The cook is
      // asked again, and only this new "Send this once" sends.
      final allowed = await run(tester, hybrid, tap: 'consent-allow');
      expect(allowed.text, 'cloud answer');
      expect(cloud.sends, 1);

      // The grant was single-use: a third identical request asks again, and
      // declining it sends nothing more.
      final again = await run(tester, hybrid, tap: 'consent-decline');
      expect(again.ok, isFalse);
      expect(cloud.sends, 1);
      expect(inference.requests, isEmpty);
    });

    testWidgets('a cancelled dialog sends nothing and authorizes nothing', (
      tester,
    ) async {
      final (:hybrid, :inference, :cloud) = await pumpRuntime(tester);

      final cancelled = await run(
        tester,
        hybrid,
        tap: null,
        closeInstead: true,
      );
      expect(cancelled.ok, isFalse);
      expect(cloud.sends, 0);

      final declined = await run(tester, hybrid, tap: 'consent-decline');
      expect(declined.ok, isFalse);
      expect(cloud.sends, 0);
      expect(inference.requests, isEmpty);
    });
  });

  group('a real mixed-input pantry scan', () {
    // The task the pantry client really builds: the cook's typed list, the
    // items picked out of their voice note and their photo.
    HybridTask pantryTask() => buildPantryScanTask(
      typedText: 'two cans of chickpeas',
      spokenItems: const ['tomatoes', 'bread'],
      photoJpeg: Uint8List.fromList(const [1, 2, 3]),
      recipes: const [
        Recipe(
          id: 'wrap',
          version: 1,
          title: 'Chickpea wrap',
          summary: 'A wrap.',
          ingredients: [
            Ingredient(id: 'chickpeas', name: 'Chickpeas', qty: '1 can'),
          ],
          equipment: [],
          steps: [
            RecipeStep(
              id: 'mash',
              title: 'Mash',
              instruction: 'Mash.',
              cue: 'Done.',
            ),
          ],
          checkpoints: [],
          reviewedSubstitutions: [],
          adjustmentLabels: {},
        ),
      ],
    );

    Future<
      ({
        HybridRuntime hybrid,
        FakeHybridInference inference,
        _CountingCloud cloud,
      })
    >
    pump(WidgetTester tester, FakeHybridInference inference) async {
      final cloud = _CountingCloud();
      final hybrid = HybridRuntime.create(
        inference: inference,
        cloudRoutes: CloudRoutes.parse('hybridFallback'),
        cloudFallback: cloud,
        isOnline: () => true,
        cloudModel: 'test-cloud-model',
      );
      await tester.pumpWidget(
        MaterialApp(navigatorKey: hybrid.navigatorKey, home: const SizedBox()),
      );
      return (hybrid: hybrid, inference: inference, cloud: cloud);
    }

    testWidgets('the prompt names the typed list and the voice items', (
      tester,
    ) async {
      final task = pantryTask();
      // The text part really carries the cook's own words.
      final text = (task.parts.first as HybridText).text;
      expect(text, contains('"typedByCook":"two cans of chickpeas"'));
      expect(text, contains('"saidByCook":["tomatoes","bread"]'));

      final (:hybrid, :inference, :cloud) = await pump(
        tester,
        FakeHybridInference(
          capabilities: const HybridCapabilities.none(),
          imageAvailability: const HybridAvailability(
            status: OnDeviceStatus.unavailable,
          ),
        ),
      );
      DispatchResult? result;
      unawaited(
        hybrid.dispatcher
            .start(task, sessionId: hybrid.sessionId)
            .result
            .then((r) => result = r),
      );
      await tester.pumpAndSettle();
      expect(find.text('Send this photo to Google if needed?'), findsOneWidget);
      expect(
        find.textContaining(
          'sends this photo, with anything you typed, any items picked out '
          'from your voice note',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('consent-decline')));
      await tester.pumpAndSettle();
      expect(result?.blocked, RouteReason.consentDeclined);
      expect(cloud.sends, 0);
      expect(inference.requests, isEmpty);
    });

    testWidgets('a yes may still finish on the device: nothing is sent', (
      tester,
    ) async {
      // A capable device: the scan may upload (preferOnDevice), so it asks,
      // but the on-device model answers and nothing leaves.
      final inference = FakeHybridInference()
        ..enqueueText('{"items":[],"meals":[]}');
      final (:hybrid, inference: _, :cloud) = await pump(tester, inference);
      DispatchResult? result;
      unawaited(
        hybrid.dispatcher
            .start(pantryTask(), sessionId: hybrid.sessionId)
            .result
            .then((r) => result = r),
      );
      await tester.pumpAndSettle();
      final dialog = find.byKey(const ValueKey('consent-dialog'));
      expect(dialog, findsOneWidget);
      // The copy only says Google may receive it, if needed.
      expect(find.textContaining('if needed?'), findsOneWidget);
      expect(find.textContaining("this device can't answer"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('consent-allow')));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.legs.single.provenance, Provenance.sdkOnDevice);
      expect(cloud.sends, 0);
    });
  });

  testWidgets('the watch cloud check prompt, then a yes sends that photo', (
    tester,
  ) async {
    final inference = FakeHybridInference(
      capabilities: const HybridCapabilities.none(),
    );
    final cloud = _CountingCloud();
    final hybrid = HybridRuntime.create(
      inference: inference,
      cloudRoutes: CloudRoutes.parse('hybridFallback'),
      cloudFallback: cloud,
      isOnline: () => true,
      cloudModel: 'test-cloud-model',
    );
    await tester.pumpWidget(
      MaterialApp(navigatorKey: hybrid.navigatorKey, home: const SizedBox()),
    );
    DispatchResult? result;
    unawaited(
      hybrid.dispatcher
          .start(
            HybridTask(
              feature: 'local_watch_cloud_check',
              parts: [
                const HybridText('Step: simmer until thick.'),
                HybridInlineData(
                  Uint8List.fromList(const [9, 9]),
                  'image/jpeg',
                ),
              ],
              maxOutputTokens: 32,
              timeout: const Duration(seconds: 5),
            ),
            sessionId: hybrid.sessionId,
          )
          .result
          .then((r) => result = r),
    );
    await tester.pumpAndSettle();
    expect(find.text('Send this photo to Google?'), findsOneWidget);
    expect(
      find.textContaining('Watch my food wants a second look from Google.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('consent-allow')));
    await tester.pumpAndSettle();
    expect(result?.text, 'cloud answer');
    expect(cloud.sends, 1);
  });
}
