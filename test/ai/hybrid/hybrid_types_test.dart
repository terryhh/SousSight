import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';

void main() {
  test('CloudRoutes defaults to nothing and ignores unknown names', () {
    expect(CloudRoutes.parse('').approved, isEmpty);
    final routes = CloudRoutes.parse('hybridFallback, bogus,research');
    expect(routes.allows(CloudRoute.hybridFallback), isTrue);
    expect(routes.allows(CloudRoute.research), isTrue);
    expect(routes.allows(CloudRoute.live), isFalse);
  });

  test('FakeHybridDispatcher returns scripted results and honours cancel', () async {
    const task = HybridTask(
      feature: 'coach_lite',
      parts: [HybridText('q')],
      maxOutputTokens: 64,
      timeout: Duration(seconds: 5),
    );
    final fake = FakeHybridDispatcher()..enqueue('answer');
    final ok = await fake.start(task, sessionId: 's').result;
    expect(ok.text, 'answer');
    expect(ok.finalLeg!.provenance, Provenance.sdkOnDevice);

    fake
      ..delay = const Duration(milliseconds: 10)
      ..enqueue('late');
    final op = fake.start(task, sessionId: 's')..cancel();
    final cancelled = await op.result;
    expect(cancelled.blocked, RouteReason.cancelled);
    expect(fake.cancelledOperations, [op.operationId]);
  });

  test('concurrent fake operations get distinct leg request ids', () async {
    const task = HybridTask(
      feature: 'local_watch',
      parts: [HybridText('q')],
      maxOutputTokens: 8,
      timeout: Duration(seconds: 1),
    );
    final fake = FakeHybridDispatcher()
      ..enqueue('a')
      ..enqueue('b')
      ..delay = const Duration(milliseconds: 10);
    final first = fake.start(task, sessionId: 's');
    final second = fake.start(task, sessionId: 's');
    final ids = [
      (await first.result).finalLeg!.requestId,
      (await second.result).finalLeg!.requestId,
    ];
    expect(ids.toSet(), hasLength(2));
  });
}
