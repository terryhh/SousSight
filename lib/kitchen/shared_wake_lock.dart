// One owner for the device's screen wake lock (SS-107, Codex #245).
//
// The platform lock is a single switch for the whole app (Android's
// FLAG_KEEP_SCREEN_ON, iOS's idle timer). When "New cook" replaces the
// cooking screen, the new screen asks for the lock before the old one is
// disposed; if each screen drove the switch directly, the old screen's
// release would turn it off under the new session. Screens therefore take a
// [lease] from one [SharedScreenWakeLock]: the platform lock is on while any
// lease holds it.

import 'screen_wake_lock.dart';

/// Reference-counts [ScreenWakeLock] leases over one platform lock.
class SharedScreenWakeLock {
  SharedScreenWakeLock(this._platform);

  final ScreenWakeLock _platform;
  int _holders = 0;

  /// How many leases hold the lock now.
  int get holders => _holders;

  /// A new lease: its own acquire/release, counted once each way.
  ScreenWakeLock lease() => _Lease(this);

  Future<void> _add() =>
      _holders++ == 0 ? _platform.acquire() : Future<void>.value();

  Future<void> _remove() =>
      --_holders == 0 ? _platform.release() : Future<void>.value();
}

class _Lease implements ScreenWakeLock {
  _Lease(this._owner);

  final SharedScreenWakeLock _owner;
  bool _held = false;

  @override
  Future<void> acquire() {
    if (_held) return Future<void>.value();
    _held = true;
    return _owner._add();
  }

  @override
  Future<void> release() {
    if (!_held) return Future<void>.value();
    _held = false;
    return _owner._remove();
  }
}

/// The app's one owner of this device's wake lock, created on first use.
final SharedScreenWakeLock appScreenWakeLock = SharedScreenWakeLock(
  createScreenWakeLock(),
);
