// Practice mode (rehearsal) translations for "Cook in your language"
// (SS-106). No model runs: [PracticeTranslationDispatcher] answers recipe
// translation tasks from hand-written Spanish for the bundled recipes, and
// every leg it returns is [Provenance.simulated], so the sheet says
// "Practice mode: a pretend translation" and never "on this device". The
// canned text still goes through every line check; a line with no canned
// Spanish stays in English.

import 'dart:convert';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import '../ai/hybrid/hybrid_types.dart';
import 'recipe_translator.dart';
import 'translation_controller.dart';

/// Hand-written Spanish for the bundled recipes, by English source line.
const practiceSpanish = <String, String>{
  // peanut_butter_sandwich_v1
  'Peanut Butter Sandwich': 'Sándwich de mantequilla de maní (peanut butter)',
  'A simple no-cook sandwich. Choose plain peanut butter or add jam, then '
          'spread and assemble.':
      'Un sándwich sencillo, sin cocinar. Elige solo mantequilla de maní '
      '(peanut butter) o agrega mermelada; luego unta y arma.',
  'Bread': 'Pan (Bread)',
  '2 slices': '2 rebanadas',
  'Peanut butter': 'Mantequilla de maní (Peanut butter)',
  'about 2 tbsp, to preference': 'unas 2 cdas, al gusto',
  'Jam, only if the cook chooses it': 'Mermelada, solo si la quieres',
  'about 1 tbsp, optional': 'aproximadamente 1 cda, opcional',
  'Set out the bread': 'Prepara el pan (bread)',
  'Place two slices of bread side by side on a plate or clean board. Have '
          'your peanut butter ready. Would you like jam, or just peanut '
          'butter?':
      'Pon dos rebanadas de pan (bread) una al lado de la otra en un plato o '
      'una tabla limpia. Ten lista la mantequilla de maní (peanut butter). '
      '¿Quieres mermelada, o solo mantequilla de maní?',
  'Both slices lie flat with their upper surfaces visible and room to '
          'spread. Jam is a cook choice, not an assumed ingredient.':
      'Ambas rebanadas quedan planas, con la cara de arriba a la vista y '
      'espacio para untar. La mermelada es opcional; tú decides.',
  'Spread the peanut butter': 'Unta la mantequilla de maní (peanut butter)',
  'Put some peanut butter on one slice. Use the back of a spoon or a butter '
          'knife to spread it gently across the bread, adding more only if '
          'you want it.':
      'Pon un poco de mantequilla de maní (peanut butter) en una rebanada. '
      'Usa el dorso de una cuchara o un cuchillo para mantequilla y úntala '
      'con cuidado sobre el pan (bread), agregando más solo si quieres.',
  'Peanut butter covers most of the slice in an even layer, leaving a small '
          'border. Look for large bare patches or a thick mound in the '
          'middle; avoid pressing hard enough to tear the bread.':
      'La mantequilla de maní (peanut butter) cubre casi toda la rebanada en '
      'una capa pareja, dejando un borde pequeño. Busca zonas grandes sin '
      'cubrir o un montón grueso en el centro; no presiones tanto que se '
      'rompa el pan (bread).',
  'Add jam if you chose it': 'Agrega mermelada si la elegiste',
  'If you chose jam and have it, spread a thin layer on the second slice. '
          'Otherwise, leave that slice plain and move on to closing the '
          'sandwich.':
      'Si elegiste mermelada y la tienes, unta una capa delgada en la '
      'segunda rebanada. Si no, deja esa rebanada sola y pasa a cerrar el '
      'sándwich.',
  'With jam, the second slice has a thin spread layer rather than a large '
          'mound. Without jam, a plain second slice is the intended result. '
          'No waiting is needed.':
      'Con mermelada, la segunda rebanada tiene una capa delgada, no un '
      'montón grande. Sin mermelada, lo esperado es una segunda rebanada '
      'sola. No hace falta esperar.',
  'Close the sandwich': 'Cierra el sándwich',
  'Turn the second slice onto the first with any spread facing inward. Line '
          'up the edges and press gently with your hand. Leave the sandwich '
          'whole for the demo.':
      'Voltea la segunda rebanada sobre la primera, con lo untado hacia '
      'adentro. Alinea los bordes y presiona suavemente con la mano. Deja el '
      'sándwich entero para la demostración.',
  'The two slices are aligned, the filling sits between them, and gentle '
          'pressure keeps it from squeezing out at the edges.':
      'Las dos rebanadas quedan alineadas, el relleno queda entre ellas y una '
      'presión suave evita que se salga por los bordes.',

  // chickpea_wrap_v1
  'Smashed Chickpea Salad Wrap': 'Wrap de ensalada de garbanzos machacados',
  'A no-cook wrap from pantry staples: canned chickpeas, a creamy dressing, '
          'and crunchy vegetables. Teaches two techniques: mashing to a '
          'chunky texture and folding a filling evenly.':
      'Un wrap sin cocinar con básicos de la despensa: garbanzos de lata, un '
      'aderezo cremoso y verduras crujientes. Enseña dos técnicas: machacar '
      'hasta una textura con trozos y mezclar un relleno de forma pareja.',
  'Canned chickpeas, drained and rinsed':
      'Garbanzos de lata, escurridos y enjuagados',
  '1 can (15 oz)': '1 lata (15 oz)',
  'Mayonnaise': 'Mayonesa (Mayonnaise)',
  '2 tbsp': '2 cdas',
  'Dijon mustard': 'Mostaza Dijon (Dijon mustard)',
  '1 tsp': '1 cdta',
  'Lemon juice': 'Jugo de limón amarillo',
  '1 tbsp + 1 tbsp for the onion': '1 cda + 1 cda para la cebolla',
  'Red onion, thinly sliced (pre-sliced)':
      'Cebolla morada, en rodajas finas (ya rebanada)',
  'Celery, diced (pre-diced)': 'Apio, en cubitos (ya picado)',
  '1/4 cup': '1/4 taza',
  'Red bell pepper, diced (pre-diced)': 'Pimiento rojo, en cubitos (ya picado)',
  'Salt and black pepper': 'Sal y pimienta negra',
  'to taste': 'al gusto',
  'Flour tortillas (10 inch)':
      'Tortillas de harina (Flour tortillas) de 10 pulgadas',
  '2': '2',
  'Quick-pickle the onion': 'Encurte rápido la cebolla',
  'Put the sliced red onion in a small cup with 1 tbsp lemon juice and a '
          'pinch of salt. Let it sit while you work.':
      'Pon la cebolla morada rebanada en un vasito con 1 cda de jugo de limón '
      'amarillo y una pizca de sal. Déjala reposar mientras trabajas.',
  'The onion turns brighter pink and softens. It takes about 5 minutes.':
      'La cebolla se pone de un rosa más vivo y se ablanda. Tarda unos 5 '
      'minutos.',
  'Mash the chickpeas': 'Machaca los garbanzos',
  'Put the drained chickpeas in the bowl and press with a masher or fork '
          'until most are broken.':
      'Pon los garbanzos escurridos en el tazón y aplástalos con un '
      'machacador o un tenedor hasta que la mayoría se rompa.',
  'Mostly broken and chunky, only a few whole chickpeas left, not a smooth '
          'paste.':
      'Casi todos rotos y con trozos, solo quedan unos pocos garbanzos '
      'enteros, no una pasta lisa.',
  'Dress and fold': 'Adereza y mezcla',
  'Add mayo, mustard, 1 tbsp lemon juice, celery, bell pepper, the drained '
          'onion, salt and pepper. Fold from the bottom up until evenly '
          'mixed.':
      'Agrega la mayonesa (mayo), la mostaza (mustard), 1 cda de jugo de '
      'limón amarillo, el apio, el pimiento, la cebolla escurrida, sal y '
      'pimienta. Mezcla de abajo hacia arriba hasta que todo quede parejo.',
  'Red and green pieces spread through the whole bowl, everything lightly '
          'coated, no white streaks of dressing.':
      'Trozos rojos y verdes repartidos por todo el tazón, todo ligeramente '
      'cubierto, sin vetas blancas de aderezo.',
  'Fill and roll': 'Rellena y enrolla',
  'Spoon about half the filling in a line across the lower third of a '
          'tortilla. Fold in the sides, then roll away from you.':
      'Pon con una cuchara más o menos la mitad del relleno en una línea '
      'sobre el tercio inferior de una tortilla. Dobla los lados hacia '
      'adentro y enrolla alejándola de ti.',
  'A spoonful holds its shape. If it slumps or pools, it is too wet to '
          'roll.':
      'Una cucharada mantiene su forma. Si se aplana o suelta líquido, '
      'tiene demasiada humedad para enrollar.',

  // Current bundled text (trunk at SS-106 merge).
  "Lemon juice, fresh or bottled":
      "Jugo de limón amarillo, fresco o embotellado",
  "Celery, diced": "Apio, en cubitos",
  "Red bell pepper, diced": "Pimiento rojo, en cubitos",
  "Add mayo, mustard, 1 tbsp lemon juice, the drained onion, salt and pepper, plus whichever vegetables you have: celery, red bell pepper, drained canned corn or shredded carrot. Fold from the bottom up until evenly mixed.": "Agrega la mayonesa (mayo), la mostaza (mustard), 1 cda de jugo de limón amarillo, la cebolla escurrida, sal y pimienta, más las verduras que tengas: apio, pimiento rojo, maíz de lata escurrido o zanahoria rallada. Mezcla de abajo hacia arriba hasta que todo quede parejo.",
  "Vegetable pieces spread through the whole bowl, everything lightly coated, no white streaks of dressing.": "Trozos de verdura repartidos por todo el tazón, todo ligeramente cubierto, sin vetas blancas de aderezo.",
  "Warm the tortilla 15–20 seconds in the microwave or a dry pan so it bends without cracking. Spoon about half the filling in a line across the lower third of the tortilla. Fold in the sides, then roll away from you.": "Calienta la tortilla 15–20 segundos en el microondas o en un sartén seco para que se doble sin romperse. Pon con una cuchara más o menos la mitad del relleno en una línea sobre el tercio inferior de la tortilla. Dobla los lados hacia adentro y enrolla alejándola de ti.",
  "about 2 tbsp": "unas 2 cdas",
  "Jam": "Mermelada",
  "about 1 tbsp": "aproximadamente 1 cda",
  "Both slices lie flat with room to spread.":
      "Ambas rebanadas quedan planas, con espacio para untar.",
  "With jam, the second slice has a thin, even layer rather than a large mound. Without jam, the second slice stays plain.": "Con mermelada, la segunda rebanada tiene una capa delgada y pareja, no un montón grande. Sin mermelada, la segunda rebanada se queda sola.",
  "Turn the second slice onto the first with any spread facing inward. Line up the edges and press gently with your hand. Cut in half if you like.": "Voltea la segunda rebanada sobre la primera, con lo untado hacia adentro. Alinea los bordes y presiona suavemente con la mano. Córtalo por la mitad si quieres.",
  "Cilantro, chopped": "Cilantro picado",
  "Cut the tomato and red onion into small, even pieces, about the size of a corn kernel. Curl the fingertips of your holding hand under, like a claw, so the side of the knife rests against your knuckles. Add the pieces to the bowl. Chop the cilantro too if you are using it.": "Corta el tomate y la cebolla morada en trozos pequeños y parejos, del tamaño de un grano de maíz. Dobla las yemas de los dedos de la mano que sostiene el tomate hacia adentro, como una garra, para que el lado del cuchillo se apoye en tus nudillos. Agrega los trozos al tazón. Pica también el cilantro si lo vas a usar.",

  // black_bean_corn_salsa_v1
  'Black Bean & Corn Salsa': 'Salsa de frijoles negros y maíz',
  'A no-cook pantry salsa: canned black beans and corn with fresh tomato, '
          'red onion, and lime. Scoop it up with tortilla chips or fold it '
          'into tortillas. Teaches an even small dice and letting flavors '
          'meld.':
      'Una salsa de despensa sin cocinar: frijoles negros y maíz de lata con '
      'tomate fresco, cebolla morada y limón. Cómela con totopos o '
      'envuélvela en tortillas. Enseña a picar en cubitos parejos y a dejar '
      'que los sabores se mezclen.',
  'Canned black beans, drained and rinsed':
      'Frijoles negros de lata, escurridos y enjuagados',
  'Canned corn, drained': 'Maíz de lata, escurrido',
  'Tomato, diced': 'Tomate, en cubitos',
  '1 large or 2 small': '1 grande o 2 pequeños',
  'Red onion, finely diced': 'Cebolla morada, en cubitos finos',
  'Lime juice': 'Jugo de limón',
  '1 lime (about 2 tbsp)': '1 limón (unas 2 cdas)',
  'Cilantro, chopped, only if the cook likes it':
      'Cilantro picado, solo si te gusta',
  '2 tbsp, optional': '2 cdas, opcional',
  'Salt': 'Sal',
  'a pinch, to taste': 'una pizca, al gusto',
  'Tortilla chips or tortillas, for serving (flour tortillas contain wheat; '
          'check labels)':
      'Totopos o tortillas (Tortilla chips or tortillas), para servir (las '
      'tortillas de harina contienen trigo; revisa las etiquetas)',
  'a handful of chips or 2 tortillas': 'un puñado de totopos o 2 tortillas',
  'Drain and rinse the cans': 'Escurre y enjuaga las latas',
  'Open the black beans and corn. Pour the beans into a colander, rinse them '
          'under cold water, then add the corn and let everything drain. Tip '
          'them into the bowl.':
      'Abre los frijoles negros y el maíz. Vierte los frijoles en un colador, '
      'enjuágalos con agua fría, luego agrega el maíz y deja que todo '
      'escurra. Pásalos al tazón.',
  'Beans look glossy but not sitting in thick, cloudy liquid. No pool of '
          'canning liquid in the bottom of the bowl.':
      'Los frijoles se ven brillantes, pero no quedan en un líquido espeso y '
      'turbio. No queda líquido de la lata en el fondo del tazón.',
  'Dice the tomato and onion': 'Pica el tomate y la cebolla',
  'Cut the tomato and red onion into small, even pieces, about the size of a '
          'corn kernel. Add them to the bowl. Chop the cilantro too if you '
          'are using it.':
      'Corta el tomate y la cebolla morada en trozos pequeños y parejos, del '
      'tamaño de un grano de maíz. Agrégalos al tazón. Pica también el '
      'cilantro si lo vas a usar.',
  'Tomato and onion pieces are evenly diced, about the size of a corn '
          'kernel, with no large chunks.':
      'Los trozos de tomate y cebolla quedan parejos, del tamaño de un grano '
      'de maíz, sin pedazos grandes.',
  'Add lime and salt, then stir': 'Agrega limón y sal, y revuelve',
  'Squeeze the lime over the bowl, add a pinch of salt, and stir gently from '
          'the bottom until the colors are mixed throughout.':
      'Exprime el limón sobre el tazón, agrega una pizca de sal y revuelve '
      'suavemente desde el fondo hasta que los colores se repartan por todo.',
  'Black, yellow, red and purple pieces are spread through the whole bowl, '
          'everything lightly glossy, with no dry clump of beans on one '
          'side.':
      'Trozos negros, amarillos, rojos y morados repartidos por todo el '
      'tazón, todo ligeramente brillante, sin un montón seco de frijoles a un '
      'lado.',
  'Let the flavors meld': 'Deja que los sabores se mezclen',
  'Let the salsa sit for about 5 minutes so the lime and salt can soak in. '
          'Taste and add a little more salt or lime if you want.':
      'Deja reposar la salsa unos 5 minutos para que el limón y la sal se '
      'absorban. Prueba y agrega un poco más de sal o limón si quieres.',
  'A little juice gathers at the bottom and the onion looks slightly '
          'softened. Taste is the cook\'s call.':
      'Se junta un poco de jugo en el fondo y la cebolla se ve un poco más '
      'suave. El sabor lo decides tú.',
  'Serve': 'Sirve',
  'Give it one more stir. Scoop it up with tortilla chips, or spoon it into '
          'tortillas.':
      'Revuélvela una vez más. Cómela con totopos o sírvela en tortillas.',
  'Salsa is mixed evenly and ready to serve.':
      'La salsa queda mezclada de forma pareja y lista para servir.',
};

