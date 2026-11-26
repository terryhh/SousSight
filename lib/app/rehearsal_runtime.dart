// Practice mode (rehearsal, `FAKE_BACKEND=true`) hybrid runtime (SS-089).
//
// Rehearsal builds get the same HybridRuntime wiring as real builds, so the
// pantry scan, typed questions, the on-device watch, the label check and the
// trust sheets all run end to end in demos and browser checks. Every answer
// comes from [RehearsalHybridInference], a scripted FakeHybridInference: no
// model runs and nothing leaves the browser. The fake reports `onDevice` (so
// the dispatcher's on-device-only paths work), and [SimulatedDispatcher] and
// [SimulatedInferenceLedger] restamp every finished leg as
// [Provenance.simulated], so every surface says "Practice mode (pretend
// answers)" and never claims a real on-device run.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/material.dart';

import '../ai/hybrid/hybrid_dispatcher.dart';
import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_ledger.dart';
import '../core/models.dart';
import '../learner/demo_live.dart';
import '../live/live_types.dart';
import '../pantry/pantry_client.dart';
import '../pantry/pantry_models.dart';
import '../pantry/recipe_draft.dart';
import '../pantry/pantry_ui.dart' show pantrySameItem, pantryTypedEntries;
import '../trust/privacy_preferences.dart';
import '../label/label_check.dart' show kLabelAllergens, kLabelCheckFeature;
import '../watch/watch_verdict.dart' show kLocalWatchFeature;
import 'hybrid_runtime.dart';

/// What the trust sheets call the practice "model". Never a real model name.
const kPracticeModelFamily = 'Practice mode (no model)';

/// Capabilities reported in practice mode: text and photos "work", so every
/// feature can be rehearsed. The sheets label all of it as pretend.
const practiceCapabilities = HybridCapabilities(
  platform: 'web',
  local: LocalModelLimits(
    modelFamily: kPracticeModelFamily,
    supportsImage: true,
    supportsJsonSchema: true,
    maxTotalTokens: 9216,
    defaultOutputReserve: 512,
    imageTokenEstimate: 1000,
    validatedLanguages: ['en'],
  ),
  supportedModes: {HybridMode.preferOnDevice, HybridMode.onlyOnDevice},
);

/// True for the practice-mode runtime (rehearsal builds).
bool isPracticeRuntime(HybridRuntime? hybrid) =>
    hybrid is RehearsalHybridRuntime;

// ---------------------------------------------------------------- inference

/// A [FakeHybridInference] that writes a plausible, clearly pretend answer
/// for each feature, built from the request itself:
/// - `pantry_scan`: the items the cook typed, matched against the catalog;
/// - `coach_lite`: a short practice answer about the current step;
/// - `local_watch`: verdicts cycling not_yet → unsure → ready;
/// - `label_check`: allergens named in a typed label (photos: unreadable).
/// Anything else fails as unavailable.
class RehearsalHybridInference extends FakeHybridInference {
  RehearsalHybridInference({
    Duration answerDelay = const Duration(milliseconds: 500),
  }) : super(capabilities: practiceCapabilities) {
    delay = answerDelay;
  }

  int _watchTurn = 0;

  /// A new practice watch starts its verdicts from "not yet" (Codex #221).
  /// Called when the practice camera starts a capture.
  void newWatch() => _watchTurn = 0;

