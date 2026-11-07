import 'package:firebase_ai/firebase_ai.dart';

/// Transport boundary shared by the structured clients. Tests inject a generator
/// here, so validation tests do not need Firebase credentials or a network.
typedef JsonGenerator = Future<String?> Function(JsonGenerationRequest request);

class JsonGenerationRequest {
  const JsonGenerationRequest({
    required this.model,
    required this.systemInstruction,
    required this.contents,
    required this.config,
  });

  final String model;
  final String systemInstruction;
  final List<Content> contents;
  final GenerationConfig config;
}

/// Call only after Firebase and App Check have been initialized by the app.
Future<String?> generateJsonWithFirebase(JsonGenerationRequest request) async {
  final model = FirebaseAI.googleAI().generativeModel(
    model: request.model,
    systemInstruction: Content.system(request.systemInstruction),
    generationConfig: request.config,
  );
  return (await model.generateContent(request.contents)).text;
}