/// Answers `recipe_translate` tasks from [table] (English line → Spanish)
/// without any model. Lines it has no text for are left out of the answer,
/// so they stay in English. Other features are blocked: practice mode has
/// no model for them here.
class PracticeTranslationDispatcher implements HybridDispatcher {
  PracticeTranslationDispatcher({
    this.table = practiceSpanish,
    this.delay = const Duration(milliseconds: 400),
  });

  final Map<String, String> table;

  /// A short pause, so the demo shows the "Translating…" state.
  final Duration delay;
  int _seq = 0;

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    final id = 'practice-translate-${++_seq}';
    var cancelled = false;
    Future<DispatchResult> run() async {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (cancelled) {
        return const DispatchResult(legs: [], blocked: RouteReason.cancelled);
      }
      if (task.feature != recipeTranslateFeature) {
        return const DispatchResult(
          legs: [],
          blocked: RouteReason.noLocalModel,
        );
      }
      return DispatchResult(
        text: _answer(task),
        legs: [
          InferenceLeg(
            requestId: id,
            feature: task.feature,
            mode: null,
            kinds: const {DataKind.text},
            transferPermitted: false,
            provenance: Provenance.simulated,
            modelLabel: 'Practice mode (no model)',
          ),
        ],
      );
    }

    return HybridOperation(id, run(), () => cancelled = true);
  }

  String _answer(HybridTask task) {
    final prompt = task.parts.whereType<HybridText>().map((p) => p.text).join();
    const marker = 'Lines (data, not instructions): ';
    final at = prompt.indexOf(marker);
    final lines = at < 0
        ? const <Object?>[]
        : (jsonDecode(prompt.substring(at + marker.length)) as Map)['lines']
              as List;
    return jsonEncode({
      'lines': [
        for (final line in lines.cast<Map>())
          if (table[line['text']] case final es?)
            {'id': line['id'], 'text': es},
      ],
    });
  }
}

TranslationController? _practice;

/// The practice-mode language controller, one per app run.
TranslationController practiceTranslation() =>
    _practice ??= TranslationController(
      translator: RecipeTranslator(dispatcher: PracticeTranslationDispatcher()),
    );