  @override
  Future<HybridResult> generate(HybridRequest request) {
    // Reserved synchronously by super.generate, so concurrent calls each get
    // the answer built for their own request.
    script.add((HybridRequest r) => _answer(r));
    final result = super.generate(request);
    // The user-facing runtime keeps no copies of requests (photos, typed
    // questions, label text) for the app run (Codex #221). A cancellation
    // record is dropped only once its own request has settled.
    requests.clear();
    unawaited(
      result
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => cancelled.remove(request.requestId)),
    );
    return result;
  }

  Object _answer(HybridRequest request) {
    final task = request.task;
    final text = [
      for (final part in task.parts)
        if (part case HybridText(:final text)) text,
    ];
    final String? answer = switch (task.feature) {
      kPantryScanFeature => practicePantryAnswer(
        text.isEmpty ? '' : text.first,
      ),
      'coach_lite' => practiceCoachAnswer(text.join('\n')),
      kLocalWatchFeature => practiceWatchAnswer(
        _watchTurn++,
        cue: _promptLine(text.join('\n'), 'Visible cue to look for'),
      ),
      kLabelCheckFeature => practiceLabelAnswer(text.join('\n')),
      _ => null,
    };
    if (answer == null) {
      return const HybridException(
        HybridErrorCode.unavailable,
        'Not part of practice mode',
      );
    }
    return HybridResult(
      requestId: request.requestId,
      text: answer,
      source: InferenceSource.onDevice,
    );
  }
}

/// The cook's typed list as short item names, in order, without duplicates.
List<String> practiceTypedItems(String typed) {
  final seen = <String>{};
  return [
    for (final name in pantryTypedEntries(typed))
      if (name.length <= 40 && seen.add(name)) name,
  ].take(kPantryMaxItems).toList();
}

/// Whether the cook's typed [item] IS the catalog [ingredient]: the same
/// food by identity, never a shared word ("sunflower seed butter" is not
/// "peanut butter"). Only the name before the first comma counts, without
/// notes in brackets; "X or Y" and "X and Y" offer each part.
bool practiceHasIngredient(String item, String ingredient) =>
    practiceIngredientMatch([item], ingredient) != null;

/// The typed items that make up [ingredient], or null when they don't.
/// "X or Y" accepts either alternative; "X and Y" needs every part
/// ("Salt and black pepper" needs both, Codex #221).
List<String>? practiceIngredientMatch(List<String> typed, String ingredient) {
  final head = ingredient
      .split(',')
      .first
      .replaceAll(RegExp(r'\([^)]*\)'), ' ')
      .toLowerCase();
  for (final alternative in head.split(RegExp(r'\s+or\s+'))) {
    // The whole name typed as one item ("salt and black pepper").
    final whole = typed
        .where((t) => pantrySameItem(t, alternative))
        .firstOrNull;
    if (whole != null) return [whole];
    final used = <String>[];
    var all = true;
    for (final part in alternative.split(RegExp(r'\s+and\s+'))) {
      final hit = typed.where((t) => pantrySameItem(t, part)).firstOrNull;
      if (hit == null) {
        all = false;
        break;
      }
      used.add(hit);
    }
    if (all && used.isNotEmpty) return used;
  }
  return null;
}

/// A pantry-scan JSON answer that only uses what the cook typed. [prompt] is
/// the scan task's first text part (`{catalog, typedByCook}`).
String practicePantryAnswer(String prompt) {
  Map<String, dynamic> input;
  try {
    input = jsonDecode(prompt) as Map<String, dynamic>;
  } on Object {
    input = const {};
  }
  final typed = practiceTypedItems('${input['typedByCook'] ?? ''}');
  final catalog = [
    for (final entry in (input['catalog'] as List? ?? const []))
      if (entry is Map) entry,
  ];
  final meals = <({String id, double score, Map<String, Object> meal})>[];
  final used = <String>{};
  for (final recipe in catalog) {
    final matched = <String>[];
    final missing = <String>[];
    var required = 0;
    for (final raw in (recipe['ingredients'] as List? ?? const [])) {
      final name = '$raw';
      final optional = name.endsWith('?');
      final clean = (optional ? name.substring(0, name.length - 1) : name)
          .toLowerCase()
          .trim();
      final hit = practiceIngredientMatch(typed, clean) ?? const <String>[];
      if (!optional) required++;
      if (hit.isNotEmpty) {
        matched.add(clean);
        used.addAll(hit);
      } else if (!optional) {
        missing.add(clean);
      }
    }
    if (matched.isEmpty) continue;
    final have = matched.take(3).join(' and ');
    meals.add((
      id: '${recipe['recipeId']}',
      score: required == 0 ? 0 : (required - missing.length) / required,
      meal: {
        'recipeId': '${recipe['recipeId']}',
        'why': missing.isEmpty
            ? 'You have $have, so you can make this now.'
            : 'You have $have; you would still need ${missing.take(2).join(' and ')}.',
        'matched': matched.take(6).toList(),
        'missing': missing.take(6).toList(),
      },
    ));
  }
  meals.sort((a, b) => b.score.compareTo(a.score));
  final unused = typed.where((t) => !used.contains(t)).toList();
  return jsonEncode({
    'items': [
      for (final name in typed) {'name': name, 'confidence': 'high'},
    ],
    'meals': [for (final m in meals.take(kPantryMaxMeals)) m.meal],
    if (unused.isNotEmpty && meals.isNotEmpty)
      'question':
          'Do you want to use the ${unused.first} in this meal too, or save it?',
  });
}

