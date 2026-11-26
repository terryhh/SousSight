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
            ReadinessAction.useCloudHelp,
            ReadinessLevel.limited,
          ),
          (
            'unsupported browser, cloud off',
            input(
              cloudApproved: false,
              text: _un('unsupported_browser'),
              image: _un('unsupported_browser'),
            ),
            ReadinessState.deviceNotSupported,
            ReadinessAction.showEnableSteps,
            ReadinessLevel.blocking,
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

    // Regression (Codex review of #180): a recovered cloud call clears the
    // earlier error instead of latching it.
    test('withCloudError reflects only the latest call', () {
      final failed = input()
          .withCloudError(HybridErrorCode.attestation)
          .withCloudError(HybridErrorCode.quota);
      expect(failed.attestationFailed, isFalse);
      expect(failed.quotaReached, isTrue);

      final recovered = failed.withCloudError(null);
      expect(recovered.attestationFailed, isFalse);
      expect(recovered.quotaReached, isFalse);
      final r = eval(recovered);
      expect(r.cloudUsable, isTrue);
      expect(r.states, {ReadinessState.ready});

      final afterAttestation = input()
          .withCloudError(HybridErrorCode.attestation)
          .withCloudError(null);
      expect(eval(afterAttestation).states, {ReadinessState.ready});
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

  group('cloud path', () {
    test('no on-device model with cloud help reads as a chosen path', () {
      for (final reason in ['unsupported_browser', 'bridge_unavailable']) {
        final r = eval(
          input(
            capabilities: reason == 'bridge_unavailable'
                ? const HybridCapabilities.none()
                : fakeWebCapabilities,
            text: _un(reason),
            image: _un(reason),
          ),
        );
        expect(r.primary.cloudPath, isTrue, reason: reason);
        expect(r.primary.action, ReadinessAction.useCloudHelp);
        expect(r.primary.title, 'Answers will come from Google cloud');
        expect(
          r.primary.message,
          "Your device doesn't have on-device AI yet — answers will come "
          "from Google cloud, and we'll show you each time.",
        );
      }
    });

    test('without cloud help it is not dressed up as a choice', () {
      final r = eval(
        input(
          cloudApproved: false,
          text: _un('unsupported_browser'),
          image: _un('unsupported_browser'),
        ),
      );
      expect(r.primary.cloudPath, isFalse);
      expect(r.primary.message, isNot(contains('Google cloud')));
    });

    test('every state has a title and no safety claims', () {
      for (final state in ReadinessState.values) {
        final title = readinessTitle(state);
        expect(title, isNotEmpty);
        expect(title.toLowerCase(), isNot(contains('safe')));
        expect(title.toLowerCase(), isNot(contains('certif')));
      }
    });
  });

  testWidgets('cloud path card shows its title, message and action', (
    tester,
  ) async {
    final actions = <ReadinessAction>[];
    await pumpPhone(
      tester,
      ReadinessPanel(
        readiness: eval(
          input(
            text: _un('unsupported_browser'),
            image: _un('unsupported_browser'),
          ),
        ),
        onAction: actions.add,
      ),
    );
    expect(find.text('Answers will come from Google cloud'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsWidgets);
    await tester.tap(
      find.byKey(const ValueKey('readiness-action-deviceNotSupported')),
    );
    expect(actions, [ReadinessAction.useCloudHelp]);
    expect(tester.takeException(), isNull);
  });

  test('text-only local model without cloud help: photos stay off', () {
    final r = eval(
      input(
        cloudApproved: false,
        capabilities: fakeIosCapabilities,
        image: _un('device_not_eligible'),
      ),
    );
    final photos = r.items.firstWhere(
      (i) => i.state == ReadinessState.photosNeedCloud,
    );
    expect(photos.message, contains("can't run here"));
    expect(photos.action, ReadinessAction.typeInstead);
    expect(photos.cloudPath, isFalse);
    expect(photos.title, "Photos can't be read here");
  });

  testWidgets('every action renders as the primary button', (tester) async {
    for (final action in ReadinessAction.values) {
      final pressed = <ReadinessAction>[];
      await pumpPhone(
        tester,
        ReadinessPanel(readiness: _single(action), onAction: pressed.add),
      );
      await tester.tap(find.byKey(const ValueKey('readiness-action-ready')));
      expect(pressed, [action]);
      expect(find.text(action.label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}

/// A readiness with one item, for rendering each action.
AppReadiness _single(ReadinessAction action) => _OneItem(
  ReadinessItem(
    ReadinessState.ready,
    ReadinessLevel.info,
    'Message',
    action,
    title: 'Title',
  ),
);

class _OneItem implements AppReadiness {
  _OneItem(this.item);
  final ReadinessItem item;
  @override
  List<ReadinessItem> get items => [item];
  @override
  bool get localReady => true;
  @override
  bool get cloudUsable => false;
  @override
  ReadinessItem get primary => item;
  @override
  bool get canUseAi => true;
  @override
  Set<ReadinessState> get states => {item.state};
}
