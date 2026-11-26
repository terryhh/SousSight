import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/trust/app_readiness.dart';

import 'trust_test_helpers.dart';

const _ok = HybridAvailability(status: OnDeviceStatus.available);
HybridAvailability _un(String reason) =>
    HybridAvailability(status: OnDeviceStatus.unavailable, reason: reason);

ReadinessInput input({
  HybridCapabilities capabilities = fakeWebCapabilities,
  HybridAvailability text = _ok,
  HybridAvailability image = _ok,
  CameraAccess camera = CameraAccess.granted,
  bool online = true,
  bool cloudApproved = true,
  bool attestationFailed = false,
  bool quotaReached = false,
}) => ReadinessInput(
  capabilities: capabilities,
  text: text,
  image: image,
  camera: camera,
  online: online,
  cloudApproved: cloudApproved,
  attestationFailed: attestationFailed,
  quotaReached: quotaReached,
);

AppReadiness eval(ReadinessInput i) => AppReadiness.evaluate(i);

void main() {
  group('AppReadiness', () {
    test('everything ready', () {
      final r = eval(input());
      expect(r.states, {ReadinessState.ready});
      expect(r.primary.action, ReadinessAction.startCooking);
      expect(r.canUseAi, isTrue);
    });

    // (name, input, primary state, primary action, primary level)
    final cases =
        <
          (
            String,
            ReadinessInput,
            ReadinessState,
            ReadinessAction,
            ReadinessLevel,
          )
        >[
          (
            'attestation failure with a local model',
            input(attestationFailed: true),
            ReadinessState.attestationFailed,
            ReadinessAction.reload,
            ReadinessLevel.limited,
          ),
          (
            'attestation failure without a local model',
            input(
              capabilities: const HybridCapabilities.none(),
              text: _un('bridge_unavailable'),
              image: _un('bridge_unavailable'),
              attestationFailed: true,
            ),
            ReadinessState.attestationFailed,
            ReadinessAction.reload,
            ReadinessLevel.blocking,
          ),
          (
            'quota reached with a local model',
            input(quotaReached: true),
            ReadinessState.quotaReached,
            ReadinessAction.keepCooking,
            ReadinessLevel.limited,
          ),
          (
            'offline with a local model',
            input(online: false),
            ReadinessState.offline,
            ReadinessAction.keepCooking,
            ReadinessLevel.limited,
          ),
          (
            'offline with nothing local',
            input(
              online: false,
              text: const HybridAvailability(
                status: OnDeviceStatus.downloadable,
              ),
              image: const HybridAvailability(
                status: OnDeviceStatus.downloadable,
              ),
            ),
            ReadinessState.offline,
            ReadinessAction.checkConnection,
            ReadinessLevel.blocking,
          ),
          (
            'model downloadable, cloud usable',
            input(
              text: const HybridAvailability(
                status: OnDeviceStatus.downloadable,
              ),
              image: const HybridAvailability(
                status: OnDeviceStatus.downloadable,
              ),
            ),
            ReadinessState.modelDownloadable,
            ReadinessAction.openOnDeviceSetup,
            ReadinessLevel.limited,
          ),
          (
            'model downloading, cloud off',
            input(
              cloudApproved: false,
              text: const HybridAvailability(
                status: OnDeviceStatus.downloading,
              ),
              image: const HybridAvailability(
                status: OnDeviceStatus.downloading,
              ),
            ),
            ReadinessState.modelDownloading,
            ReadinessAction.showDownloadProgress,
            ReadinessLevel.blocking,
          ),
          (
            'bridge missing, cloud usable',
            input(
              capabilities: const HybridCapabilities.none(),
              text: _un('bridge_unavailable'),
              image: _un('bridge_unavailable'),
            ),
            ReadinessState.bridgeUnavailable,
            ReadinessAction.useCloudHelp,
            ReadinessLevel.limited,
          ),
          (
            'bridge missing, cloud off',
            input(
              cloudApproved: false,
              capabilities: const HybridCapabilities.none(),
              text: _un('bridge_unavailable'),
              image: _un('bridge_unavailable'),
            ),
            ReadinessState.bridgeUnavailable,
            ReadinessAction.showEnableSteps,
            ReadinessLevel.blocking,
          ),
          (
            'unsupported browser',
            input(
              text: _un('unsupported_browser'),
              image: _un('unsupported_browser'),
            ),
            ReadinessState.deviceNotSupported,
            ReadinessAction.showEnableSteps,
            ReadinessLevel.limited,
          ),
          (
            'Apple Intelligence off',
            input(
              capabilities: fakeIosCapabilities,
              text: _un('apple_intelligence_off'),
              image: _un('apple_intelligence_off'),
            ),
            ReadinessState.appleIntelligenceOff,
            ReadinessAction.showEnableSteps,
            ReadinessLevel.limited,
          ),
          (
            'Android not enrolled',
            input(text: _un('not_enrolled'), image: _un('not_enrolled')),
            ReadinessState.notEnrolled,
            ReadinessAction.showEnableSteps,
            ReadinessLevel.limited,
          ),
          (
            'web text ready, photos need the Chrome flag',
            input(image: _un('model_not_ready')),
            ReadinessState.photosNeedSetting,
            ReadinessAction.showEnableSteps,
            ReadinessLevel.limited,
          ),
          (
            'text ready, photo model downloadable',
            input(
              image: const HybridAvailability(
                status: OnDeviceStatus.downloadable,
              ),
            ),
            ReadinessState.photosNeedSetup,
            ReadinessAction.openOnDeviceSetup,
            ReadinessLevel.limited,
          ),
          (
            'camera denied',
            input(camera: CameraAccess.denied),
            ReadinessState.cameraDenied,
            ReadinessAction.allowCamera,
            ReadinessLevel.limited,
          ),
          (
            'no camera',
            input(camera: CameraAccess.noCamera),
            ReadinessState.noCamera,
            ReadinessAction.typeInstead,
            ReadinessLevel.limited,
          ),
        ];
    for (final (name, i, state, action, level) in cases) {
      test(name, () {
        final r = eval(i);
        expect(r.primary.state, state);
        expect(r.primary.action, action);
        expect(r.primary.level, level);
        expect(r.primary.message, isNotEmpty);
      });
    }

    test('iOS reads text only: photos use the cloud, and say so', () {
      final r = eval(
        input(
          capabilities: fakeIosCapabilities,
          image: _un('device_not_eligible'),
        ),
      );
      expect(r.states, {ReadinessState.photosNeedCloud, ReadinessState.ready});
      expect(r.primary.state, ReadinessState.photosNeedCloud);
      expect(
        r.primary.message,
        contains('Apple Foundation Models reads text only'),
      );
    });

    test('nothing can run: offers cooking without AI', () {
      final r = eval(
        input(
          cloudApproved: false,
          text: _un('device_not_eligible'),
          image: _un('device_not_eligible'),
        ),
      );
      expect(r.canUseAi, isFalse);
      expect(r.states, contains(ReadinessState.noAiAvailable));
      expect(
        r.items
            .firstWhere((i) => i.state == ReadinessState.noAiAvailable)
            .action,
        ReadinessAction.cookWithoutAi,
      );
      expect(r.states, isNot(contains(ReadinessState.ready)));
    });

    test(
      'cloud problems are not shown when cloud help is off in this build',
      () {
        final r = eval(
          input(
            cloudApproved: false,
            attestationFailed: true,
            quotaReached: true,
          ),
        );
        expect(r.states, {ReadinessState.ready});
      },
    );

    test('withCloudError maps attestation and quota codes', () {
      final base = input();
      expect(
        eval(base.withCloudError(HybridErrorCode.attestation)).primary.state,
        ReadinessState.attestationFailed,
      );
      expect(
        eval(base.withCloudError(HybridErrorCode.quota)).primary.state,
        ReadinessState.quotaReached,
      );
      expect(
        eval(base.withCloudError(HybridErrorCode.busy)).primary.state,
        ReadinessState.ready,
      );
    });

    test('several problems are ordered most serious first', () {
      final r = eval(
        input(
          online: false,
          camera: CameraAccess.denied,
          text: const HybridAvailability(status: OnDeviceStatus.downloadable),
        ),
      );
      expect(r.items.first.level, ReadinessLevel.blocking);
      expect(
        r.items.map((i) => i.level.index).toList(),
        orderedEquals([...r.items.map((i) => i.level.index)]..sort()),
      );
    });
  });

  testWidgets('panel shows each state with its action', (tester) async {
    final actions = <ReadinessAction>[];
    await pumpPhone(
      tester,
      ReadinessPanel(
        readiness: eval(input(camera: CameraAccess.denied, online: false)),
        onAction: actions.add,
      ),
    );
    expect(find.byKey(const ValueKey('readiness-offline')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('readiness-cameraDenied')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('readiness-action-cameraDenied')),
    );
    await tester.tap(find.byKey(const ValueKey('readiness-action-offline')));
    expect(actions, [ReadinessAction.allowCamera, ReadinessAction.keepCooking]);
    expect(find.widgetWithText(FilledButton, 'Keep cooking'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
