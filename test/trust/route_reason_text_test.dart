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

  test('plain words: no "cloud", "model" or product names (SS-089)', () {
    for (final text in routeReasonText.values) {
      expect(
        text,
        isNot(matches(RegExp(r'\bcloud\b|\bmodel\b|Gemini|Firebase'))),
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
      "Voice clips have to be sent online to Google's AI; your photo stayed "
      'here.',
    );
    expect(
      routeReasonSentence(RouteReason.cloudNotApproved),
      'Sending online is off in this build.',
    );
  });
}
