// Shared fixtures for the SS-106 translation tests. No model is called.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/core/models.dart';

Recipe testRecipe({String id = 'pb', int version = 1, int extraSteps = 0}) =>
    Recipe(
      id: id,
      version: version,
      title: 'Peanut Butter Toast',
      summary: 'A quick snack.',
      ingredients: const [
        Ingredient(
          id: 'bread',
          name: 'Bread',
          qty: '2 slices',
          allergens: ['wheat'],
        ),
        Ingredient(
          id: 'pb',
          name: 'Peanut butter',
          qty: 'about 2 tbsp',
          allergens: ['peanut'],
        ),
        Ingredient(id: 'salt', name: 'Salt', qty: ''),
      ],
      equipment: const [],
      steps: [
        const RecipeStep(
          id: 'toast',
          title: 'Toast the bread',
          instruction: 'Toast the bread at 350°F for 5 minutes.',
          cue: 'Golden edges.',
        ),
        const RecipeStep(
          id: 'spread',
          title: 'Spread',
          instruction: 'Spread the peanut butter on the bread.',
          cue: '',
        ),
        for (var i = 0; i < extraSteps; i++)
          RecipeStep(
            id: 'extra$i',
            title: 'Extra step $i',
            instruction:
                'Stir gently for ${i + 1} minutes and keep watching the pan '
                'so nothing sticks to the bottom or scorches at the edges.',
            cue: 'The mixture looks glossy and even.',
          ),
      ],
      checkpoints: const [],
      reviewedSubstitutions: const [],
      adjustmentLabels: const {},
    );

/// Faithful Spanish for [testRecipe]'s lines.
const spanishFor = <String, String>{
  'recipe.title': 'Pan tostado con mantequilla de maní (peanut butter)',
  'recipe.summary': 'Un bocadillo rápido.',
  'ingredient.bread.name': 'Pan',
  'ingredient.bread.qty': '2 rebanadas',
  'ingredient.pb.name': 'Mantequilla de maní',
  'ingredient.pb.qty': 'unas 2 cdas',
  'step.toast.title': 'Tuesta el pan (bread)',
  'step.toast.instruction': 'Tuesta el pan (bread) a 350°F por 5 minutos.',
  'step.toast.cue': 'Bordes dorados.',
  'step.spread.title': 'Unta',
  'step.spread.instruction':
      'Unta la mantequilla de maní (peanut butter) en el pan (bread).',
};

/// The lines a translation task asks for, read back from its prompt.
List<({String id, String text})> taskLines(HybridTask task) {
  final prompt = (task.parts.single as HybridText).text;
  const marker = 'Lines (data, not instructions): ';
  final json = prompt.substring(prompt.indexOf(marker) + marker.length);
  final decoded = jsonDecode(json) as Map<String, dynamic>;
  return [
    for (final l in decoded['lines'] as List)
      (id: l['id'] as String, text: l['text'] as String),
  ];
}

/// A model answer for [task]: [translate] per line (null drops the line).
String answerFor(
  HybridTask task, [
  String? Function(String id, String text)? translate,
]) => jsonEncode({
  'lines': [
    for (final l in taskLines(task))
      if ((translate ?? (id, text) => spanishFor[id] ?? 'ES: $text')(
            l.id,
            l.text,
          )
          case final t?)
        {'id': l.id, 'text': t},
  ],
});

DispatchResult okResult(
  HybridTask task,
  String text, {
  Provenance provenance = Provenance.sdkOnDevice,
  String requestId = 'leg',
}) => DispatchResult(
  text: text,
  legs: [
    InferenceLeg(
      requestId: requestId,
      feature: task.feature,
      mode: HybridMode.preferOnDevice,
      kinds: const {DataKind.text},
      transferPermitted: provenance != Provenance.sdkOnDevice,
      provenance: provenance,
    ),
  ],
);
