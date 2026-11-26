import 'native_wake_lock.dart';
import 'screen_wake_lock.dart';

/// The wake lock for this platform: `wakelock_plus` off the web.
ScreenWakeLock createScreenWakeLock() => NativeScreenWakeLock();
