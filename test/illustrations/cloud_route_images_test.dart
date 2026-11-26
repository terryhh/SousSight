import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';

void main() {
  test('the images route parses and is off unless listed', () {
    expect(CloudRoute.values.map((r) => r.name), contains('images'));
    expect(CloudRoutes.parse('images').allows(CloudRoute.images), isTrue);
    expect(CloudRoutes.parse('hybridFallback, research , images').approved, {
      CloudRoute.hybridFallback,
      CloudRoute.research,
      CloudRoute.images,
    });
    // The current repo variable does not approve it.
    expect(
      CloudRoutes.parse('hybridFallback,research').allows(CloudRoute.images),
      isFalse,
    );
    expect(CloudRoutes.parse('').allows(CloudRoute.images), isFalse);
    expect(CloudRoutes.parse('Images').allows(CloudRoute.images), isFalse);
    expect(CloudRoutes.fromEnvironment().allows(CloudRoute.images), isFalse);
  });
}
