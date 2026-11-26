// Real backend wiring: Firebase init, App Check, Firestore repositories.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;

import '../app/services_scope.dart';
import '../firebase_options.dart';
import 'firebase_analytics_sink.dart';
import 'firestore_repositories.dart';

const kAppCheckDebugToken = String.fromEnvironment('APPCHECK_DEBUG_TOKEN');
const kRecaptchaSiteKey = String.fromEnvironment('RECAPTCHA_SITE_KEY');

/// Initializes Firebase and App Check. Safe to call more than once.
Future<void> initFirebase() async {
  if (Firebase.apps.isNotEmpty) return;
  // TODO(SS-073, Terry): iOS has no Firebase app yet, so
  // DefaultFirebaseOptions.currentPlatform throws on iOS. Register it with
  // `flutterfire configure --platforms=android,ios,web` (needs Terry's login);
  // that regenerates lib/firebase_options.dart and adds
  // ios/Runner/GoogleService-Info.plist.
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // App Check is enforced for Firebase AI Logic, so it must be active before
  // the first Gemini call. Debug token for the hackathon; never committed.
  final plan = appCheckPlan(
    isWeb: kIsWeb,
    isReleaseBuild: kReleaseMode,
    // Constant-folded so a native release binary never contains the token,
    // even if a build passes the define by mistake. Web keeps its behaviour.
    debugToken: kReleaseMode && !kIsWeb ? '' : kAppCheckDebugToken,
    recaptchaSiteKey: kRecaptchaSiteKey,
  );
  if (plan != null) {
    await FirebaseAppCheck.instance.activate(
      providerWeb: plan.web,
      providerAndroid: plan.android,
      providerApple: plan.apple,
    );
  }
}

/// The App Check providers to activate, or null to leave App Check off.
class AppCheckPlan {
  const AppCheckPlan({
    this.web,
    this.android = const AndroidPlayIntegrityProvider(),
    this.apple = const AppleAppAttestWithDeviceCheckFallbackProvider(),
  });

  final WebProvider? web;
  final AndroidAppCheckProvider android;
  final AppleAppCheckProvider apple;
}

/// Web: unchanged, active only with a debug token or a reCAPTCHA site key.
///
/// Android and iOS: always active. Debug and profile builds use the debug
/// providers (with [debugToken] when given, otherwise the SDK logs a token to
/// register in the console). Release builds use Play Integrity and App Attest
/// with DeviceCheck fallback, and never carry a debug token.
AppCheckPlan? appCheckPlan({
  required bool isWeb,
  required bool isReleaseBuild,
  required String debugToken,
  required String recaptchaSiteKey,
}) {
  if (isWeb) {
    if (debugToken.isNotEmpty) {
      return AppCheckPlan(web: WebDebugProvider(debugToken: debugToken));
    }
    if (recaptchaSiteKey.isNotEmpty) {
      return AppCheckPlan(web: ReCaptchaEnterpriseProvider(recaptchaSiteKey));
    }
    return null;
  }
  if (isReleaseBuild) return const AppCheckPlan();
  final token = debugToken.isEmpty ? null : debugToken;
  return AppCheckPlan(
    android: AndroidDebugProvider(debugToken: token),
    apple: AppleDebugProvider(debugToken: token),
  );
}

Future<AppServices> firebaseServices() async {
  await initFirebase();
  final db = FirebaseFirestore.instance;
  final recipe = await loadBundledRecipe();
  final analytics = FirebaseAnalyticsSink()..start();
  return AppServices(
    auth: FirebaseAuthService(FirebaseAuth.instance),
    recipes: FirestoreRecipeRepository(db, recipe),
    sessions: FirestoreSessionRepository(db),
    bundledRecipe: recipe,
    analytics: analytics,
  );
}
