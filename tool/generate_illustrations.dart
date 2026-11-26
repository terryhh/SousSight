// Generates SousSight's pre-made step and plate illustrations (SS-098), and
// runs the one-image on-demand gate. A Flutter WEB entry point: it initializes
// Firebase and App Check exactly as the app does and calls Firebase AI Logic
// from the browser, so a local run needs an App Check debug token passed at
// build time. It is never deployed and never part of the app bundle.
//
// Driven by tool/generate_illustrations.mjs, which builds this target, serves
// it on localhost, reads the images this page prints to the console, and
// writes assets/illustrations/** and its manifest. Nothing is generated
// unless ILLUSTRATION_MAX is above zero (or ILLUSTRATION_GATE=true), and the
// run stops at the first error of any kind: no retries.
//
// Defines:
//   ILLUSTRATION_MAX      most images to generate (default 0 = none)
//   ILLUSTRATION_TARGETS  optional comma list of recipeId/key to limit the run
//   ILLUSTRATION_MODEL    image model (lib/illustrations/illustration_generator)
//   ILLUSTRATION_GATE     true: run the on-demand gate instead (one image,
//                         through the production controller, consent dialog,
//                         ledger and widget, for a synthetic AI-drafted recipe)
//   APPCHECK_DEBUG_TOKEN  local runs only; never commit, print or deploy it

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/app/cloud_send_recorder.dart';
import 'package:soussight/app/hybrid_runtime.dart' show DialogConsentGate;
import 'package:soussight/app/online_status.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/data/firebase_services.dart';
import 'package:soussight/illustrations/illustration_controller.dart';
import 'package:soussight/illustrations/illustration_generator.dart';
import 'package:soussight/illustrations/illustration_panel.dart';
import 'package:soussight/illustrations/illustration_prompts.dart';
import 'package:soussight/illustrations/premade_illustrations.dart';
import 'package:soussight/pantry/recipe_catalog.dart';
import 'package:soussight/trust/privacy_preferences.dart';

const _max = int.fromEnvironment('ILLUSTRATION_MAX');
const _only = String.fromEnvironment('ILLUSTRATION_TARGETS');
const _gate = bool.fromEnvironment('ILLUSTRATION_GATE');

void _emit(String tag, Map<String, Object?> data) =>
    // ignore: avoid_print
    print('$tag ${jsonEncode(data)}');

/// A synthetic AI-drafted recipe for the gate. No-cook and no animal
/// protein, so its step may be pictured.
const gateRecipe = Recipe(
  id: 'draft_gate_cucumber_yogurt_dip',
  version: 1,
  title: 'Cucumber Yogurt Dip',
  summary: 'A quick no-cook dip.',
  ingredients: [
    Ingredient(id: 'yogurt', name: 'Plain yogurt', qty: '1 cup'),
    Ingredient(id: 'cucumber', name: 'Cucumber, grated', qty: '1/2'),
    Ingredient(id: 'lemon', name: 'Lemon juice', qty: '1 tsp'),
    Ingredient(id: 'salt', name: 'Salt', qty: 'pinch'),
  ],
  equipment: ['Bowl', 'Grater'],
  steps: [
    RecipeStep(
      id: 'stir',
      title: 'Stir it together',
      instruction:
          'Squeeze the grated cucumber, then stir it into the yogurt '
          'with the lemon juice and salt.',
      cue:
          'Pale green flecks of cucumber spread evenly through thick white '
          'yogurt, with no watery pool on top.',
    ),
  ],
  checkpoints: [],
  reviewedSubstitutions: [],
  adjustmentLabels: {},
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _GeneratorApp());
}

class _GeneratorApp extends StatefulWidget {
  const _GeneratorApp();
  @override
  State<_GeneratorApp> createState() => _GeneratorAppState();
}

