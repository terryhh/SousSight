// Production wiring for on-demand illustrations (SS-098).

import '../app/hybrid_runtime.dart';
import 'illustration_controller.dart';
import 'illustration_generator.dart';

/// A controller on the app's shared hybrid services: its routes, privacy
/// settings, connectivity and ledger. The consent prompt names the image
/// model, not the text model.
IllustrationController illustrationControllerFor(
  HybridRuntime hybrid, {
  IllustrationGenerator? generator,
}) => IllustrationController(
  cloudRoutes: hybrid.cloudRoutes,
  privacy: hybrid.privacy,
  isOnline: hybrid.isOnline,
  consent: DialogConsentGate(
    navigatorKey: hybrid.navigatorKey,
    cloudModel: generator?.model ?? kIllustrationModel,
  ),
  recorder: hybrid.cloudSends,
  generator: generator ?? FirebaseAiIllustrationGenerator(),
);
