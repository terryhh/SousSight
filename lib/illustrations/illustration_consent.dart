// The consent prompt for an on-demand illustration (SS-098).
//
// Illustrations are always made in the cloud; no device can draw them. The
// shared prompt copy is written for on-device-first features ("may need
// help from Google … if this device can't answer"), which would understate
// this send, so this prompt says plainly what a yes sends and to whom. It
// uses the shared button labels so every consent prompt reads the same.

import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../app/consent_copy.dart' show kConsentAllowLabel, kConsentDeclineLabel;

({String title, String body}) illustrationConsentCopy({
  required String model,
}) => (
  title: 'Send this to Google to draw a picture?',
  body:
      'Drawing an illustration needs Google: this device cannot make '
      'one. If you say yes, SousSight sends the recipe text for this '
      "picture (the step's visible cue and the ingredients it names, or "
      "the dish's ingredient list) to Google's servers ($model) to draw one "
      'illustration. No photo, voice or location is sent. Your yes '
      "covers this one picture only. Google's own privacy terms cover "
      'what Google does with anything it receives. If you choose '
      '"$kConsentDeclineLabel", nothing is sent.',
);

/// "Send this once" grants exactly the asked payload; anything else
/// (declining, dismissing, no screen to show it on) is a decline.
class IllustrationConsentGate implements ConsentGate {
  IllustrationConsentGate({required this.navigatorKey, required this.model});

  final GlobalKey<NavigatorState> navigatorKey;
  final String model;

  @override
  Future<ConsentGrant?> request(ConsentAsk ask) async {
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
    final copy = illustrationConsentCopy(model: model);
    final allowed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        key: const ValueKey('consent-dialog'),
        icon: const Icon(Icons.cloud_upload_outlined),
        title: Text(copy.title),
        scrollable: true,
        content: Text(copy.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(kConsentDeclineLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(kConsentAllowLabel),
          ),
        ],
      ),
    );
    return allowed == true ? ConsentGrant(ask) : null;
  }
}
