// Production wiring for on-demand illustrations (SS-098).

import 'package:flutter/foundation.dart';

import '../app/hybrid_runtime.dart';
import 'illustration_controller.dart';
import 'illustration_generator.dart';
import 'illustration_ledger.dart';

final _usage = Expando<IllustrationUsage>('illustration usage');

/// The paid-send counts for this app run, keyed by cooking-session id. It
/// lives as long as [hybrid], so re-entering the same cooking session
/// (back to the pantry, then the same draft again) keeps its count.
IllustrationUsage illustrationUsageFor(HybridRuntime hybrid) =>
    _usage[hybrid] ??= IllustrationUsage();

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
    ledger: InferenceLedgerIllustrations(hybrid.ledger),
    generator: generator ?? FirebaseAiIllustrationGenerator(),
    settingsChanges: hybrid.privacy,
    usage: illustrationUsageFor(hybrid),
  );
}
