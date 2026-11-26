// Keeps the screen awake while a cooking session is active (SS-107): messy
// hands can't unlock a phone.
//
// [ScreenWakeLock] is the small seam the cooking screen uses. On web it is
// the Screen Wake Lock API ([BrowserWakeLock]); elsewhere it is the
// `wakelock_plus` plugin ([NativeScreenWakeLock]). Where neither works (an
// unsupported browser, an insecure context, a desktop without a plugin, a
// test without a platform channel) every call quietly does nothing.

export 'screen_wake_lock_native.dart'
    if (dart.library.js_interop) 'screen_wake_lock_web.dart'
    show createScreenWakeLock;

/// A screen wake lock that can be asked for and given back any number of
/// times, in any order. Neither call throws; the latest call wins.
abstract class ScreenWakeLock {
  /// Asks the platform to keep the screen on.
  Future<void> acquire();

  /// Lets the screen sleep again.
  Future<void> release();
}

/// Records what was asked for. For tests.
class FakeScreenWakeLock implements ScreenWakeLock {
  /// Every call, in order: `true` for [acquire], `false` for [release].
  final List<bool> calls = [];

  /// Whether the latest call was [acquire].
  bool get held => calls.isNotEmpty && calls.last;

  @override
  Future<void> acquire() async => calls.add(true);

  @override
  Future<void> release() async => calls.add(false);
}
