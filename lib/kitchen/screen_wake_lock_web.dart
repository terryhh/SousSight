// The Screen Wake Lock API through `dart:js_interop` (`package:web`).
// https://developer.mozilla.org/docs/Web/API/Screen_Wake_Lock_API

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'browser_wake_lock.dart';
import 'screen_wake_lock.dart';

/// The wake lock for this platform: the browser's Screen Wake Lock API.
ScreenWakeLock createScreenWakeLock() => BrowserWakeLock(_WebWakeLockApi());

class _WebWakeLockApi implements BrowserWakeLockApi {
  @override
  bool get supported =>
      web.window.isSecureContext && web.window.navigator.has('wakeLock');

  @override
  bool get visible => web.document.visibilityState == 'visible';

  @override
  Stream<void> get visibilityChanges =>
      const web.EventStreamProvider<web.Event>('visibilitychange')
          .forTarget(web.document);

  @override
  Future<BrowserWakeLockHandle> request() async =>
      _Sentinel(await web.window.navigator.wakeLock.request('screen').toDart);
}

class _Sentinel implements BrowserWakeLockHandle {
  _Sentinel(this._sentinel);

  final web.WakeLockSentinel _sentinel;

  @override
  bool get released => _sentinel.released;

  @override
  Future<void> release() => _sentinel.release().toDart;
}
