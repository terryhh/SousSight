import 'dart:convert';

import '../ai/hybrid/hybrid_types.dart';
import '../core/models.dart';

/// Ledger key for the on-device watch. The policy forces `onlyOnDevice` for
/// it; the watch never sets a mode.
const kLocalWatchFeature = 'local_watch';

/// Ledger key for the single, consented cloud look at one unclear frame.
/// The policy must route it cloud-only and require consent (see the PR).
const kWatchCloudCheckFeature = 'local_watch_cloud_check';

enum WatchState { ready, notYet, unsure }

enum WatchDirection { more, less, none }

/// Where a verdict was produced, from the dispatcher's legs.
enum WatchVerdictSource { onDevice, cloud, simulated, unknown }

/// The JSON the model must return. `ready` means "matches the step's visible
/// cue", never "done" or "safe".
const Map<String, Object?> kWatchSchema = {
  'type': 'object',
  'properties': {
    'state': {
      'type': 'string',
      'enum': ['ready', 'not_yet', 'unsure'],
      'description':
          'ready: the photo clearly shows the visible cue. not_yet: the food '
          'is visible and does not show the cue yet. unsure: the food is '
          'hidden, blurry, dark or out of frame.',
    },
    'direction': {
      'type': 'string',
      'enum': ['more', 'less', 'none'],
      'description':
          'For not_yet: more if it needs more of the step\'s action, less if '
          'it looks past the cue, none otherwise.',
    },
    'whatISee': {
      'type': 'string',
      'description': 'One short sentence about only what is visible.',
    },
  },
  'required': ['state', 'direction', 'whatISee'],
};

const kWatchSystemInstruction =
    'You look at one kitchen camera photo for a home cook and compare only '
    'what is visible with the visible cue for the current recipe step. '
    'Reply with JSON only. Use state "ready" only if the photo clearly shows '
    'the cue; "not_yet" if the food is visible but does not show the cue yet; '
    '"unsure" if the food is hidden, blurry, too dark or out of frame. '
    'For "not_yet", set direction to "more" if it needs more of the step\'s '
    'action, "less" if it looks past the cue, otherwise "none". '
    'whatISee is one short sentence describing only what is visible. '
    'Never state or guess internal temperature, doneness inside the food, '
    'freshness, allergens or whether food is safe to eat.';

const _fieldLimit = 280;

String _clip(String value) {
  final text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  return text.length <= _fieldLimit
      ? text
      : '${text.substring(0, _fieldLimit - 1)}…';
}

/// The visible cue to watch for, or null when the step has nothing visible
/// to compare against.
String? watchCue(RecipeStep step) {
  final cue = step.cue.trim();
  if (cue.isNotEmpty) return cue;
  final instruction = step.instruction.trim();
  return instruction.isEmpty ? null : instruction;
}

/// The single-turn prompt for one frame. Bounded so the whole task fits the
/// smallest local budget (Android: 4,000 tokens including one image).
String buildWatchPrompt(RecipeStep step) {
  final cue = watchCue(step) ?? '';
  return 'Step: ${_clip(step.title)}\n'
      'Instruction: ${_clip(step.instruction)}\n'
      'Visible cue to look for: ${_clip(cue)}\n'
      'Does this photo show the visible cue?';
}

/// One verdict, stamped by the app (never the model) with the watch, step and
/// session it was asked for.
class WatchVerdict {
  const WatchVerdict({
    required this.state,
    required this.direction,
    required this.whatISee,
    required this.watchId,
    required this.stepId,
    required this.sessionId,
    required this.frameCapturedAt,
    required this.source,
    this.legs = const [],
    this.redacted = false,
  });

  final WatchState state;
  final WatchDirection direction;
  final String whatISee;
  final String watchId;
  final String stepId;
  final String sessionId;
  final DateTime frameCapturedAt;
  final WatchVerdictSource source;
  final List<InferenceLeg> legs;

  /// True when the model's sentence made a claim vision cannot support and
  /// was replaced.
  final bool redacted;

