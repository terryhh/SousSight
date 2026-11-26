import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soussight/kitchen/kitchen_mode.dart';
import 'package:soussight/kitchen/kitchen_preferences.dart';
import 'package:soussight/kitchen/screen_wake_lock.dart';

/// A session stand-in: notifies when [active] changes.
class _Session extends ChangeNotifier {
  bool _active = false;
  bool get active => _active;
  set active(bool value) {
    _active = value;
    notifyListeners();
  }
}

/// Preferences whose read finishes only when the test says so.
class _SlowPrefs extends InMemoryKitchenPreferences {
  final read = Completer<bool?>();
  @override
  Future<bool?> readBigText() => read.future;
}

class _ThrowingLock implements ScreenWakeLock {
  int calls = 0;
  @override
  Future<void> acquire() async {
    calls++;
    throw StateError('broken');
  }

  @override
  Future<void> release() async {
    calls++;
    throw StateError('broken');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeScreenWakeLock lock;
  late InMemoryKitchenPreferences prefs;
  late _Session session;

  KitchenMode make({KitchenPreferences? preferences}) => KitchenMode(
    wakeLock: lock,
    preferences: preferences ?? prefs,
    observeLifecycle: false,
  );

  setUp(() {
    lock = FakeScreenWakeLock();
    prefs = InMemoryKitchenPreferences();
    session = _Session();
  });

  group('wake lock', () {
    test('held only while the session is active', () async {
      final mode = make()..followSession(session, () => session.active);
      await pumpEventQueue();
      expect(lock.calls, isEmpty, reason: 'no session yet');
      expect(mode.keepsScreenOn, isFalse);
      session.active = true;
      expect(lock.calls, [true]);
      expect(mode.keepsScreenOn, isTrue);
      session.active = true; // no change
      expect(lock.calls, [true]);
      session.active = false; // session ended
      expect(lock.calls, [true, false]);
      mode.dispose();
      expect(lock.calls, [true, false], reason: 'nothing left to release');
    });

    test('released in the background and taken again on return', () {
      final mode = make()..setSessionActive(true);
      mode.setForeground(false);
      expect(lock.calls, [true, false]);
      mode.setForeground(true);
      expect(lock.calls, [true, false, true]);
      mode.dispose();
      expect(lock.calls, [true, false, true, false]);
    });

    test('coming back after the session ended does not re-acquire', () {
      final mode = make()
        ..setSessionActive(true)
        ..setForeground(false)
        ..setSessionActive(false)
        ..setForeground(true);
      expect(lock.calls, [true, false]);
      mode.dispose();
    });

    test('dispose releases, stops following the session, and is idempotent',
        () {
      final mode = make()..followSession(session, () => session.active);
      session.active = true;
      mode.dispose();
      expect(lock.calls, [true, false]);
      mode.dispose();
      session.active = false;
      session.active = true;
      mode.followSession(session, () => true);
      mode.setSessionActive(true);
      expect(lock.calls, [true, false], reason: 'nothing after dispose');
    });

    test('following a new source drops the old one', () {
      final other = _Session();
      final mode = make()
        ..followSession(session, () => session.active)
        ..followSession(other, () => other.active);
      session.active = true;
      expect(lock.calls, isEmpty, reason: 'the old source is ignored');
      other.active = true;
      expect(lock.calls, [true]);
      mode.dispose();
    });

    test('a throwing lock never breaks the screen', () async {
      final broken = _ThrowingLock();
      final mode = KitchenMode(
        wakeLock: broken,
        preferences: prefs,
        observeLifecycle: false,
      )..setSessionActive(true);
      mode.setSessionActive(false);
      await pumpEventQueue();
      expect(broken.calls, 2);
      mode.dispose();
    });
  });

  group('lifecycle', () {
    testWidgets('hidden and paused release; resumed re-acquires', (
      tester,
    ) async {
      final mode = KitchenMode(wakeLock: lock, preferences: prefs)
        ..setSessionActive(true);
      expect(lock.calls, [true]);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(lock.calls, [true, false]);
      expect(mode.keepsScreenOn, isFalse);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(lock.calls, [true, false, true], reason: 'inactive is visible');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(lock.calls, [true, false, true]);
      mode.dispose();
      expect(lock.calls, [true, false, true, false]);
      // No longer listening after dispose.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(lock.calls, hasLength(4));
    });

    testWidgets('starting in the background waits for the app to return', (
      tester,
    ) async {
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      final mode = KitchenMode(wakeLock: lock, preferences: prefs)
        ..setSessionActive(true);
      expect(lock.calls, isEmpty);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(lock.calls, [true]);
      mode.dispose();
    });
  });

  group('big text', () {
    test('starts off and loads the saved choice', () async {
      prefs.bigText = true;
      final mode = make();
      expect(mode.bigText, isFalse);
      var notified = 0;
      mode.addListener(() => notified++);
      await mode.load();
      expect(mode.bigText, isTrue);
      expect(notified, 1);
      await mode.load(); // same value: no notification
      expect(notified, 1);
      mode.dispose();
    });

    test('no saved choice or unreadable storage leaves it off', () async {
      final mode = make();
      await mode.load();
      expect(mode.bigText, isFalse);
      prefs.failReads = true;
      await mode.load();
      expect(mode.bigText, isFalse);
      mode.dispose();
    });

    test('toggling saves the choice on this device', () async {
      final mode = make();
      await mode.setBigText(true);
      expect(mode.bigText, isTrue);
      expect(prefs.bigText, isTrue);
      await mode.setBigText(true); // unchanged: not written again
      expect(prefs.writes, 1);
      await mode.setBigText(false);
      expect(prefs.bigText, isFalse);
      expect(prefs.writes, 2);
      mode.dispose();
    });

    test('rapid toggles are saved in order', () async {
      final mode = make();
      unawaited(mode.setBigText(true));
      unawaited(mode.setBigText(false));
      await mode.setBigText(true);
      expect(prefs.bigText, isTrue);
      expect(prefs.writes, 3);
      mode.dispose();
    });

    test('a failed save still applies the choice for now', () async {
      prefs.failWrites = true;
      final mode = make();
      await mode.setBigText(true);
      expect(mode.bigText, isTrue);
      expect(prefs.bigText, isNull);
      mode.dispose();
    });

    test('a choice made while loading wins over the saved one', () async {
      final slow = _SlowPrefs();
      final mode = make(preferences: slow);
      final loading = mode.load();
      await mode.setBigText(true);
      slow.read.complete(false);
      await loading;
      expect(mode.bigText, isTrue);
      mode.dispose();
    });

    test('a load that finishes after dispose changes nothing', () async {
      final slow = _SlowPrefs();
      final mode = make(preferences: slow);
      final loading = mode.load();
      mode.dispose();
      slow.read.complete(true);
      await loading;
      expect(mode.bigText, isFalse);
      await mode.setBigText(true);
      expect(mode.bigText, isFalse);
      expect(slow.writes, 0);
    });
  });

  group('scope', () {
    testWidgets('creates from the scope, or this device by default', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      KitchenMode? scoped;
      KitchenMode? fallback;
      final made = make();
      await tester.pumpWidget(
        Column(
          children: [
            KitchenModeScope(
              create: () => made,
              child: Builder(
                builder: (context) {
                  scoped = KitchenModeScope.createFor(context);
                  return const SizedBox();
                },
              ),
            ),
            Builder(
              builder: (context) {
                fallback = KitchenModeScope.createFor(context);
                return const SizedBox();
              },
            ),
          ],
        ),
      );
      expect(scoped, same(made));
      expect(fallback, isNotNull);
      // The device default degrades silently without platform channels.
      fallback!.setSessionActive(true);
      await tester.runAsync(fallback!.load);
      fallback!.dispose();
      made.dispose();
      final scope = tester.widget<KitchenModeScope>(
        find.byType(KitchenModeScope),
      );
      expect(scope.updateShouldNotify(scope), isFalse);
    });
  });
}