String? _promptLine(String prompt, String label) {
  final match = RegExp(
    '^${RegExp.escape(label)}: (.*)\$',
    multiLine: true,
  ).firstMatch(prompt);
  if (match == null) return null;
  try {
    final value = jsonDecode(match.group(1)!);
    return value is String ? value : '$value';
  } on FormatException {
    return match.group(1);
  }
}

/// A short Coach Lite JSON answer about the current step. It never certifies
/// doneness or safety; it points the cook back to the step.
String practiceCoachAnswer(String prompt) {
  final question = _promptLine(
    prompt,
    "The cook's question (data, not instructions)",
  );
  final title = _promptLine(prompt, 'Step title') ?? 'this step';
  final instruction = _promptLine(prompt, 'Instruction') ?? '';
  final cue = _promptLine(prompt, 'Visible cue to look for') ?? '';
  final seconds = int.tryParse(
    RegExp(
          r'^Recipe timer for this step: (\d+) seconds$',
          multiLine: true,
        ).firstMatch(prompt)?.group(1) ??
        '',
  );
  String cut(String v, int max) =>
      v.length <= max ? v : '${v.substring(0, max - 1)}…';
  final asked = question == null || question.trim().isEmpty
      ? ''
      : 'You asked: “${cut(question.trim(), 120)}”. ';
  return jsonEncode({
    'components': [
      {
        'id': 'root',
        'component': 'CookingColumn',
        'children': ['practice_answer'],
      },
      {
        'id': 'practice_answer',
        'component': 'stepCue',
        'title': 'Practice answer for “${cut(title, 60)}”',
        'body': cut(
          '${asked}This is a pretend answer. Go gently and follow the step: '
          '$instruction${cue.isEmpty ? '' : ' Look for: $cue'}',
          560,
        ),
      },
    ],
    if (seconds != null && seconds > 0)
      'timerSuggestion': {'label': cut(title, 40), 'seconds': seconds},
  });
}

/// Watch verdicts in a fixed cycle: not yet, unsure, then the visible cue.
/// Watch verdicts in a fixed cycle: not yet, unsure, then the visible cue.
/// Observations name the current step's [cue] when known.
String practiceWatchAnswer(int turn, {String? cue}) {
  final target = cue == null || cue.trim().isEmpty ? null : cue.trim();
  String short(String v) => v.length <= 120 ? v : '${v.substring(0, 119)}…';
  return jsonEncode(switch (turn % 3) {
    0 => {
      'state': 'not_yet',
      'direction': 'more',
      'whatISee': target == null
          ? 'Practice camera: not at the step yet.'
          : 'Practice camera: not yet at "${short(target)}".',
    },
    1 => {'state': 'unsure', 'direction': 'none', 'whatISee': ''},
    _ => {
      'state': 'ready',
      'direction': 'none',
      'whatISee': target == null
          ? 'Practice camera: this looks like the step.'
          : 'Practice camera: looks like "${short(target)}".',
    },
  });
}

