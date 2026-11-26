import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/kitchen/native_wake_lock.dart';
import 'package:soussight/kitchen/screen_wake_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('applies calls one at a time, in order', () async {
    final applied = <bool>[];
    final gate = Completer<void>();
    final lock = NativeScreenWakeLock((enable) async {
      if (enable) await gate.future;
      applied.add(enable);
    });
    final acquiring = lock.acquire();
    final releasing = lock.release();
    await pumpEventQueue();
    expect(applied, isEmpty, reason: 'release waits for the slow acquire');
    gate.complete();
    await Future.wait([acquiring, releasing]);
    expect(applied, [true, false]);
  });

  test(
    'platform errors degrade silently and do not block later calls',
    () async {
      final applied = <bool>[];
      final lock = NativeScreenWakeLock((enable) async {
        if (enable) throw StateError('no plugin');
        applied.add(enable);
      });
      await lock.acquire();
      await lock.release();
      expect(applied, [false]);
    },
  );

  test('the plugin without a platform channel does not throw', () async {
    final lock = createScreenWakeLock();
    expect(lock, isA<NativeScreenWakeLock>());
    await lock.acquire();
    await lock.release();
  });

  test('the fake records the order of calls', () async {
    final fake = FakeScreenWakeLock();
    expect(fake.held, isFalse);
    await fake.acquire();
    expect(fake.held, isTrue);
    await fake.release();
    expect(fake.calls, [true, false]);
    expect(fake.held, isFalse);
  });
}
