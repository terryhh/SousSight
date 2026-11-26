import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/illustrations/illustration_prompts.dart';
import 'package:soussight/illustrations/premade_illustrations.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

IllustrationTarget targetFor(String key) =>
    key == 'plate' ? const PlateTarget() : StepTarget(key.substring(5));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lookup: reviewed recipes only, known keys only', () {
    expect(
      premadeIllustrationAsset('chickpea_wrap_v1', const StepTarget('mash')),
      'assets/illustrations/chickpea_wrap_v1/step_mash.jpg',
    );
    expect(
      premadeIllustrationAsset('chickpea_wrap_v1', const PlateTarget()),
      'assets/illustrations/chickpea_wrap_v1/plate.jpg',
    );
    expect(
      premadeIllustrationAsset('chickpea_wrap_v1', const StepTarget('nope')),
      isNull,
    );
    expect(premadeIllustrationAsset('unknown', const PlateTarget()), isNull);
    // A draft never gets a shipped image, even if its id collides.
    expect(
      premadeIllustrationAsset('draft_chickpea_wrap_v1', const PlateTarget()),
      isNull,
    );
  });

  test('every indexed image exists, is listed in the manifest, and its '
      'prompt is what the builder makes today', () async {
    final manifest = jsonDecode(
      File('assets/illustrations/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(manifest['label'], kIllustrationLabel);
    final entries = {
      for (final e in (manifest['images'] as List).cast<Map<String, dynamic>>())
        '${e['recipe']}/${e['key']}': e,
    };
    final recipes = {for (final r in await loadRecipeCatalog()) r.id: r};
    final indexed = <String>{};
    for (final MapEntry(key: recipeId, value: keys)
        in kPremadeIllustrations.entries) {
      final recipe = recipes[recipeId]!;
      for (final key in keys) {
        indexed.add('$recipeId/$key');
        final target = targetFor(key);
        if (target case StepTarget(:final stepId)) {
          expect(recipe.steps.map((s) => s.id), contains(stepId));
        }
        final path = premadeIllustrationAsset(recipeId, target)!;
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: path);
        // Shipped images are small JPEGs.
        final bytes = file.readAsBytesSync();
        expect(bytes.take(3), [0xFF, 0xD8, 0xFF], reason: path);
        expect(bytes.length, lessThan(400 * 1024), reason: path);

        final entry = entries['$recipeId/$key'];
        expect(entry, isNotNull, reason: '$recipeId/$key not in manifest');
        expect(entry!['file'], '$recipeId/$key.jpg');
        expect(entry['model'], isNotEmpty);
        expect(DateTime.tryParse(entry['generatedAt'] as String), isNotNull);
        // 'prompt' records what was actually sent. If it was hand-tightened,
        // or the reviewed recipe
        // changed since, the entry must say so (and Terry re-approves or
        // regenerates); otherwise it must be exactly today's prompt.
        final today = illustrationPrompt(recipe, target)!.text;
        if (entry['promptOverride'] case final String reason) {
          // A recorded, hand-tightened prompt (tool/generate_illustrations.dart
          // promptOverrides): it must say why and keep the house style.
          expect(reason, isNotEmpty);
          expect(entry['prompt'], endsWith(kIllustrationStyle));
          expect(entry['prompt'], isNot(today));
        } else if (entry['recipeChangedSinceGeneration']
            case final String note) {
          expect(note, contains('Re-approve or regenerate'));
          expect(entry['prompt'], isNot(today), reason: '$recipeId/$key');
        } else {
          expect(
            entry['prompt'],
            today,
            reason: 'prompt for $recipeId/$key changed since generation',
          );
        }
      }
    }
    expect(entries.keys.toSet(), indexed);
    // Within the approved budget of about 15.
    expect(indexed.length, lessThanOrEqualTo(15));
  });
}