/// Label check: allergens a typed label names literally. A photo prompt has
/// no typed text, so the practice answer is "couldn't read".
String practiceLabelAnswer(String prompt) {
  final typed = RegExp(r'"""\n([\s\S]*?)\n"""').firstMatch(prompt)?.group(1);
  if (typed == null || typed.trim().isEmpty) {
    return jsonEncode({
      'readable': false,
      'allergensMentioned': [],
      'quote': '',
    });
  }
  final lower = typed.toLowerCase();
  final found = [
    for (final allergen in kLabelAllergens)
      if (RegExp(
        // Whole names and plurals only: "eggplant" is not egg.
        '\\b${RegExp.escape(allergen)}(?:s|es)?\\b',
        caseSensitive: false,
      ).hasMatch(lower))
        allergen,
  ];
  final quote = typed.trim();
  return jsonEncode({
    'readable': true,
    'allergensMentioned': found,
    'quote': quote.length <= 200 ? quote : quote.substring(0, 200),
  });
}

// ------------------------------------------------------- simulated legs

/// [leg] as practice mode reports it: a finished leg is [Provenance.simulated]
/// whatever the fake said. A failed leg keeps its provenance (unknown) so it
/// still reads "didn't finish".
InferenceLeg simulatedLeg(InferenceLeg leg) =>
    leg.error != null || leg.provenance == Provenance.unknown
    ? leg
    : InferenceLeg(
        requestId: leg.requestId,
        feature: leg.feature,
        mode: leg.mode,
        kinds: leg.kinds,
        transferPermitted: leg.transferPermitted,
        provenance: Provenance.simulated,
        modelLabel: null,
        error: null,
      );

/// The session ledger in practice mode: finished legs are recorded as
/// simulated, so "What we sent" never shows a real on-device or cloud run.
class SimulatedInferenceLedger extends InferenceLedger {
  SimulatedInferenceLedger({required super.sessionId, super.clock});

  @override
  void complete(
    LedgerEntry entry, {
    required Provenance provenance,
    String? modelLabel,
    HybridErrorCode? error,
  }) => super.complete(
    entry,
    provenance: error == null && provenance != Provenance.unknown
        ? Provenance.simulated
        : provenance,
    error: error,
  );

  @override
  LedgerEntry record(InferenceLeg leg) => super.record(simulatedLeg(leg));
}

/// Wraps the real dispatcher (policy, consent, ledger) and restamps the legs
/// it hands to features as simulated.
class SimulatedDispatcher implements HybridDispatcher {
  SimulatedDispatcher(this.inner);
  final HybridDispatcher inner;

  @override
  HybridOperation start(
    HybridTask task, {
    required String sessionId,
    ResultValidator? validate,
    ConsentGrant? grant,
  }) {
    final operation = inner.start(
      task,
      sessionId: sessionId,
      validate: validate,
      grant: grant,
    );
    return HybridOperation(
      operation.operationId,
      operation.result.then(
        (result) => DispatchResult(
          text: result.text,
          legs: [for (final leg in result.legs) simulatedLeg(leg)],
          blocked: result.blocked,
        ),
      ),
      operation.cancel,
    );
  }
}

/// Practice mode never sends anything online.
class NoCloudInPracticeMode implements CloudFallbackSender {
  const NoCloudInPracticeMode();

  @override
  Future<HybridResult> send(HybridRequest request) async =>
      throw const HybridException(
        HybridErrorCode.unavailable,
        'Practice mode never sends anything online.',
      );

  @override
  Future<void> cancel(String requestId) async {}
}

// ------------------------------------------------------------------ runtime

