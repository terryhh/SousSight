import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/kitchen/kitchen_mode.dart';
import 'package:soussight/kitchen/kitchen_preferences.dart';
import 'package:soussight/kitchen/screen_wake_lock.dart';
import 'package:soussight/kitchen/shared_wake_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the platform lock is on while any lease holds it', () async {
    final platform = FakeScreenWakeLock();
    final shared = SharedScreenWakeLock(platform);
    final a = shared.lease();
    final b = shared.lease();
    await a.acquire();
    await a.acquire(); // counted once
    await b.acquire();
    expect(platform.calls, [true]);
    expect(shared.holders, 2);
    await a.release();
    await a.release(); // counted once
    expect(platform.calls, [true]);
    expect(shared.holders, 1);
    await b.release();
    expect(platform.calls, [true, false]);
    expect(shared.holders, 0);
    await b.release();
    expect(platform.calls, [true, false]);
  });

  test('disposing a replaced session keeps the new session\'s lock', () {
    final platform = FakeScreenWakeLock();
    final shared = SharedScreenWakeLock(platform);
    KitchenMode mode() => KitchenMode(
      wakeLock: shared.lease(),
      preferences: InMemoryKitchenPreferences(),
      observeLifecycle: false,
    );
    // "New cook": the new screen starts before the old one is disposed.
    final old = mode()..setSessionActive(true);
    final replacement = mode()..setSessionActive(true);
    old.dispose();
    expect(platform.calls, [true]);
    expect(platform.held, isTrue);
    replacement.dispose();
    expect(platform.calls, [true, false]);
  });

  test('the app owner leases this platform\'s lock without channels', () async {
    final lease = appScreenWakeLock.lease();
    await lease.acquire();
    expect(appScreenWakeLock.holders, 1);
    await lease.release();
    expect(appScreenWakeLock.holders, 0);
  });
}