  /// Cook-facing text. It says what the camera shows and never certifies
  /// doneness, temperature or safety.
  String get message {
    final seen = whatISee.isEmpty ? '' : ' I can see: $whatISee';
    final where = switch (source) {
      WatchVerdictSource.cloud => ' (cloud check of one photo)',
      WatchVerdictSource.simulated => ' (practice mode, pretend answer)',
      _ => '',
    };
    return switch (state) {
      WatchState.ready =>
        'This looks like the cue for this step$where.$seen '
            'Have a look yourself before moving on — the camera can\'t '
            'check temperature or food safety.',
      WatchState.notYet => switch (direction) {
        WatchDirection.more => 'Not at the cue yet — keep going$where.$seen',
        // Food keeps cooking while the cook looks, so heat comes off first.
        WatchDirection.less =>
          "It may be past the cue$where. If it's on the heat, slide the pan "
              'off the heat, then look.$seen',
        WatchDirection.none => 'Not at the cue yet$where.$seen',
      },
      WatchState.unsure =>
        'I can\'t see it clearly$where. Move the camera closer, clear '
            'steam or hands from view, or add light.$seen',
    };
  }
}

// Words may be separated by spaces or hyphens ("cooked-through").
const _sp = r'[\s-]+';
const _middle = '(inside|in${_sp}the$_sp(middle|centre|center)|throughout)';

/// Judgements a photo cannot support: doneness, temperature, safety,
/// freshness and allergens, in English and basic Spanish. Doneness words
/// ("cooked", "done", "cocido") are matched on their own rather than in
/// phrases, because phrase lists kept leaking ("cooked to the
/// bone", "well-done"). Matching is deliberately broad: a false match only
/// swaps the sentence for a neutral one, a miss shows the cook a claim the
/// camera cannot make. Spanish "hecho" is the exception: it is also the
/// auxiliary in visible cues ("se han hecho burbujas"), so only its doneness
/// predicate ("está hecho", "bien hecho", "ya hecho") is matched.
final _unsupportedClaim = RegExp(
  [
    // Doneness, any phrasing: overcooked, undercooked, well-done, doneness.
    r'cooked\b', r'\bdone', r'\b(under|over)[\s-]*done\b',
    '(all${_sp}the${_sp}way|right)${_sp}through',
    '\\b(raw|pink|bloody|red|opaque|set)$_sp$_middle',
    r'no\s+longer\s+pink', r'\binternal(ly)?\b', r'\binterior\b',
    r'juices?\s+(run|running|are|is)\s+clear', r'medium[\s-]+rare',
    // Safety.
    r'\bsafe(ly|ty)?\b', r'\bunsafe\b', 'food${_sp}safe',
    '\\b(ready|okay|ok|fine|good|fit)${_sp}to$_sp(eat|serve)\\b',
    r'\b(salmonella|bacteria|pathogens?|food\s+poisoning)\b',
    // Temperature, with or without a number or unit.
    r'temperature', r'\btemps?\b', r'thermometer', r'[°º]',
    r'\b(degrees?|deg|fahrenheit|celsius)\b', r'\b\d+\s*[fc]\b',
    // Freshness and allergens.
    r'spoil', r'gone\s+off', r'allerg', r'\bgluten\b', r'\blactose\b',
    '\\b(nut|peanut|dairy|egg|soy|wheat|shellfish)$_sp?free\\b',
    r'\bmay\s+contain\b', r'\b(in)?edible\b', r'\bcomestible\b',
    // Whether an ingredient is absent or present is not something a photo
    // of the pan can establish ("there are no peanuts", "contains nuts").
    '\\b(no|any|without|contains?|free$_sp(of|from))$_sp'
        '(peanuts?|nuts?|dairy|milk|eggs?|soy|wheat|shellfish|sesame|fish)\\b',
    // Spanish basics: cocido/cocinado, hecho, seguro, sin gluten,
    // temperatura, grados, por dentro, listo para comer, alérgeno.
    r'\b(cocid|cocinad|segur|crud)[oa]s?\b',
    r'\b(est[aá]n?|estar|bien|ya|muy|poco|medio|mal)\s+hech[oa]s?\b',
    r'\bsin\s+gluten\b',
    r'temperatura', r'\bgrados?\b', r'\bpor\s+dentro\b',
    r'\blist[oa]s?\s+para\s+(comer|servir)\b', r'al[eé]rg',
  ].join('|'),
  caseSensitive: false,
);

/// True when [text] claims something vision cannot establish.
bool claimsUnsupported(String text) =>
    _unsupportedClaim.hasMatch(text.replaceAll('\u2019', "'"));

