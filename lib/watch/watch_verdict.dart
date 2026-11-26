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
        WatchDirection.less =>
          'It may be past the cue — have a look$where.$seen',
        WatchDirection.none => 'Not at the cue yet$where.$seen',
      },
      WatchState.unsure =>
        'I can\'t see it clearly$where. Move the camera closer, clear '
            'steam or hands from view, or add light.$seen',
    };
  }
}

final _unsupportedClaim = RegExp(
  r'safe to eat|food[- ]safe|\bunsafe\b|\bsafe\b|temperature|°|\bdegrees\b|'
  r'cooked through|fully cooked|undercooked|raw (inside|in the middle)|'
  r'done inside|spoil|gone off|allergen',
  caseSensitive: false,
);

/// Parses the model's JSON. Anything malformed becomes `unsure` so the cook
/// is asked for a better view rather than shown a guess. Never throws.
({WatchState state, WatchDirection direction, String whatISee, bool redacted})
parseWatchJson(String text) {
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
  var seen = _clip(raw);
  if (seen.isEmpty && state != WatchState.unsure) return unsure;
  final direction = state == WatchState.notYet
      ? parsedDirection
      : WatchDirection.none;
  var redacted = false;
  if (_unsupportedClaim.hasMatch(seen)) {
    seen = 'I can describe how it looks, not how it is inside.';
    redacted = true;
  }
  return (
    state: state,
    direction: direction,
    whatISee: seen,
    redacted: redacted,
  );
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
