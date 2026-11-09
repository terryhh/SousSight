import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/analytics.dart';
import 'package:soussight/data/dinner_messages.dart';
import 'package:soussight/learner/cooking_app.dart';

void main() {
  const request = DinnerMessageRequest(
    sessionId: 's1',
    notificationId: 'n1',
    recipient: '+15555550100',
    kind: DinnerKind.ready,
    recipeTitle: 'Chickpea wrap',
  );

  test('only a submitted (Vonage-accepted) send is counted', () {
    final analytics = RecordingAnalytics();
    for (final status in ['failed', 'skipped', 'unknown', 'rejected']) {
      trackHouseholdSend(analytics, request, DinnerMessageResult(status, 'sms'));
    }
    expect(analytics.events, isEmpty);

    trackHouseholdSend(
      analytics,
      request,
      const DinnerMessageResult('submitted', 'sms', simulated: true),
    );
    expect(analytics.names, [AnalyticsEvents.householdMessageSent]);
    expect(analytics.events.single.parameters, {'kind': 'ready', 'simulated': 1});
  });
}
