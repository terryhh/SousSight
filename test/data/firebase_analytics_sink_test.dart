import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/data/firebase_analytics_sink.dart';

enum _Failure { none, async, sync }

class _FakeAnalytics implements FirebaseAnalytics {
  _FakeAnalytics([this.failure = _Failure.none]);
  final _Failure failure;
  final calls = <String>[];
  final parameters = <Map<String, Object>?>[];

  Future<void> _answer() {
    switch (failure) {
      case _Failure.none:
        return Future.value();
      case _Failure.async:
        return Future.error(StateError('gtag blocked'));
      case _Failure.sync:
        throw StateError('not initialized');
    }
  }

  @override
  Future<void> setAnalyticsCollectionEnabled(bool enabled) {
    calls.add('enabled:$enabled');
    return _answer();
  }

  @override
  Future<void> logEvent({
    required String name,
    Map<String, Object>? parameters,
    List<AnalyticsEventItem>? items,
    AnalyticsCallOptions? callOptions,
  }) {
    calls.add('event:$name');
    this.parameters.add(parameters);
    return _answer();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('start enables collection so page_view is recorded on load', () {
    final analytics = _FakeAnalytics();
    FirebaseAnalyticsSink(analytics).start();
    expect(analytics.calls, ['enabled:true']);
  });

  test('events pass their parameters; an empty map is sent as none', () {
    final analytics = _FakeAnalytics();
    FirebaseAnalyticsSink(analytics)
      ..log('step_completed', {'step': 2})
      ..log('session_started');
    expect(analytics.calls, ['event:step_completed', 'event:session_started']);
    expect(analytics.parameters, [
      {'step': 2},
      null,
    ]);
  });

  for (final failure in [_Failure.async, _Failure.sync]) {
    test(
      'a ${failure.name} analytics failure never reaches the cook',
      () async {
        final analytics = _FakeAnalytics(failure);
        final sink = FirebaseAnalyticsSink(analytics);
        // Neither call may throw, and no unhandled async error may escape the
        // test zone (which would fail this test).
        sink.start();
        sink.log('timer_started', {'minutes': 3});
        await pumpEventQueue();
        expect(analytics.calls, ['enabled:true', 'event:timer_started']);
      },
    );
  }
}
