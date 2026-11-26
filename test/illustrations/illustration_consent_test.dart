import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/consent_copy.dart';
import 'package:soussight/illustrations/illustration_consent.dart';
import 'package:soussight/illustrations/illustration_prompts.dart';

const _ask = ConsentAsk(
  feature: kIllustrationFeature,
  kinds: {DataKind.text},
  payloadDigest: 'd',
  sessionId: 's',
);

void main() {
  test('the copy says plainly that a yes sends text to Google', () {
    final copy = illustrationConsentCopy(model: 'gemini-nano-banana-2.1');
    expect(copy.title, contains('Google'));
    expect(copy.body, contains('this device cannot make one'));
    expect(copy.body, contains('gemini-nano-banana-2.1'));
    expect(copy.body, contains('No photo, voice or location is sent'));
    expect(copy.body, contains(kConsentDeclineLabel));
    expect(copy.body, isNot(contains("can't answer by itself")));
  });

  Future<Future<ConsentGrant?>> open(
    WidgetTester tester,
    GlobalKey<NavigatorState> key,
  ) async {
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Scaffold()),
    );
    final gate = IllustrationConsentGate(navigatorKey: key, model: 'm');
    final result = gate.request(_ask);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('consent-dialog')), findsOneWidget);
    return result;
  }

  testWidgets('"Send this once" grants exactly this ask', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final result = await open(tester, key);
    await tester.tap(find.text(kConsentAllowLabel));
    await tester.pumpAndSettle();
    final grant = await result;
    expect(grant, isNotNull);
    expect(identical(grant!.ask, _ask), isTrue);
  });

  testWidgets('"Keep it on my phone" declines', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final result = await open(tester, key);
    await tester.tap(find.text(kConsentDeclineLabel));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  test('no screen to show it on is a decline', () async {
    final gate = IllustrationConsentGate(
      navigatorKey: GlobalKey<NavigatorState>(),
      model: 'm',
    );
    expect(await gate.request(_ask), isNull);
  });
}
