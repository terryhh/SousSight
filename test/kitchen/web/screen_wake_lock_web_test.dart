// Runs only in a browser:
//   flutter test --platform chrome test/kitchen/web
// Headless Chrome may grant or refuse the lock (hidden page, no user
// activation); either way the calls must complete without throwing.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/kitchen/browser_wake_lock.dart';
import 'package:soussight/kitchen/screen_wake_lock.dart';

void main() {
  test('the web build uses the Screen Wake Lock API, silently', () async {
    final lock = createScreenWakeLock();
    expect(lock, isA<BrowserWakeLock>());
    await lock.acquire();
    await lock.acquire();
    await lock.release();
    expect((lock as BrowserWakeLock).held, isFalse);
    await lock.release();
  });
}
