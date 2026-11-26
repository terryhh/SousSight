import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show HybridErrorCode;
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/illustrations/illustration_generator.dart';

Uint8List png() => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ...List.filled(80, 1),
]);

Uint8List jpeg() =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(80, 2)]);

Uint8List webp() => Uint8List.fromList([
  0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, //
  ...List.filled(80, 3),
]);

GenerateContentResponse response(
  List<Part> parts, {
  FinishReason? finish = FinishReason.stop,
  PromptFeedback? feedback,
  bool noCandidate = false,
}) => GenerateContentResponse(
  noCandidate
      ? const []
      : [Candidate(Content('model', parts), null, null, finish, null)],
  feedback,
);

FirebaseAiIllustrationGenerator generatorReturning(
  FutureOr<GenerateContentResponse> Function() answer, {
  List<String>? prompts,
  Duration timeout = const Duration(seconds: 5),
}) => FirebaseAiIllustrationGenerator(
  model: 'test-image-model',
  timeout: timeout,
  send: ({required model, required prompt}) async {
    expect(model, 'test-image-model');
    prompts?.add(prompt);
    return answer();
  },
);

Future<HybridErrorCode> failureOf(FirebaseAiIllustrationGenerator g) async {
  try {
    await g.generate('p');
  } on IllustrationException catch (e) {
    return e.code;
  }
  fail('expected an IllustrationException');
}

void main() {
  test('defaults: model id and cap are configurable defines', () {
    expect(kIllustrationModel, 'gemini-nano-banana-2.1');
    expect(kIllustrationSessionCap, 4);
    expect(illustrationModelLabel('m'), 'm (text→image)');
    expect(FirebaseAiIllustrationGenerator().model, kIllustrationModel);
  });

  test('returns the first image part whose bytes match its type', () async {
    final prompts = <String>[];
    final g = generatorReturning(
      () => response([
        const TextPart('here you go'),
        InlineDataPart('image/png', jpeg()), // lies about its type
        InlineDataPart('IMAGE/JPEG', jpeg()),
      ]),
      prompts: prompts,
    );
    final image = await g.generate('draw a bowl');
    expect(prompts, ['draw a bowl']);
    expect(image.mimeType, 'image/jpeg');
    expect(image.model, 'test-image-model');
    expect(image.bytes, jpeg());
  });

  test('accepts png and webp', () {
    for (final (mime, bytes) in [
      ('image/png', png()),
      ('image/webp', webp()),
    ]) {
      final image = illustrationFromResponse(
        response([InlineDataPart(mime, bytes)]),
        model: 'm',
      );
      expect(image.mimeType, mime);
    }
  });

  test('malformed or missing images abstain', () {
    final cases = <GenerateContentResponse>[
      response(const [TextPart('no image')]),
      response([InlineDataPart('image/png', Uint8List(10))]), // too short
      response([InlineDataPart('image/gif', png())]), // unsupported type
      response([InlineDataPart('text/plain', png())]),
      response(const [], noCandidate: true),
    ];
    for (final r in cases) {
      expect(
        () => illustrationFromResponse(r, model: 'm'),
        throwsA(
          isA<IllustrationException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.failed,
          ),
        ),
      );
    }
  });

  test('blocked prompts and candidates report blocked', () {
    for (final finish in [
      FinishReason.safety,
      FinishReason.blocklist,
      FinishReason.prohibitedContent,
      FinishReason.spii,
      FinishReason.recitation,
    ]) {
      expect(
        () => illustrationFromResponse(
          response([InlineDataPart('image/png', png())], finish: finish),
          model: 'm',
        ),
        throwsA(
          isA<IllustrationException>().having(
            (e) => e.code,
            'code',
            HybridErrorCode.blocked,
          ),
        ),
      );
    }
    expect(
      () => illustrationFromResponse(
        response(
          const [],
          noCandidate: true,
          feedback: PromptFeedback(BlockReason.safety, null, const []),
        ),
        model: 'm',
      ),
      throwsA(
        isA<IllustrationException>().having(
          (e) => e.code,
          'code',
          HybridErrorCode.blocked,
        ),
      ),
    );
  });

  test('errors map to ledger codes', () async {
    expect(
      await failureOf(generatorReturning(() => throw QuotaExceeded('q'))),
      HybridErrorCode.quota,
    );
    expect(
      await failureOf(generatorReturning(() => throw ServerException('s'))),
      HybridErrorCode.failed,
    );
    expect(
      await failureOf(generatorReturning(() => throw StateError('x'))),
      HybridErrorCode.network,
    );
    expect(
      await failureOf(
        generatorReturning(
          () => throw const IllustrationException(HybridErrorCode.blocked, 'b'),
        ),
      ),
      HybridErrorCode.blocked,
    );
    final slow = generatorReturning(
      () => Completer<GenerateContentResponse>().future,
      timeout: const Duration(milliseconds: 10),
    );
    expect(await failureOf(slow), HybridErrorCode.timeout);
    expect(
      const IllustrationException(HybridErrorCode.failed, 'x').toString(),
      contains('failed'),
    );
  });
}
