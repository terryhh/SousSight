// Text→image generation through Firebase AI Logic (SS-098).
//
// Verified November 26, 2026 against firebase_ai 5.1.0 (the installed
// package) and https://firebase.google.com/docs/ai-logic/models: Imagen was
// shut down and removed from the SDK in 4.0.0; images now come from a Gemini
// image model through `generateContent` with
// `responseModalities: [ResponseModalities.image]` and an [ImageConfig].
// The model id is a build define so it can follow Google's model list.
// There is no on-device image model, so this is cloud-only by design.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show HybridErrorCode;
import 'package:firebase_ai/firebase_ai.dart';

/// Gemini image model for illustrations. `gemini-nano-banana-2.1` was US$
/// 0.0336 per 1K image on the Gemini Developer API standard tier when this
/// was written (docs/COST-LEDGER.md).
const kIllustrationModel = String.fromEnvironment(
  'ILLUSTRATION_MODEL',
  defaultValue: 'gemini-nano-banana-2.1',
);

/// On-demand illustrations allowed per cooking session.
const kIllustrationSessionCap = int.fromEnvironment(
  'ILLUSTRATION_SESSION_CAP',
  defaultValue: 4,
);

/// The ledger's label for one illustration leg.
String illustrationModelLabel(String model) => '$model (text→image)';

class GeneratedIllustration {
  const GeneratedIllustration({
    required this.bytes,
    required this.mimeType,
    required this.model,
  });
  final Uint8List bytes;
  final String mimeType;
  final String model;
}

class IllustrationException implements Exception {
  const IllustrationException(this.code, this.message);
  final HybridErrorCode code;
  final String message;
  @override
  String toString() => 'IllustrationException(${code.name}): $message';
}

abstract class IllustrationGenerator {
  String get model;

  /// Throws [IllustrationException] on any failure, including a response
  /// that holds no usable image.
  Future<GeneratedIllustration> generate(String prompt);
}

/// One `generateContent` call. Replaced in tests.
typedef ImageContentSender = Future<GenerateContentResponse> Function({
  required String model,
  required String prompt,
});

Future<GenerateContentResponse> _firebaseAiSend({
  required String model,
  required String prompt,
}) => FirebaseAI.googleAI()
    .generativeModel(
      model: model,
      generationConfig: GenerationConfig(
        responseModalities: [ResponseModalities.image],
        imageConfig: const ImageConfig(
          aspectRatio: ImageAspectRatio.landscape4x3,
          imageSize: ImageSize.size1K,
        ),
      ),
    )
    .generateContent([Content.text(prompt)]);

class FirebaseAiIllustrationGenerator implements IllustrationGenerator {
  FirebaseAiIllustrationGenerator({
    this.model = kIllustrationModel,
    ImageContentSender? send,
    this.timeout = const Duration(seconds: 90),
  }) : _send = send ?? _firebaseAiSend;

  @override
  final String model;
  final ImageContentSender _send;
  final Duration timeout;

  @override
  Future<GeneratedIllustration> generate(String prompt) async {
    final GenerateContentResponse response;
    try {
      response = await _send(model: model, prompt: prompt).timeout(timeout);
    } on TimeoutException {
      throw const IllustrationException(
        HybridErrorCode.timeout,
        'Image generation timed out',
      );
    } on QuotaExceeded {
      throw const IllustrationException(
        HybridErrorCode.quota,
        'Image quota used up',
      );
    } on FirebaseAIException catch (e) {
      throw IllustrationException(HybridErrorCode.failed, e.message);
    } on IllustrationException {
      rethrow;
    } catch (e) {
      throw IllustrationException(HybridErrorCode.network, '${e.runtimeType}');
    }
    return illustrationFromResponse(response, model: model);
  }
}

/// The first usable image in [response]. Anything else (no candidate, a
/// blocked prompt or candidate, a non-image part, bytes that are not the
/// image type they claim) throws: a malformed answer shows nothing.
GeneratedIllustration illustrationFromResponse(
  GenerateContentResponse response, {
  required String model,
}) {
  if (response.promptFeedback?.blockReason != null) {
    throw const IllustrationException(
      HybridErrorCode.blocked,
      'Prompt was blocked',
    );
  }
  final candidate = response.candidates.firstOrNull;
  if (candidate == null) {
    throw const IllustrationException(HybridErrorCode.failed, 'No candidate');
  }
  switch (candidate.finishReason) {
    case FinishReason.safety ||
        FinishReason.blocklist ||
        FinishReason.prohibitedContent ||
        FinishReason.spii ||
        FinishReason.recitation:
      throw const IllustrationException(
        HybridErrorCode.blocked,
        'Image was blocked',
      );
    default:
  }
  for (final part in response.inlineDataParts) {
    final mime = part.mimeType.toLowerCase();
    if (imageBytesMatch(mime, part.bytes)) {
      return GeneratedIllustration(
        bytes: part.bytes,
        mimeType: mime,
        model: model,
      );
    }
  }
  throw const IllustrationException(
    HybridErrorCode.failed,
    'Response held no usable image',
  );
}

/// Whether [bytes] start like the [mimeType] they claim (PNG, JPEG or WebP).
bool imageBytesMatch(String mimeType, Uint8List bytes) {
  if (bytes.length < 64) return false;
  bool starts(List<int> magic, [int offset = 0]) {
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  return switch (mimeType) {
    'image/png' => starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    'image/jpeg' => starts([0xFF, 0xD8, 0xFF]),
    'image/webp' =>
      starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8),
    _ => false,
  };
}
