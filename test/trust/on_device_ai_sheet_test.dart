import 'dart:async';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/trust/on_device_ai_sheet.dart';
import 'package:soussight/trust/privacy_preferences.dart';

import 'trust_test_helpers.dart';

const _downloadable = HybridAvailability(status: OnDeviceStatus.downloadable);
const _available = HybridAvailability(status: OnDeviceStatus.available);

class _Prepare {
  final calls = <bool>[];
  final controller = StreamController<double?>.broadcast();

  Stream<double?> call({required bool withImage}) {
    calls.add(withImage);
    return controller.stream;
  }
}

final _sheetScroll = find
    .descendant(
      of: find.byKey(const ValueKey('on-device-ai-sheet')),
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  testWidgets(
    'Set up calls prepare inside the tap, shows progress, then re-reads '
    'availability',
    (tester) async {
      final prepare = _Prepare();
      // Availability checks never answer until setup finishes, so a handler
      // that awaited anything before prepare would never reach it.
      final gate = Completer<void>();
      final checks = <bool>[];
      var readyCalls = 0;
      Future<HybridAvailability> check({required bool withImage}) async {
        checks.add(withImage);
        await gate.future;
        return _available;
      }

      await pumpPhone(
        tester,
        OnDeviceAiSheet(
          capabilities: fakeWebCapabilities,
          textAvailability: _downloadable,
          imageAvailability: _downloadable,
          prepare: prepare.call,
          checkAvailability: check,
          privacy: InMemoryPrivacyPreferences(),
          onReady: () => readyCalls++,
        ),
      );

      expect(find.text('Ready to set up.'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('set-up-on-device')));
      // Called during the tap itself, before any frame or await.
      expect(prepare.calls, [true]);
      expect(checks, isEmpty);

      await tester.pump();
      expect(find.byKey(const ValueKey('on-device-progress')), findsOneWidget);
      expect(find.text('Setting up…'), findsOneWidget);
      expect(find.byKey(const ValueKey('set-up-on-device')), findsNothing);

      prepare.controller.add(0.42);
      await tester.pump();
      expect(find.text('Downloading… 42%'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('on-device-progress')),
      );
      expect(bar.value, 0.42);

      await prepare.controller.close();
      await tester.pump();
      expect(checks, [false]);
      expect(find.byKey(const ValueKey('on-device-ready')), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(checks, [false, true]);

      expect(find.byKey(const ValueKey('on-device-ready')), findsOneWidget);
      expect(find.text('Ready on this device.'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('set-up-on-device')), findsNothing);
      expect(readyCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('prepares text only when photos cannot be set up', (
    tester,
  ) async {
    final prepare = _Prepare();
    await pumpPhone(
      tester,
      OnDeviceAiSheet(
        capabilities: fakeWebCapabilities,
        textAvailability: _downloadable,
        imageAvailability: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
        ),
        prepare: prepare.call,
        privacy: InMemoryPrivacyPreferences(),
      ),
    );
    expect(
      find.text('Photo checks need a Chrome setting or a newer device.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('set-up-on-device')));
    expect(prepare.calls, [false]);
  });

  testWidgets('a failed download explains itself and offers a retry', (
    tester,
  ) async {
    final prepare = _Prepare();
    await pumpPhone(
      tester,
      OnDeviceAiSheet(
        capabilities: fakeWebCapabilities,
        textAvailability: _downloadable,
        imageAvailability: _downloadable,
        prepare: prepare.call,
        privacy: InMemoryPrivacyPreferences(),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('set-up-on-device')));
    await tester.pump();
    prepare.controller.addError(
      const HybridException(HybridErrorCode.network, 'offline'),
    );
    await tester.pump();

    expect(
      find.text('The download needs a connection. Try again on Wi-Fi.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('set-up-on-device')));
    expect(prepare.calls, [true, true]);
  });

  testWidgets('no set-up button when the model is already available', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      OnDeviceAiSheet(
        capabilities: fakeWebCapabilities,
        textAvailability: const HybridAvailability(
          status: OnDeviceStatus.available,
          modelLabel: 'Gemini Nano',
        ),
        imageAvailability: _available,
        prepare: _Prepare().call,
        privacy: InMemoryPrivacyPreferences(),
      ),
    );
    expect(find.text('Ready on this device.'), findsNWidgets(2));
    expect(find.textContaining('Gemini Nano'), findsNothing);
    expect(
      find.text(
        'Text and photo help can run right here on this device, even '
        'offline. Each answer shows where it actually ran.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('stay here'), findsNothing);
    expect(find.byKey(const ValueKey('set-up-on-device')), findsNothing);
  });

  testWidgets('privacy switches write the preferences', (tester) async {
    final privacy = InMemoryPrivacyPreferences({'coach_lite'});
    await pumpPhone(
      tester,
      OnDeviceAiSheet(
        capabilities: fakeWebCapabilities,
        textAvailability: _available,
        imageAvailability: _available,
        prepare: _Prepare().call,
        privacy: privacy,
      ),
    );
    final pantry = find.byKey(const ValueKey('local-only-pantry_scan'));
    await tester.scrollUntilVisible(pantry, 200, scrollable: _sheetScroll);
    expect(tester.widget<SwitchListTile>(pantry).value, isFalse);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('local-only-coach_lite')),
          )
          .value,
      isTrue,
    );

    await tester.tap(pantry);
    await tester.pump();
    expect(privacy.localOnly('pantry_scan'), isTrue);
    expect(tester.widget<SwitchListTile>(pantry).value, isTrue);

    // SS-096: nearby lookups have their own switch.
    final nearby = find.byKey(const ValueKey('local-only-nearby'));
    await tester.scrollUntilVisible(nearby, 200, scrollable: _sheetScroll);
    await tester.ensureVisible(nearby);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: nearby,
        matching: find.text('Keep Find food help on this device'),
      ),
      findsOneWidget,
    );
    await tester.tap(nearby);
    await tester.pump();
    expect(privacy.localOnly('nearby'), isTrue);
  });

  testWidgets('enable steps open for this platform and name the Chrome flag', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      OnDeviceAiSheet(
        capabilities: fakeWebCapabilities,
        textAvailability: _available,
        imageAvailability: _available,
        prepare: _Prepare().call,
        privacy: InMemoryPrivacyPreferences(),
      ),
    );
    final flag = find.textContaining(
      'chrome://flags/#prompt-api-for-gemini-nano-multimodal-input',
      findRichText: true,
    );
    // SS-089: setup steps (22 GB, flags) live under "Details".
    expect(flag, findsNothing);
    final details = find.byKey(const ValueKey('on-device-details'));
    await tester.scrollUntilVisible(details, 200, scrollable: _sheetScroll);
    await tester.ensureVisible(details);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(flag, 200, scrollable: _sheetScroll);
    expect(flag, findsOneWidget);
    expect(find.text('Chrome on a computer (this device)'), findsOneWidget);
    expect(find.textContaining('22 GB', findRichText: true), findsOneWidget);
    expect(
      find.textContaining(
        'Recent desktop Chrome on Windows, macOS, Linux or Chromebook Plus.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    // No unverified minimum versions.
    expect(
      find.textContaining(RegExp(r'Chrome \d|iOS \d'), findRichText: true),
      findsNothing,
    );
    // Other platforms start collapsed.
    expect(
      find.textContaining('AICore developer preview', findRichText: true),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.text('iPhone'),
      200,
      scrollable: _sheetScroll,
    );
    await tester.drag(_sheetScroll, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('iPhone'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'An iPhone with Apple Intelligence turned on '
        '(Settings → Apple Intelligence & Siri).',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(RegExp(r'iOS \d'), findRichText: true),
      findsNothing,
    );
  });

  group('SS-089: the intro never contradicts the status rows', () {
    Future<String> intro(
      WidgetTester tester, {
      required HybridAvailability text,
      bool practice = false,
      HybridCapabilities capabilities = fakeWebCapabilities,
    }) async {
      await pumpPhone(
        tester,
        OnDeviceAiSheet(
          capabilities: capabilities,
          textAvailability: text,
          imageAvailability: text,
          prepare: _Prepare().call,
          privacy: InMemoryPrivacyPreferences(),
          practice: practice,
        ),
      );
      return tester
          .widget<Text>(find.byKey(const ValueKey('on-device-intro')))
          .data!;
    }

    testWidgets('unsupported device: says it cannot help offline', (
      tester,
    ) async {
      final line = await intro(
        tester,
        text: const HybridAvailability(
          status: OnDeviceStatus.unavailable,
          reason: 'device_not_eligible',
        ),
      );
      expect(line, startsWith("This device can't help offline right now."));
      expect(line, isNot(contains('stay here')));
      expect(find.text("This device isn't supported."), findsNWidgets(2));
    });

    testWidgets('downloadable: says it works once set up', (tester) async {
      final line = await intro(
        tester,
        text: const HybridAvailability(status: OnDeviceStatus.downloadable),
      );
      expect(line, contains('once it is set up'));
      expect(find.text('Set up offline help'), findsOneWidget);
    });

    testWidgets('practice mode: says nothing real runs', (tester) async {
      final line = await intro(tester, text: _available, practice: true);
      expect(line, startsWith('Practice mode (pretend answers)'));
      expect(line, contains('no AI runs here'));
      expect(find.text('Ready on this device.'), findsNothing);
      expect(
        find.text('Pretend answers only (practice mode).'),
        findsNWidgets(2),
      );
    });

    testWidgets('technical names only under Details', (tester) async {
      await intro(
        tester,
        text: const HybridAvailability(
          status: OnDeviceStatus.available,
          modelLabel: 'gemini-nano-4',
        ),
      );
      expect(find.textContaining('Gemini Nano'), findsNothing);
      expect(find.textContaining('Firebase'), findsNothing);
      final details = find.byKey(const ValueKey('on-device-details'));
      await tester.scrollUntilVisible(details, 200, scrollable: _sheetScroll);
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      final technical = tester
          .widget<Text>(find.byKey(const ValueKey('on-device-technical')))
          .data!;
      expect(technical, contains('Gemini Nano (gemini-nano-4)'));
      expect(technical, contains('Firebase AI Logic'));
    });

    test('status text keeps model names out of the rows', () {
      expect(
        onDeviceStatusText(
          const HybridAvailability(
            status: OnDeviceStatus.available,
            modelLabel: 'gemini-nano-4',
          ),
          image: false,
        ),
        'Ready on this device.',
      );
      expect(
        onDeviceStatusText(
          _available,
          image: true,
          local: fakeIosCapabilities.local,
        ),
        'Reads text only on this device.',
      );
      expect(
        onDeviceStatusText(
          const HybridAvailability(
            status: OnDeviceStatus.unavailable,
            reason: 'bridge_unavailable',
          ),
          image: false,
        ),
        "Offline help didn't start in this build.",
      );
    });
  });

  testWidgets('Codex #221: a text-only device states text and photos '
      'separately and promises no transfer', (tester) async {
    await pumpPhone(
      tester,
      OnDeviceAiSheet(
        capabilities: fakeIosCapabilities,
        textAvailability: _available,
        imageAvailability: _available,
        prepare: _Prepare().call,
        privacy: InMemoryPrivacyPreferences(),
      ),
    );
    final intro = tester
        .widget<Text>(find.byKey(const ValueKey('on-device-intro')))
        .data!;
    expect(intro, contains('Text help can run right here'));
    expect(intro, contains("Photo checks can't run here yet"));
    expect(intro, isNot(contains('photos and notes stay here')));
    expect(find.text('Reads text only on this device.'), findsOneWidget);
  });
}