class _GeneratorAppState extends State<_GeneratorApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  String _status = 'Starting Firebase…';
  IllustrationController? _gateController;
  InferenceLedger? _ledger;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await initFirebase();
    } catch (e) {
      _emit('ILLUSTRATION_ERROR', {'stage': 'firebase', 'error': '$e'});
      setState(() => _status = 'Firebase failed');
      return;
    }
    if (_gate) {
      _startGate();
    } else {
      await _generatePremade();
    }
  }

  Future<void> _generatePremade() async {
    final only = {
      for (final t in _only.split(','))
        if (t.trim().isNotEmpty) t.trim(),
    };
    final recipes = await loadRecipeCatalog();
    final generator = FirebaseAiIllustrationGenerator();
    var made = 0;
    for (final recipe in recipes) {
      for (final key in kPremadeIllustrations[recipe.id] ?? const <String>{}) {
        if (only.isNotEmpty && !only.contains('${recipe.id}/$key')) continue;
        if (made >= _max) break;
        final target = key == 'plate'
            ? const PlateTarget()
            : StepTarget(key.substring('step_'.length));
        final prompt = illustrationPrompt(recipe, target);
        if (prompt == null) {
          _emit('ILLUSTRATION_SKIP', {'recipe': recipe.id, 'key': key});
          continue;
        }
        made++;
        setState(() => _status = 'Generating ${recipe.id}/$key ($made)…');
        final started = DateTime.now().toUtc();
        try {
          final image = await generator.generate(prompt.text);
          _emit('ILLUSTRATION', {
            'recipe': recipe.id,
            'key': key,
            'subject': prompt.subject.name,
            'prompt': prompt.text,
            'model': image.model,
            'mimeType': image.mimeType,
            'generatedAt': started.toIso8601String(),
            'bytes': base64Encode(image.bytes),
          });
        } on IllustrationException catch (e) {
          // Stop at once, whatever the error: never retry a paid call.
          _emit('ILLUSTRATION_ERROR', {
            'recipe': recipe.id,
            'key': key,
            'code': e.code.name,
            'error': e.message,
          });
          setState(() => _status = 'Stopped on error');
          return;
        }
      }
    }
    _emit('ILLUSTRATION_DONE', {'calls': made});
    setState(() => _status = 'Done: $made call(s)');
  }

  void _startGate() {
    final ledger = InferenceLedger(sessionId: 'illustration-gate');
    final controller = IllustrationController(
      cloudRoutes: CloudRoutes.parse('images'),
      privacy: InMemoryPrivacyPreferences(),
      isOnline: deviceOnline,
      consent: DialogConsentGate(
        navigatorKey: _navigatorKey,
        cloudModel: kIllustrationModel,
      ),
      recorder: LedgerCloudSendRecorder(ledger),
      generator: FirebaseAiIllustrationGenerator(),
      cap: 1,
    );
    ledger.addListener(() {
      final legs = [
        for (final e in ledger.entries)
          {
            'feature': e.leg.feature,
            'kinds': [for (final k in e.leg.kinds) k.name],
            'transferPermitted': e.leg.transferPermitted,
            'provenance': e.leg.provenance.name,
            'modelLabel': e.leg.modelLabel,
            'error': e.leg.error?.name,
            'pending': e.pending,
          },
      ];
      _emit('ILLUSTRATION_GATE_LEDGER', {'legs': legs});
    });
    controller.addListener(() {
      final state = controller.stateFor(const StepTarget('stir'));
      _emit('ILLUSTRATION_GATE_STATE', {
        'state': state.runtimeType.toString(),
        'used': controller.used,
        if (state is IllustrationFailed) 'code': state.code.name,
        if (state is IllustrationReady) 'bytes': state.image.bytes.length,
      });
    });
    setState(() {
      _ledger = ledger;
      _gateController = controller;
      _status = 'Gate ready';
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Illustration tool · $_status'),
            if (_gateController case final controller?) ...[
              const SizedBox(height: 16),
              Text('Recipe: ${gateRecipe.title} (AI-drafted, synthetic)'),
              Text(gateRecipe.steps.single.cue),
              StepIllustrations(
                recipe: gateRecipe,
                step: gateRecipe.steps.single,
                sessionId: 'illustration-gate',
                showPlate: false,
                createController: () => controller,
              ),
              if (_ledger case final ledger?)
                ListenableBuilder(
                  listenable: ledger,
                  builder: (_, _) =>
                      Text('Ledger legs: ${ledger.entries.length}'),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}
