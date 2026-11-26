import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/kitchen/browser_wake_lock.dart';

class _Handle implements BrowserWakeLockHandle {
  _Handle({this.failRelease = false});
  final bool failRelease;
  int releases = 0;
  @override
  bool released = false;
  @override
  Future<void> release() async {
    releases++;
    if (failRelease) throw StateError('gone');
    released = true;
  }
}

class _Api implements BrowserWakeLockApi {
  _Api({this.isSupported = true, this.isVisible = true});
  bool isSupported;
  bool isVisible;
  bool supportedThrows = false;
  bool requestThrowsSync = false;
  final visibility = StreamController<void>.broadcast();
  final requests = <Completer<BrowserWakeLockHandle>>[];

  /// Grant each request straight away with a new handle.
  bool autoGrant = true;
  final granted = <_Handle>[];

  @override
  bool get supported {
    if (supportedThrows) throw StateError('no navigator');
    return isSupported;
  }

  @override
  bool get visible => isVisible;

  @override
  Stream<void> get visibilityChanges => visibility.stream;

  @override
  Future<BrowserWakeLockHandle> request() {
    if (requestThrowsSync) throw StateError('NotAllowedError');
    final completer = Completer<BrowserWakeLockHandle>();
    requests.add(completer);
    if (autoGrant) grant(completer);
    return completer.future;
  }

  void grant(Completer<BrowserWakeLockHandle> completer, {_Handle? handle}) {
    final h = handle ?? _Handle();
    granted.add(h);
    completer.complete(h);
  }

  Future<void> setVisible(bool value) async {
    isVisible = value;
    visibility.add(null);
    await pumpEventQueue();
  }
}

void main() {
  test('acquire on a visible page requests one screen lock', () async {
    final api = _Api();
    final lock = BrowserWakeLock(api);
    await lock.acquire();
    await lock.acquire();
    expect(api.requests, hasLength(1));
    expect(lock.held, isTrue);
  });

  test('unsupported browsers degrade silently', () async {
    final api = _Api(isSupported: false);
    final lock = BrowserWakeLock(api);
    await lock.acquire();
    await api.setVisible(true);
    expect(api.requests, isEmpty);
    expect(lock.held, isFalse);
    await lock.release();
  });

  test('a throwing feature check counts as unsupported', () async {
    final api = _Api()..supportedThrows = true;
    final lock = BrowserWakeLock(api);
    await lock.acquire();
    expect(api.requests, isEmpty);
  });

  test('a hidden page waits until it is visible again', () async {
    final api = _Api(isVisible: false);
    final lock = BrowserWakeLock(api);
    await lock.acquire();
    expect(api.requests, isEmpty);
    await api.setVisible(true);
    expect(api.requests, hasLength(1));
    expect(lock.held, isTrue);
  });

  test('re-acquires after the browser released it on hide', () async {
    final api = _Api();
    final lock = BrowserWakeLock(api);
    await lock.acquire();
    // The browser gives the lock back whenever the page is hidden.
    api.granted.single.released = true;
    await api.setVisible(false);
    expect(api.requests, hasLength(1), reason: 'never requested while hidden');
    await api.setVisible(true);
    expect(api.requests, hasLength(2));
    expect(lock.held, isTrue);
  });

  test('a visible event while still held does not request again', () async {
    final api = _Api();
    final lock = BrowserWakeLock(api);
    await lock.acquire();
    await api.setVisible(true);
    expect(api.requests, hasLength(1));
  });

  test('release gives the lock back and stops following visibility', () async {
    final api = _Api();
    final lock = BrowserWakeLock(api);
    await lock.acquire();
    await lock.release();
    expect(api.granted.single.released, isTrue);
    expect(lock.held, isFalse);
    expect(api.visibility.hasListener, isFalse);
    await api.setVisible(true);
    expect(api.requests, hasLength(1));
  });

  test('a lock granted after release is given straight back', () async {
    final api = _Api()..autoGrant = false;
    final lock = BrowserWakeLock(api);
    final acquiring = lock.acquire();
    await lock.release();
    api.grant(api.requests.single);
    await acquiring;
    expect(api.granted.single.released, isTrue);
    expect(lock.held, isFalse);
  });

  test(
    'release then acquire during a slow request keeps only the new lock',
    () async {
      final api = _Api()..autoGrant = false;
      final lock = BrowserWakeLock(api);
      final first = lock.acquire();
      await lock.release();
      final second = lock.acquire();
      expect(api.requests, hasLength(2));
      // The new request resolves first, then the stale one.
      api.grant(api.requests[1]);
      await second;
      api.grant(api.requests[0]);
      await first;
      expect(api.granted[0].released, isFalse, reason: 'the new lock');
      expect(api.granted[1].released, isTrue, reason: 'the stale one');
      expect(lock.held, isTrue);
    },
  );

  test('a refused request is swallowed and retried on the next show', () async {
    final api = _Api()..autoGrant = false;
    final lock = BrowserWakeLock(api);
    final acquiring = lock.acquire();
    api.requests.single.completeError(StateError('NotAllowedError'));
    await acquiring;
    expect(lock.held, isFalse);
    api.autoGrant = true;
    await api.setVisible(true);
    expect(api.requests, hasLength(2));
    expect(lock.held, isTrue);
  });

  test('a request that throws synchronously is swallowed', () async {
    final api = _Api()..requestThrowsSync = true;
    final lock = BrowserWakeLock(api);
    await lock.acquire();
    expect(lock.held, isFalse);
  });

  test('a failing sentinel release is swallowed', () async {
    final api = _Api()..autoGrant = false;
    final lock = BrowserWakeLock(api);
    await Future.wait([
      lock.acquire(),
      Future(
        () =>
            api.grant(api.requests.single, handle: _Handle(failRelease: true)),
      ),
    ]);
    await lock.release();
    expect(api.granted.single.releases, 1);
  });

  test('release without a lock is harmless', () async {
    final lock = BrowserWakeLock(_Api());
    await lock.release();
    expect(lock.held, isFalse);
  });
}
