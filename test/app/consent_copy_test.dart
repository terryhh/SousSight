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
      ('coach_lite', {DataKind.text}, 'this question'),
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
      ('recipe_draft', {DataKind.text}, 'this pantry list'),
      ('pantry_scan', {DataKind.text}, 'this pantry list'),
      ('pantry_voice', {DataKind.text}, 'what you said'),
    ]) {
      test('$feature $kinds says "$subject"', () {
        final ask = _ask(feature, kinds);
        expect(consentSubject(ask), subject);
        final copy = consentCopy(ask);
        expect(copy.title, 'Send $subject to Google?');
        expect(copy.body, contains('sends $subject'));
        expect(copy.body, contains("to Google's servers to answer"));
        expect(copy.body, contains("SousSight doesn't save it."));
        expect(copy.body, contains('"Keep it on my phone", nothing is sent'));
        expect(copy.allow, 'Send this once');
        expect(copy.decline, 'Keep it on my phone');
      });
    }

    test('a photo with text mentions the written request; text alone not', () {
      expect(
        consentCopy(_ask('label_check', {DataKind.image, DataKind.text})).body,
        contains('sends this photo, with a short written request, to Google'),
      );
      expect(
        consentCopy(_ask('label_check', {DataKind.image})).body,
        contains('sends this photo to Google'),
      );
      expect(
        consentCopy(_ask('coach_lite', {DataKind.text})).body,
        isNot(contains('written request')),
      );
    });

    test('names the feature and uses no technical jargon', () {
      final copy = consentCopy(
        _ask('label_check', {DataKind.image, DataKind.text}),
      );
      expect(copy.body, startsWith('Label check needs help from Google.'));
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
      expect(find.text('Send this photo to Google?'), findsOneWidget);
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
      expect(find.text('Send this photo to Google?'), findsOneWidget);
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
}