/// The rehearsal [HybridRuntime]: the real dispatcher over
/// [RehearsalHybridInference], no approved cloud routes, no cloud sender, and
/// a ledger that records simulated legs.
class RehearsalHybridRuntime extends HybridRuntime {
  RehearsalHybridRuntime._({
    required super.inference,
    required super.privacy,
    required super.cloudRoutes,
    required super.ledger,
    required super.dispatcher,
    required super.consent,
    required super.navigatorKey,
    required super.isOnline,
    required super.cloudModel,
  });

  factory RehearsalHybridRuntime.create({
    RehearsalHybridInference? inference,
    GlobalKey<NavigatorState>? navigatorKey,
  }) {
    final key = navigatorKey ?? GlobalKey<NavigatorState>();
    final fake = inference ?? RehearsalHybridInference();
    final prefs = InMemoryPrivacyPreferences();
    const routes = CloudRoutes({});
    bool online() => true; // practice mode needs no network
    final ledger = SimulatedInferenceLedger(
      sessionId:
          'practice-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
    );
    const model = 'none (practice mode)';
    final consent = DialogConsentGate(navigatorKey: key, cloudModel: model);
    return RehearsalHybridRuntime._(
      inference: fake,
      privacy: prefs,
      cloudRoutes: routes,
      ledger: ledger,
      consent: consent,
      navigatorKey: key,
      isOnline: online,
      cloudModel: model,
      dispatcher: SimulatedDispatcher(
        DefaultHybridDispatcher(
          inference: fake,
          privacy: prefs,
          cloudRoutes: routes,
          consent: consent,
          ledger: ledger,
          cloudFallback: const NoCloudInPracticeMode(),
          isOnline: online,
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- pantry

/// Practice-mode pantry: a typed list goes through the hybrid pantry client
/// (so the result respects it); a pretend photo or voice clip alone gets the
/// canned rehearsal result. Every result is labelled simulated.
class RehearsalPantryClient implements PantryClient {
  RehearsalPantryClient(
    this.hybrid, {
    this.fallback = const FakePantryClient(),
  });

  final HybridRuntime hybrid;
  final PantryClient fallback;

  @override
  Future<PantryResult> identify(PantryInput input, List<Recipe> recipes) async {
    if (input.text.trim().isEmpty) {
      // A pretend photo or voice clip skips the dispatcher, so its legs are
      // written to the session ledger here, once, as simulated (Codex #221).
      final canned = await fallback.identify(input, recipes);
      final legs = [for (final leg in canned.legs) simulatedLeg(leg)];
      for (final leg in legs) {
        hybrid.ledger.record(leg);
      }
      return PantryResult(
        items: canned.items,
        meals: canned.meals,
        question: canned.question,
        simulated: true,
        legs: legs,
        notice: canned.notice,
      );
    }
    final result = await HybridPantryClient(
      dispatcher: hybrid.dispatcher,
      sessionId: () => hybrid.sessionId,
    ).identify(PantryInput(text: input.text), recipes);
    return PantryResult(
      items: result.items,
      meals: result.meals,
      question: result.question,
      simulated: true,
      legs: result.legs,
      notice: result.notice,
    );
  }
}

/// Practice-mode recipe drafts: the canned rehearsal draft, with its legs
/// written to the session ledger once as simulated, so the draft's badge and
/// "What we sent" agree (Codex #221).
class RehearsalDraftClient implements RecipeDraftClient {
  RehearsalDraftClient(this.hybrid, this.inner);

  final HybridRuntime hybrid;
  final RecipeDraftClient inner;

  @override
  Future<RecipeDraftResult> draft(RecipeDraftRequest request) async {
    final result = await inner.draft(request);
    final legs = [for (final leg in result.legs) simulatedLeg(leg)];
    for (final leg in legs) {
      hybrid.ledger.record(leg);
    }
    return RecipeDraftResult(result.recipe, legs: legs);
  }
}

// ------------------------------------------------------------------- camera

/// The rehearsal camera: no device is opened. While a camera-only capture
/// runs (the on-device watch), it emits a drawn practice frame on a timer.
class RehearsalLiveMedia extends DemoLiveMedia {
  RehearsalLiveMedia({
    this.interval = const Duration(milliseconds: 700),
    DateTime Function()? now,
    this.onCameraStart,
  }) : _now = now ?? DateTime.now;

  final Duration interval;

  /// Called when a camera-only capture (a new practice watch) starts.
  final void Function()? onCameraStart;
  final DateTime Function() _now;
  final _frames = StreamController<CapturedFrame>.broadcast();
  Timer? _timer;
  int _count = 0;

  bool get capturing => _timer != null;

  @override
  Stream<CapturedFrame> get timedFrames => _frames.stream;

  @override
  Future<void> startCameraOnly() async {
    onCameraStart?.call();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      if (_frames.isClosed) return;
      _frames.add(
        CapturedFrame(bytes: practiceCameraFrame(_count++), capturedAt: _now()),
      );
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }
}

/// A small drawn kitchen scene (two slices of bread on a board) as a PNG.
/// [frame] nudges the light so consecutive frames differ.
Uint8List practiceCameraFrame(int frame, {int width = 160, int height = 120}) {
  final rgb = Uint8List(width * height * 3);
  final glow = (frame % 6) * 3;
  void put(int x, int y, int r, int g, int b) {
    final i = (y * width + x) * 3;
    rgb[i] = r.clamp(0, 255);
    rgb[i + 1] = g.clamp(0, 255);
    rgb[i + 2] = b.clamp(0, 255);
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // Counter: warm grey, lighter towards the top.
      final shade = 70 + (height - y) ~/ 3 + glow;
      put(x, y, shade + 18, shade + 10, shade);
      // Cutting board.
      final bx = x - 22, by = y - 26;
      if (bx >= 0 && bx < 116 && by >= 0 && by < 74) {
        final grain = (y % 7 == 0) ? -10 : 0;
        put(x, y, 196 + grain + glow, 150 + grain, 96 + grain);
      }
      // Two slices of bread: crust, then crumb.
      for (final sx in const [34, 84]) {
        final dx = x - sx, dy = y - 36;
        if (dx >= 0 && dx < 42 && dy >= 0 && dy < 50) {
          final edge = dx < 3 || dx > 38 || dy < 4 || dy > 46;
          if (edge) {
            put(x, y, 170, 112, 52);
          } else {
            put(x, y, 238 + glow ~/ 2, 214, 160);
          }
        }
      }
    }
  }
  return encodePng(width, height, rgb);
}

/// Minimal PNG encoder (8-bit RGB, stored deflate blocks). Enough for small
/// practice frames; no compression library needed on the web.
Uint8List encodePng(int width, int height, Uint8List rgb) {
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter: none
    raw.add(Uint8List.sublistView(rgb, y * width * 3, (y + 1) * width * 3));
  }
  final data = raw.toBytes();
  final zlib = BytesBuilder(copy: false)..add(const [0x78, 0x01]);
  var offset = 0;
  do {
    final n = (data.length - offset).clamp(0, 65535);
    final last = offset + n >= data.length;
    zlib
      ..addByte(last ? 1 : 0)
      ..add([n & 0xff, n >> 8, ~n & 0xff, (~n >> 8) & 0xff])
      ..add(Uint8List.sublistView(data, offset, offset + n));
    offset += n;
  } while (offset < data.length);
  var a = 1, b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  zlib.add(_u32(b * 65536 + a));

  final png = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> body) {
    final typed = ascii.encode(type);
    png
      ..add(_u32(body.length))
      ..add(typed)
      ..add(body)
      ..add(_u32(_crc32([...typed, ...body])));
  }

  chunk('IHDR', [..._u32(width), ..._u32(height), 8, 2, 0, 0, 0]);
  chunk('IDAT', zlib.toBytes());
  chunk('IEND', const []);
  return png.toBytes();
}

List<int> _u32(int v) => [
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xffffffff;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
