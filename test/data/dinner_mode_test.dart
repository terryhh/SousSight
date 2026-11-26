import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/analytics.dart';
import 'package:soussight/data/dinner_messages.dart';
import 'package:soussight/data/dinner_mode.dart';
import 'package:soussight/data/dinner_status.dart';
import 'package:soussight/learner/cooking_app.dart';

void main() {
  const request = DinnerMessageRequest(
    sessionId: 's1',
    notificationId: 'n1',
    recipient: '+15555550100',
    kind: DinnerKind.started,
    recipeTitle: 'Chickpea wrap',
    minutes: 20,
    cookName: 'Ana',
  );

  Never realSender(DinnerMessageRequest _) =>
      fail('simulated mode must never call the real dinner endpoint');
  Never realStatus() =>
      fail('simulated mode must never build the Firestore status source');

  test('missing or real DINNER_MODE keeps the real path', () {
    // Test runs pass no define, so the build constant is the default.
    expect(configuredDinnerMode, DinnerMode.real);
    expect(parseDinnerMode(null), DinnerMode.real);
    expect(parseDinnerMode(''), DinnerMode.real);
    expect(parseDinnerMode('real'), DinnerMode.real);
  });

  test('simulated and unknown values fail safe to simulated', () {
    expect(parseDinnerMode('simulated'), DinnerMode.simulated);
    expect(parseDinnerMode(' simulated '), DinnerMode.simulated);
    expect(parseDinnerMode('simulate'), DinnerMode.simulated);
    expect(isKnownDinnerMode('simulated'), isTrue);
    expect(isKnownDinnerMode('real'), isTrue);
    expect(isKnownDinnerMode(''), isTrue);
    expect(isKnownDinnerMode('simulate'), isFalse);
  });

  test('simulated sender uses the fake, a fictional recipient and a labelled '
      'delivery even when FAKE_BACKEND is off', () async {
    final fake = FakeDinnerBackend();
    addTearDown(fake.dispose);
    final send = dinnerSenderFor(
      DinnerMode.simulated,
      isDemo: false,
      fake: fake,
      real: realSender,
    );
    final statusSource = dinnerStatusFor(
      DinnerMode.simulated,
      isDemo: false,
      fake: fake,
      real: realStatus,
    );
    expect(statusSource, same(fake));

    final result = await send(request);
    expect(result.simulated, isTrue);
    expect(result.status, 'submitted');
    expect(result.deliveryStatus, 'delivered');

    final sent = fake.sent.single;
    expect(sent.recipient, simulatedDinnerRecipient);
    expect(sent.simulate, DinnerSimulation.delivered);
    expect(sent.minutes, 20);
    expect(sent.cookName, 'Ana');
    expect(sent.preview, request.preview);

    final status = await statusSource.watch('s1', 'n1').first;
    expect(status!.simulated, isTrue);
    expect(status.label, '$simulatedLabel Delivered ✓');
  });

  test('simulated sender keeps an explicit simulated failure', () async {
    final fake = FakeDinnerBackend();
    addTearDown(fake.dispose);
    final send = dinnerSenderFor(
      DinnerMode.simulated,
      isDemo: false,
      fake: fake,
      real: realSender,
    );
    await send(
      DinnerMessageRequest(
        sessionId: 's1',
        notificationId: 'n2',
        recipient: '',
        kind: DinnerKind.ready,
        recipeTitle: 'Chickpea wrap',
        simulate: DinnerSimulation.rejected,
      ),
    );
    final status = await fake.watch('s1', 'n2').first;
    expect(status!.isFailure, isTrue);
    expect(status.label, startsWith(simulatedLabel));
  });

  test('real mode keeps the existing demo/real selection', () async {
    final fake = FakeDinnerBackend();
    addTearDown(fake.dispose);
    final calls = <DinnerMessageRequest>[];
    Future<DinnerMessageResult> real(DinnerMessageRequest r) async {
      calls.add(r);
      return const DinnerMessageResult('submitted', 'sms');
    }

    final firestoreStand = FakeDinnerBackend();
    addTearDown(firestoreStand.dispose);

    final live = dinnerSenderFor(
      DinnerMode.real,
      isDemo: false,
      fake: fake,
      real: real,
    );
    await live(request);
    expect(calls.single.recipient, '+15555550100');
    expect(calls.single.simulate, isNull);
    expect(fake.sent, isEmpty);
    expect(
      dinnerStatusFor(
        DinnerMode.real,
        isDemo: false,
        fake: fake,
        real: () => firestoreStand,
      ),
      same(firestoreStand),
    );

    final rehearsal = dinnerSenderFor(
      DinnerMode.real,
      isDemo: true,
      fake: fake,
      real: real,
    );
    final result = await rehearsal(request);
    expect(result.status, 'skipped');
    expect(calls, hasLength(1));
    expect(
      dinnerStatusFor(
        DinnerMode.real,
        isDemo: true,
        fake: fake,
        real: realStatus,
      ),
      same(fake),
    );
  });

  test('simulated sends are never counted in analytics', () async {
    final fake = FakeDinnerBackend();
    addTearDown(fake.dispose);
    final send = dinnerSenderFor(
      DinnerMode.simulated,
      isDemo: false,
      fake: fake,
      real: realSender,
    );
    final result = await send(request);
    // trackHouseholdSend alone would count this 'submitted' result, so the
    // mode guard is what keeps simulated sends out of the metric.
    final unguarded = RecordingAnalytics();
    trackHouseholdSend(unguarded, request, result);
    expect(unguarded.events, hasLength(1));

    final analytics = RecordingAnalytics();
    if (dinnerAnalyticsEnabled(DinnerMode.simulated, isDemo: false)) {
      trackHouseholdSend(analytics, request, result);
    }
    expect(analytics.events, isEmpty);

    expect(dinnerAnalyticsEnabled(DinnerMode.simulated, isDemo: true), isFalse);
    expect(dinnerAnalyticsEnabled(DinnerMode.real, isDemo: true), isFalse);
    expect(dinnerAnalyticsEnabled(DinnerMode.real, isDemo: false), isTrue);
  });
}
