// Routing rules. Gemini only classifies the request (category -> needed
// skill); these deterministic rules pick the owner, and a person confirms by
// accepting. Pure Dart so it is unit-tested and shared by learner + board.

import 'models.dart';

class RoutingDecision {
  const RoutingDecision({required this.owner, required this.reason});

  /// Null when no available instructor covers the skill (needs-owner case).
  final Instructor? owner;

  /// Human-readable "why", shown on the board card and to the learner.
  final String reason;

  bool get routed => owner != null;
}

/// Picks the available instructor who covers [neededSkill] with the fewest
/// open requests, breaking ties by least-recently assigned, then by id.
RoutingDecision route({
  required String neededSkill,
  required List<Instructor> roster,
  Set<String> exclude = const {},
  Map<String, int> openLoad = const {},
}) {
  final eligible = roster
      .where((i) => i.available && i.covers(neededSkill) && !exclude.contains(i.id))
      .toList()
    ..sort((a, b) {
      final load = (openLoad[a.id] ?? 0).compareTo(openLoad[b.id] ?? 0);
      if (load != 0) return load;
      final at = a.lastAssignedAt?.millisecondsSinceEpoch ?? 0;
      final bt = b.lastAssignedAt?.millisecondsSinceEpoch ?? 0;
      if (at != bt) return at.compareTo(bt);
      return a.id.compareTo(b.id);
    });

  if (eligible.isEmpty) {
    final covering = roster.where((i) => i.covers(neededSkill)).toList();
    final why = covering.isEmpty
        ? 'No instructor covers $neededSkill'
        : 'No available instructor covers $neededSkill '
            '(${covering.map((i) => i.displayName).join(', ')} offline'
            '${exclude.isNotEmpty ? ' or declined' : ''})';
    return RoutingDecision(owner: null, reason: why);
  }

  final owner = eligible.first;
  final load = openLoad[owner.id] ?? 0;
  return RoutingDecision(
    owner: owner,
    reason: '${owner.displayName}: covers $neededSkill · available · '
        '$load open request${load == 1 ? '' : 's'}',
  );
}

/// Open (non-terminal, owned or suggested) request counts per instructor.
Map<String, int> openLoadFrom(Iterable<HelpRequest> requests) {
  final load = <String, int>{};
  for (final r in requests) {
    if (r.status.isTerminal) continue;
    final who = r.ownerId ?? r.suggestedOwnerId;
    if (who != null) load[who] = (load[who] ?? 0) + 1;
  }
  return load;
}
