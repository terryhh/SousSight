// Canned practice-mode Spanish (SS-106): every bundled recipe translates in
// full through the same line checks, and every leg says "simulated".

import 'dart:convert';
import 'dart:io';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/translate/cook_language.dart';
import 'package:soussight/translate/practice_translation.dart';
import 'package:soussight/translate/recipe_translator.dart';
import 'package:soussight/translate/translation_guard.dart';

import 'translate_fixtures.dart';

void main() {
  final bundled = [
    for (final f in Directory('assets/recipes').listSync().whereType<File>())
      if (f.path.endsWith('.json'))
        Recipe.fromMap(
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
        ),
  ];

  test('there are bundled recipes to cover', () {
    expect(bundled.length, greaterThanOrEqualTo(3));
  });

  for (final recipe in bundled) {
    test('${recipe.id}: every sent line translated and checked', () async {
      final t = await RecipeTranslator(
        dispatcher: PracticeTranslationDispatcher(delay: Duration.zero),
      ).translate(recipe, spanish, sessionId: 'practice');
      // Only the reviewed safety/allergen/timing lines stay in English;
      // every other line has canned Spanish that passes the checks.
      final kept = [
        for (final l in t.lines.values)
          if (l.kept && l.rejection != LineRejection.reviewedEnglish)
            '${l.id}: ${l.rejection}',
      ];
      expect(kept, isEmpty);
      final untranslated = [
        for (final l in t.lines.values)
          if (!l.kept && !practiceSpanish.containsKey(l.original)) l.id,
      ];
      expect(untranslated, isEmpty, reason: 'every sent line is canned');
      expect(t.status, TranslationStatus.complete);
      expect(t.legs, isNotEmpty);
      for (final leg in t.legs) {
        expect(leg.provenance, Provenance.simulated);
        expect(leg.transferPermitted, isFalse);
      }
    });
  }

  test('a line with no canned Spanish stays in English', () async {
    final t = await RecipeTranslator(
      dispatcher: PracticeTranslationDispatcher(delay: Duration.zero),
    ).translate(testRecipe(), spanish, sessionId: 'practice');
    // "Bread" is canned; "Toast the bread" is not, so the practice answer
    // gives it back as written, and the allergen check keeps the original.
    expect(t.text(RecipeLineIds.ingredientName('bread'), 'x'), 'Pan (Bread)');
    expect(t.isKept(RecipeLineIds.stepTitle('toast')), isTrue);
  });

  test('other features are not answered; cancel wins', () async {
    final d = PracticeTranslationDispatcher(delay: Duration.zero);
    final other = await d
        .start(
          const HybridTask(
            feature: 'coach_lite',
            parts: [HybridText('q')],
            maxOutputTokens: 10,
            timeout: Duration(seconds: 1),
          ),
          sessionId: 's',
        )
        .result;
    expect(other.ok, isFalse);
    expect(other.blocked, RouteReason.noLocalModel);

    final slow = PracticeTranslationDispatcher(
      delay: const Duration(milliseconds: 5),
    );
    final op = slow.start(
      translationTask(
        recipeSourceLines(testRecipe()).take(1).toList(),
        spanish,
        const [],
      ),
      sessionId: 's',
    );
    op.cancel();
    expect((await op.result).blocked, RouteReason.cancelled);
  });

  test('a task without the lines marker gets an empty answer', () async {
    final r = await PracticeTranslationDispatcher(delay: Duration.zero)
        .start(
          const HybridTask(
            feature: recipeTranslateFeature,
            parts: [HybridText('nothing here')],
            maxOutputTokens: 10,
            timeout: Duration(seconds: 1),
          ),
          sessionId: 's',
        )
        .result;
    expect(jsonDecode(r.text!), {'lines': <Object?>[]});
  });

  test('one practice controller per app run', () {
    expect(identical(practiceTranslation(), practiceTranslation()), isTrue);
  });
}
