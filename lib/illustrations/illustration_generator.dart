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
import 'dart:ui' as ui;

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
/// blocked prompt or candidate, a finish other than STOP, a non-image part,
/// bytes that are not the image type they claim) throws: a malformed answer
/// shows nothing. The caller still decodes the bytes before showing them
/// ([imageDecodes]).
GeneratedIllustration illustrationFromResponse(
  GenerateContentResponse response, {
  required String model,
}) {
  final feedback = response.promptFeedback;
  if (feedback?.blockReason != null ||
      (feedback?.safetyRatings ?? const []).any((r) => r.isBlocked == true)) {
    throw const IllustrationException(
      HybridErrorCode.blocked,
      'Prompt was blocked',
    );
  }
  // Exactly one candidate: a second one is not "the" image asked for.
  if (response.candidates.length != 1) {
    throw IllustrationException(
      HybridErrorCode.failed,
      'Expected one candidate, got ${response.candidates.length}',
    );
  }
  final candidate = response.candidates.single;
  // Only a normal finish may show an image: every block, including the
  // image-specific ones, is "blocked", and anything else (no reason, cut
  // short, no image, unknown) abstains.
  switch (candidate.finishReason) {
    case FinishReason.stop:
      break;
    case FinishReason.safety ||
        FinishReason.blocklist ||
        FinishReason.prohibitedContent ||
        FinishReason.spii ||
        FinishReason.recitation ||
        FinishReason.imageSafety ||
        FinishReason.imageProhibitedContent ||
        FinishReason.imageRecitation:
      throw const IllustrationException(
        HybridErrorCode.blocked,
        'Image was blocked',
      );
    case final reason:
      throw IllustrationException(
        HybridErrorCode.failed,
        'Generation did not finish normally (${reason?.name ?? 'no reason'})',
      );
  }
  // An explicit block flag wins over a contradictory STOP.
  if ((candidate.safetyRatings ?? const []).any((r) => r.isBlocked == true)) {
    throw const IllustrationException(
      HybridErrorCode.blocked,
      'Image was blocked',
    );
  }
  // The image-only contract: every non-thought part is one well-formed
  // image (blank text is tolerated), and there is exactly one. Anything
  // else in the answer means it is not what was asked for: abstain.
  GeneratedIllustration? found;
  for (final part in candidate.content.parts) {
    if (part.isThought == true) continue;
    switch (part) {
      case TextPart(:final text) when text.trim().isEmpty:
        continue;
      case InlineDataPart(:final mimeType, :final bytes)
          when found == null && imageBytesMatch(mimeType.toLowerCase(), bytes):
        found = GeneratedIllustration(
          bytes: bytes,
          mimeType: mimeType.toLowerCase(),
          model: model,
        );
      default:
        throw const IllustrationException(
          HybridErrorCode.failed,
          'Response was not a single image',
        );
    }
  }
  if (found == null) {
    throw const IllustrationException(
      HybridErrorCode.failed,
      'Response held no usable image',
    );
  }
  return found;
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

/// Whether [bytes] decode to an image with at least one pixel. A valid
/// signature followed by garbage fails here, so it is never shown as ready.
Future<bool> imageDecodes(Uint8List bytes) async {
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final ok = frame.image.width > 0 && frame.image.height > 0;
    frame.image.dispose();
    return ok;
  } catch (_) {
    return false;
  } finally {
    codec?.dispose();
  }
}
