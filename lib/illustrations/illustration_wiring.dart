// Production wiring for on-demand illustrations (SS-098).

import 'package:flutter/foundation.dart';

import '../app/hybrid_runtime.dart';
import 'illustration_controller.dart';
import 'illustration_generator.dart';

/// Tests replace the controller the cooking screen builds (fake generator,
/// consent and cap). Never set in the app.
@visibleForTesting
IllustrationController Function(HybridRuntime hybrid)?
debugIllustrationControllerFactory;

/// A controller on the app's shared hybrid services: its routes, privacy
/// settings, connectivity and ledger. The consent prompt names the image
/// model, not the text model. The caller owns it for one cooking session
/// and disposes it when the session ends.
IllustrationController illustrationControllerFor(
  HybridRuntime hybrid, {
  IllustrationGenerator? generator,
}) {
  if (debugIllustrationControllerFactory case final make?) return make(hybrid);
  return IllustrationController(
    cloudRoutes: hybrid.cloudRoutes,
    privacy: hybrid.privacy,
    isOnline: hybrid.isOnline,
    consent: DialogConsentGate(
      navigatorKey: hybrid.navigatorKey,
      cloudModel: generator?.model ?? kIllustrationModel,
    ),
    recorder: hybrid.cloudSends,
    generator: generator ?? FirebaseAiIllustrationGenerator(),
    settingsChanges: hybrid.privacy,
  );
}
