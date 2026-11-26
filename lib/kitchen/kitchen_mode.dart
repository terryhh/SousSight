// Kitchen mode for a cooking session (SS-107): the screen stays on while the
// cook is cooking, and "Big text" enlarges the cooking space for reading from
// across the counter.

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'kitchen_preferences.dart';
import 'screen_wake_lock.dart';

/// Holds the screen wake lock while a cooking session is active and the app
/// is in the foreground, and the per-device "Big text" choice.
///
/// The lock is released when the session ends, when the app is hidden or
/// paused, and on [dispose]; it is taken again when the app comes back while
/// the session is still active.
class KitchenMode extends ChangeNotifier {
  KitchenMode({
    required ScreenWakeLock wakeLock,
    required KitchenPreferences preferences,
    bool observeLifecycle = true,
  }) : _lock = wakeLock,
       _prefs = preferences {
    if (observeLifecycle) {
      _foreground = _isForeground(WidgetsBinding.instance.lifecycleState);
      _lifecycle = AppLifecycleListener(
        onStateChange: (state) => setForeground(_isForeground(state)),
      );
    }
  }

  /// This device's wake lock and preferences.
  factory KitchenMode.device() => KitchenMode(
    wakeLock: createScreenWakeLock(),
    preferences: DeviceKitchenPreferences(),
  );

  final ScreenWakeLock _lock;
  final KitchenPreferences _prefs;
  AppLifecycleListener? _lifecycle;

  bool _bigText = false;
  bool _chosen = false;
  bool _sessionActive = false;
  bool _foreground = true;
  bool _lockWanted = false;
  bool _disposed = false;

  /// Saves in order. Created on first use, in the caller's zone.
  Future<void>? _writes;

  Listenable? _session;
  bool Function()? _sessionIsActive;

  /// Whether "Big text" is on.
  bool get bigText => _bigText;

  /// Whether the wake lock has been asked for (the platform may still
  /// decline it; see [ScreenWakeLock]).
  bool get keepsScreenOn => _lockWanted;

  static bool _isForeground(AppLifecycleState? state) => switch (state) {
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => false,
    _ => true,
  };

  /// Reads the saved "Big text" choice. A choice the cook makes before the
  /// read finishes wins; unreadable storage leaves it off.
  Future<void> load() async {
    bool? saved;
    try {
      saved = await _prefs.readBigText();
    } catch (_) {
      return;
    }
    if (_disposed || _chosen || saved == null || saved == _bigText) return;
    _bigText = saved;
    notifyListeners();
  }

  /// Turns "Big text" on or off and saves it on this device. If saving
  /// fails the choice still applies until the app closes.
  Future<void> setBigText(bool value) {
    if (_disposed) return Future.value();
    _chosen = true;
    if (value == _bigText) return _writes ?? Future.value();
    _bigText = value;
    notifyListeners();
    return _writes = (_writes ?? Future.value()).then((_) async {
      try {
        await _prefs.writeBigText(value);
      } catch (_) {
        // Storage unavailable (private browsing, full disk).
      }
    });
  }

  /// Follows [source]: the session is active whenever [isActive] says so.
  /// Replaces any session followed before.
  void followSession(Listenable source, bool Function() isActive) {
    if (_disposed) return;
    _session?.removeListener(_onSession);
    _session = source;
    _sessionIsActive = isActive;
    source.addListener(_onSession);
    _onSession();
  }

  void _onSession() => setSessionActive(_sessionIsActive!());

  void setSessionActive(bool active) {
    _sessionActive = active;
    _syncLock();
  }

  /// Hidden, paused and detached are background; anything else foreground.
  void setForeground(bool foreground) {
    _foreground = foreground;
    _syncLock();
  }

  void _syncLock() {
    final want = !_disposed && _sessionActive && _foreground;
    if (want == _lockWanted) return;
    _lockWanted = want;
    unawaited((want ? _lock.acquire() : _lock.release()).catchError((_) {}));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session?.removeListener(_onSession);
    _session = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _syncLock();
    super.dispose();
  }
}

/// Supplies how cooking screens below it create their [KitchenMode]. Without
/// one, [KitchenMode.device] is used. Tests put fakes here.
class KitchenModeScope extends InheritedWidget {
  const KitchenModeScope({
    super.key,
    required this.create,
    required super.child,
  });

  final KitchenMode Function() create;

  /// A new [KitchenMode] for a cooking screen at [context]. Safe to call
  /// from `initState`.
  static KitchenMode createFor(BuildContext context) =>
      (context.getInheritedWidgetOfExactType<KitchenModeScope>()?.create ??
      KitchenMode.device)();

  @override
  bool updateShouldNotify(KitchenModeScope oldWidget) => false;
}
