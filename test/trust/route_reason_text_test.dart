import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/trust/route_reason_text.dart';

void main() {
  test('every RouteReason has one short cook-facing sentence', () {
    for (final reason in RouteReason.values) {
      final text = routeReasonText[reason];
      expect(text, isNotNull, reason: '${reason.name} has no sentence');
      expect(text!.length, lessThanOrEqualTo(100), reason: reason.name);
      expect(text.endsWith('.'), isTrue, reason: reason.name);
    }
  });

  test('sentences never claim safety or doneness', () {
    for (final text in routeReasonText.values) {
      expect(
        text.toLowerCase(),
        isNot(matches(RegExp(r'\b(safe|done|cooked through|temperature)\b'))),
      );
    }
  });

  test('the agreed wording is kept', () {
    expect(
      routeReasonSentence(RouteReason.onDevice),
      'Ran on this device — nothing left it.',
    );
    expect(
      routeReasonSentence(RouteReason.audioNeedsCloud),
      'Voice clips need the cloud; your photo stayed here.',
    );
    expect(
      routeReasonSentence(RouteReason.cloudNotApproved),
      'Cloud help is off in this build.',
    );
  });
}
