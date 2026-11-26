// SS-075 watch evaluation, run by a person on the device under test:
//
//   flutter run -t tool/hybrid_eval/main_watch_eval.dart -d chrome \
//     --dart-define=GIT_SHA=$(git rev-parse --short HEAD)
//
// Needs assets/reference-cooking/ declared in pubspec.yaml (see EVIDENCE.md).
// No cloud route is approved here, and the policy forces `local_watch`
// on-device, so photos are checked only by the on-device model. The report
// still counts uploads from the inference legs rather than assuming that.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/app/hybrid_runtime.dart';
import 'package:soussight/data/firebase_services.dart';

import 'watch_eval.dart';
import 'watch_eval_app.dart';
import 'watch_eval_runner.dart';

const _buildSha = String.fromEnvironment('GIT_SHA', defaultValue: 'unknown');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initFirebase();
  final runtime = HybridRuntime.create(cloudRoutes: const CloudRoutes({}));
  Future<Uint8List> load(String path) async =>
      (await rootBundle.load(path)).buffer.asUint8List();
  final fixtures = parseWatchFixtures(
    await rootBundle.loadString('assets/reference-cooking/fixtures.json'),
  );
  final steps = recipeStepsById(
    await rootBundle.loadString('assets/recipes/chickpea_wrap_v1.json'),
  );
  runApp(
    MaterialApp(
      navigatorKey: runtime.navigatorKey,
      debugShowCheckedModeBanner: false,
      home: WatchEvalScreen(
        fixtures: fixtures,
        runner: WatchEvalRunner(
          dispatcher: runtime.dispatcher,
          loadAsset: load,
          steps: steps,
        ),
        loadAsset: load,
        buildSha: _buildSha,
        platform: describePlatform(),
      ),
    ),
  );
}
