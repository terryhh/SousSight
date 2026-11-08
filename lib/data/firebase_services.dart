// Real backend wiring: Firebase init, App Check, Firestore repositories.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../app/services_scope.dart';
import '../firebase_options.dart';
import 'firestore_repositories.dart';

const kAppCheckDebugToken = String.fromEnvironment('APPCHECK_DEBUG_TOKEN');
const kRecaptchaSiteKey = String.fromEnvironment('RECAPTCHA_SITE_KEY');

/// Initializes Firebase and App Check. Safe to call more than once.
Future<void> initFirebase() async {
  if (Firebase.apps.isNotEmpty) return;
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // App Check is enforced for Firebase AI Logic, so it must be active before
  // the first Gemini call. Debug token for the hackathon; never committed.
  if (kAppCheckDebugToken.isNotEmpty) {
    await FirebaseAppCheck.instance
        .activate(providerWeb: WebDebugProvider(debugToken: kAppCheckDebugToken));
  } else if (kRecaptchaSiteKey.isNotEmpty) {
    await FirebaseAppCheck.instance
        .activate(providerWeb: ReCaptchaEnterpriseProvider(kRecaptchaSiteKey));
  }
}

Future<AppServices> firebaseServices() async {
  await initFirebase();
  final db = FirebaseFirestore.instance;
  final recipe = await loadBundledRecipe();
  return AppServices(
    auth: FirebaseAuthService(FirebaseAuth.instance),
    recipes: FirestoreRecipeRepository(db, recipe),
    sessions: FirestoreSessionRepository(db),
    bundledRecipe: recipe,
  );
}
