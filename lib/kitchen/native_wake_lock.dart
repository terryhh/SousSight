// Android, iOS and desktop: the `wakelock_plus` plugin (BSD-3-Clause,
// Flutter Community). On Android it sets FLAG_KEEP_SCREEN_ON on the window and
// on iOS `isIdleTimerDisabled`; neither needs a permission.

import 'package:wakelock_plus/wakelock_plus.dart';

import 'screen_wake_lock.dart';

/// Turns the platform wake lock on or off.
typedef WakelockToggle = Future<void> Function(bool enable);

Future<void> _pluginToggle(bool enable) => WakelockPlus.toggle(enable: enable);

/// [ScreenWakeLock] over a [WakelockToggle] (the plugin by default). Calls are
/// applied one at a time in the order made, so a quick acquire then release
/// always ends released. A platform error (no plugin, no channel) is
/// swallowed: the screen simply follows its normal timeout.
class NativeScreenWakeLock implements ScreenWakeLock {
  NativeScreenWakeLock([this._toggle = _pluginToggle]);

  final WakelockToggle _toggle;
  Future<void> _queue = Future.value();

  @override
  Future<void> acquire() => _apply(true);

  @override
  Future<void> release() => _apply(false);

  Future<void> _apply(bool enable) => _queue = _queue.then((_) async {
    try {
      await _toggle(enable);
    } catch (_) {
      // Unsupported here: degrade silently.
    }
  });
}
