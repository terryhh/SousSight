import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart' show HybridErrorCode;
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/illustrations/illustration_ledger.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/illustrations/illustration_controller.dart';
import 'package:soussight/illustrations/illustration_generator.dart';
import 'package:soussight/trust/privacy_preferences.dart';

/// A tiny valid PNG header plus padding: enough for the magic-byte check.
final fakePng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ...List.filled(120, 7),
]);

class FakeGenerator implements IllustrationGenerator {
  FakeGenerator({Uint8List? bytes}) : bytes = bytes ?? fakePng;
  final Uint8List bytes;
  final List<String> prompts = [];
  final List<Completer<GeneratedIllustration>> pending = [];
  bool hold = false;
  Object? error;

  @override
  String get model => 'fake-image-model';

  @override
  Future<GeneratedIllustration> generate(String prompt) {
    prompts.add(prompt);
    if (error case final e?) return Future.error(e);
    final image = GeneratedIllustration(
      bytes: bytes,
      mimeType: 'image/png',
      model: model,
    );
    if (!hold) return Future.value(image);
    final c = Completer<GeneratedIllustration>();
    pending.add(c);
    return c.future;
  }

  void release() {
    for (final c in pending) {
      c.complete(
        GeneratedIllustration(
          bytes: bytes,
          mimeType: 'image/png',
          model: model,
        ),
      );
    }
    pending.clear();
  }
}

class FakeConsent implements ConsentGate {
  final List<ConsentAsk> asks = [];
  bool allow = true;
  Completer<void>? gate;
  Object? error;

  /// Runs while the prompt is "open", before the answer.
  void Function()? whileOpen;

  /// Answer with a grant for some other ask.
  ConsentAsk? forge;

  @override
  Future<ConsentGrant?> request(ConsentAsk ask) async {
    asks.add(ask);
    if (gate case final g?) await g.future;
    whileOpen?.call();
    if (error case final e?) throw e;
    if (!allow) return null;
    return ConsentGrant(forge ?? ask);
  }
}

class Harness {
  Harness({
    Set<CloudRoute> routes = const {CloudRoute.images},
    Set<String> localOnly = const {},
    int cap = 4,
    IllustrationUsage? usage,
  }) : routes = CloudRoutes(routes),
       privacy = InMemoryPrivacyPreferences(localOnly) {
    controller = IllustrationController(
      cloudRoutes: this.routes,
      privacy: privacy,
      isOnline: () => online,
      consent: consent,
      ledger: InferenceLedgerIllustrations(ledger),
      generator: generator,
      cap: cap,
      usage: usage,
      decodes: (bytes) async {
        decoded.add(bytes);
        return decodes;
      },
    );
  }

  /// What the fake decoder answers; real decoding is tested separately.
  bool decodes = true;
  final List<Uint8List> decoded = [];

  final CloudRoutes routes;
  final InMemoryPrivacyPreferences privacy;
  bool online = true;
  final consent = FakeConsent();
  final generator = FakeGenerator();
  final ledger = InferenceLedger(sessionId: 'run-1');
  late final IllustrationController controller;
}

Recipe draftRecipe({
  String id = 'draft_abc',
  List<RecipeStep>? steps,
  List<Ingredient>? ingredients,
}) => Recipe(
  id: id,
  version: 1,
  title: 'Cucumber Dip',
  summary: '',
  ingredients:
      ingredients ??
      const [
        Ingredient(id: 'y', name: 'Yogurt', qty: '1 cup'),
        Ingredient(id: 'c', name: 'Cucumber', qty: '1'),
      ],
  equipment: const [],
  steps:
      steps ??
      const [
        RecipeStep(
          id: 'grate',
          title: 'Grate',
          instruction: 'Grate the cucumber.',
          cue: 'Fine shreds of cucumber.',
        ),
        RecipeStep(
          id: 'stir',
          title: 'Stir',
          instruction: 'Stir the cucumber into the yogurt.',
          cue: 'Pale green flecks through white yogurt.',
        ),
      ],
  checkpoints: const [],
  reviewedSubstitutions: const [],
  adjustmentLabels: const {},
);

HybridErrorCode? lastLegError(InferenceLedger ledger) =>
    ledger.entries.last.leg.error;
