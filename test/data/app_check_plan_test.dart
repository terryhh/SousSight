import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/data/firebase_services.dart';

void main() {
  group('web (unchanged)', () {
    test('stays off without a debug token or site key', () {
      expect(
        appCheckPlan(
          isWeb: true,
          isReleaseBuild: true,
          debugToken: '',
          recaptchaSiteKey: '',
        ),
        isNull,
      );
    });

    test('debug token wins over the site key', () {
      final plan = appCheckPlan(
        isWeb: true,
        isReleaseBuild: false,
        debugToken: 'token',
        recaptchaSiteKey: 'site',
      )!;
      expect(plan.web, isA<WebDebugProvider>());
    });

    test('site key selects reCAPTCHA Enterprise', () {
      final plan = appCheckPlan(
        isWeb: true,
        isReleaseBuild: true,
        debugToken: '',
        recaptchaSiteKey: 'site',
      )!;
      expect(plan.web, isA<ReCaptchaEnterpriseProvider>());
    });
  });

  group('Android and iOS', () {
    test('debug builds always activate the debug providers', () {
      final plan = appCheckPlan(
        isWeb: false,
        isReleaseBuild: false,
        debugToken: '',
        recaptchaSiteKey: '',
      )!;
      expect(plan.android, isA<AndroidDebugProvider>());
      expect((plan.android as AndroidDebugProvider).debugToken, isNull);
      expect(plan.apple, isA<AppleDebugProvider>());
      expect((plan.apple as AppleDebugProvider).debugToken, isNull);
    });

    test('debug builds use the APPCHECK_DEBUG_TOKEN define when given', () {
      final plan = appCheckPlan(
        isWeb: false,
        isReleaseBuild: false,
        debugToken: 'local-token',
        recaptchaSiteKey: '',
      )!;
      expect((plan.android as AndroidDebugProvider).debugToken, 'local-token');
      expect((plan.apple as AppleDebugProvider).debugToken, 'local-token');
    });

    test('release builds attest and ignore any debug token', () {
      final plan = appCheckPlan(
        isWeb: false,
        isReleaseBuild: true,
        debugToken: 'leaked-token',
        recaptchaSiteKey: '',
      )!;
      expect(plan.android, isA<AndroidPlayIntegrityProvider>());
      expect(plan.apple, isA<AppleAppAttestWithDeviceCheckFallbackProvider>());
      expect(plan.web, isNull);
    });
  });
}
