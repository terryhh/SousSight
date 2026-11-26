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
    expect(find.text('Ready on this device (Gemini Nano).'), findsOneWidget);
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
    await tester.scrollUntilVisible(flag, 200, scrollable: _sheetScroll);
    expect(flag, findsOneWidget);
    expect(find.text('Chrome on a computer (this device)'), findsOneWidget);
    expect(find.textContaining('22 GB', findRichText: true), findsOneWidget);
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
    await tester.tap(find.text('iPhone'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Apple Intelligence & Siri', findRichText: true),
      findsOneWidget,
    );
  });
}
