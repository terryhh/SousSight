// The web wake lock's bookkeeping, kept free of `package:web` so the VM tests
// can drive it. The Screen Wake Lock API releases a lock by itself whenever
// the page is hidden, so while the cook still wants one we request it again
// each time the page becomes visible.

import 'dart:async';

import 'screen_wake_lock.dart';

/// The parts of the browser the web wake lock needs.
abstract class BrowserWakeLockApi {
  /// `navigator.wakeLock` exists and the page is a secure context.
  bool get supported;

  /// `document.visibilityState == 'visible'`. Requests from a hidden page
  /// are rejected, so none is made.
  bool get visible;

  /// Fires on each `visibilitychange` of the document.
  Stream<void> get visibilityChanges;

  /// `navigator.wakeLock.request('screen')`.
  Future<BrowserWakeLockHandle> request();
}

/// A granted `WakeLockSentinel`.
abstract class BrowserWakeLockHandle {
  /// True once the browser or [release] gave the lock back.
  bool get released;

  Future<void> release();
}

/// [ScreenWakeLock] over the Screen Wake Lock API. Unsupported browsers,
/// refused requests (battery saver, permissions policy) and hidden pages
/// leave the screen on its normal timeout without an error.
class BrowserWakeLock implements ScreenWakeLock {
  BrowserWakeLock(this._api);

  final BrowserWakeLockApi _api;

  bool _wanted = false;

  /// Bumped by [release]; a request that resolves under an older epoch is
  /// no longer wanted and is given straight back.
  int _epoch = 0;
  BrowserWakeLockHandle? _handle;
  Future<BrowserWakeLockHandle>? _pending;
  StreamSubscription<void>? _visibility;

  /// Whether a granted lock is held right now.
  bool get held => _handle != null && !_handle!.released;

  @override
  Future<void> acquire() async {
    _wanted = true;
    if (!_safe(() => _api.supported)) return;
    _visibility ??= _api.visibilityChanges.listen((_) {
      if (_wanted && _safe(() => _api.visible)) unawaited(_request());
    });
    await _request();
  }

  Future<void> _request() async {
    if (!_wanted || held || _pending != null) return;
    if (!_safe(() => _api.visible)) return;
    final epoch = _epoch;
    final pending = _pending = Future.sync(_api.request);
    try {
      final handle = await pending;
      if (epoch != _epoch || !_wanted) {
        await _quietRelease(handle);
        return;
      }
      _handle = handle;
    } catch (_) {
      // Refused or unsupported: degrade silently.
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  @override
  Future<void> release() async {
    _wanted = false;
    _epoch++;
    _pending = null;
    final visibility = _visibility;
    _visibility = null;
    final handle = _handle;
    _handle = null;
    await visibility?.cancel();
    if (handle != null) await _quietRelease(handle);
  }

  static Future<void> _quietRelease(BrowserWakeLockHandle handle) async {
    try {
      if (!handle.released) await handle.release();
    } catch (_) {
      // Already gone.
    }
  }

  static bool _safe(bool Function() read) {
    try {
      return read();
    } catch (_) {
      return false;
    }
  }
}