// Words that say nothing about what the cue looks like. Compared by their
// first four letters, like the content words below.
const _fillerStems = {
  'with', 'that', 'this', 'thes', 'have', 'look', 'like', 'from', 'into', //
  'they', 'them', 'ther', 'been', 'some', 'more', 'unti', 'abou', 'when',
  'then', 'than', 'very', 'just', 'also', 'each', 'stil', 'only', 'what',
  'your', 'will', 'step', 'food', 'appe', 'seem', 'visi', 'phot', 'imag',
  'clea', 'show',
};

Set<String> _contentStems(String text) => {
  for (final word in RegExp(
    r'[a-záéíóúñü]+',
  ).allMatches(text.toLowerCase()).map((m) => m[0]!))
    if (word.length >= 4 && !_fillerStems.contains(word.substring(0, 4)))
      word.substring(0, 4),
};

/// True when [observation] shares at least one content word with [cue]
/// ("Golden edges." and "golden at the edges"), so a positive verdict
/// points at the thing the step asked the camera to look for.
bool relatesToCue(String observation, String cue) =>
    _contentStems(observation).intersection(_contentStems(cue)).isNotEmpty;

/// Parses the model's JSON. Anything malformed becomes `unsure` so the cook
/// is asked for a better view rather than shown a guess. Never throws.
///
/// With [cue], a `ready` whose observation does not mention anything in the
/// cue also abstains: "ready" must rest on the visible cue it was asked
/// about.
({WatchState state, WatchDirection direction, String whatISee, bool redacted})
parseWatchJson(String text, {String? cue}) {
  const unsure = (
    state: WatchState.unsure,
    direction: WatchDirection.none,
    whatISee: '',
    redacted: false,
  );
  Object? decoded;
  try {
    decoded = jsonDecode(text.trim());
  } on FormatException {
    return unsure;
  }
  if (decoded is! Map) return unsure;
  // Every schema field must be present with the right type and value before
  // anything is accepted; a positive verdict also needs an observation.
  final rawState = decoded['state'];
  final rawDirection = decoded['direction'];
  final raw = decoded['whatISee'];
  if (rawState is! String || rawDirection is! String || raw is! String) {
    return unsure;
  }
  final state = switch (rawState) {
    'ready' => WatchState.ready,
    'not_yet' => WatchState.notYet,
    'unsure' => WatchState.unsure,
    _ => null,
  };
  final parsedDirection = switch (rawDirection) {
    'more' => WatchDirection.more,
    'less' => WatchDirection.less,
    'none' => WatchDirection.none,
    _ => null,
  };
  if (state == null || parsedDirection == null) return unsure;
  final seen = _clip(raw);
  if (seen.isEmpty && state != WatchState.unsure) return unsure;
  final direction = state == WatchState.notYet
      ? parsedDirection
      : WatchDirection.none;
  // Check the whole observation, not the clipped display text, so a claim
  // past the clip (or split by it) is still caught.
  if (claimsUnsupported(raw.replaceAll(RegExp(r'\s+'), ' '))) {
    // The sentence was the only evidence. A positive verdict resting on a
    // claim the camera cannot make abstains, so the watch keeps looking
    // instead of stopping and telling the cook it saw the cue; and a "more"
    // or "less" resting on it is dropped, so no heat change is suggested.
    return (
      state: state == WatchState.ready ? WatchState.unsure : state,
      direction: WatchDirection.none,
      whatISee: 'I can describe how it looks, not how it is inside.',
      redacted: true,
    );
  }
  if (state == WatchState.ready && cue != null && !relatesToCue(seen, cue)) {
    return (
      state: WatchState.unsure,
      direction: WatchDirection.none,
      whatISee: seen,
      redacted: false,
    );
  }
  return (state: state, direction: direction, whatISee: seen, redacted: false);
}

WatchVerdictSource sourceOf(List<InferenceLeg> legs) {
  final last = legs.isEmpty ? null : legs.last;
  return switch (last?.provenance) {
    Provenance.sdkOnDevice => WatchVerdictSource.onDevice,
    Provenance.sdkCloud || Provenance.cloudAdapter => WatchVerdictSource.cloud,
    Provenance.simulated => WatchVerdictSource.simulated,
    _ => WatchVerdictSource.unknown,
  };
}
