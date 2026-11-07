// Model IDs and call settings for the Gemini clients (Firebase AI Logic,
// Gemini Developer API via FirebaseAI.googleAI()).
//
// Override any model at build time without a code change, e.g.
//   flutter run --dart-define=ASSESSMENT_MODEL=gemini-3.8-flash

import 'package:firebase_ai/firebase_ai.dart';

abstract final class AiConfig {
  /// Checkpoint assessment (images + structured output).
  static const assessmentModel = String.fromEnvironment(
    'ASSESSMENT_MODEL',
    defaultValue: 'gemini-3.8-flash',
  );

  /// Help-request triage: category, urgency, instructor summary.
  static const triageModel = String.fromEnvironment(
    'TRIAGE_MODEL',
    defaultValue: 'gemini-3.5-flash-lite',
  );

  /// Gemini Live (stretch goal, audio-only push-to-talk).
  static const liveModel = String.fromEnvironment(
    'LIVE_MODEL',
    defaultValue: 'gemini-3.1-flash-live-preview',
  );

  /// Gemini 3.x ignores `temperature` (deprecated in firebase_ai 5.x), so
  /// determinism comes from the schema and a low thinking level instead.
  static const assessmentThinking = ThinkingLevel.low;
  static const triageThinking = ThinkingLevel.low;

  /// After this, the client gives up and returns its fallback result.
  static const assessmentTimeout = Duration(seconds: 25);
  static const triageTimeout = Duration(seconds: 15);
}
