// Help-request state machine. Every transition is a pure function
// (request, actor, now) -> request, so repositories can run it inside a
// Firestore transaction and tests can run it without Firebase.
//
//   submitted --triage--> suggested | needsOwner
//   needsOwner --reroute (roster change)--> suggested
//   needsOwner/suggested --accept (instructor) / assign (coordinator)--> accepted
//   suggested/accepted --decline--> suggested(next) | needsOwner
//   accepted --answer--> answered
//   answered --resolve (learner)--> resolved
//   answered --stillStuck (learner)--> accepted
//   any non-terminal --cancel (learner)--> cancelled
//
// Cooking completion never resolves a request; only the learner can.

import 'models.dart';
import 'routing.dart';

class TransitionError implements Exception {
  TransitionError(this.message);
  final String message;
  @override
  String toString() => 'TransitionError: $message';
}

class TriageResult {
  const TriageResult({
    required this.category,
    required this.urgency,
    required this.summaryForInstructor,
    this.aiUncertainty,
    this.englishQuestion,
    this.clarifyingQuestion,
    this.language = 'en',
  });

  final RequestCategory category;
  final Urgency urgency;
  final String summaryForInstructor;
  final String? aiUncertainty;
  final String? englishQuestion;
  final String? clarifyingQuestion;
  final String language;
}

abstract final class RequestMachine {
  /// The learner-facing next step for each status. Never empty.
  static String nextStepFor(
    RequestStatus status, {
    String? ownerName,
    String? skill,
    bool safety = false,
  }) {
    final who = ownerName ?? 'an instructor';
    return switch (status) {
      RequestStatus.submitted =>
        'Sending your question. It stays saved even if you lose signal.',
      RequestStatus.needsOwner =>
        'Waiting for an instructor who covers ${skill ?? 'this'}. '
            "You'll be notified when someone accepts. You can add details "
            'or cancel.${safety ? " Don't serve it until someone answers." : ''}',
      RequestStatus.suggested => 'Sent to $who. Waiting for them to accept.',
      RequestStatus.accepted => '$who is on it. Keep cooking; we will show '
          'the answer here.',
      RequestStatus.answered =>
        '$who answered. Did this solve it? Tap "This solved it" or '
            '"Still stuck".',
      RequestStatus.resolved => 'Resolved. The answer is saved in your session.',
      RequestStatus.cancelled => 'Cancelled.',
    };
  }

  static HelpRequest _move(
    HelpRequest r,
    RequestStatus to, {
    required String by,
    required DateTime now,
    required String nextStep,
    String? note,
  }) =>
      r.copyWith(
        status: to,
        nextStep: nextStep,
        updatedAt: now,
        history: [
          ...r.history,
          HistoryEntry(status: to, at: now, by: by, note: note),
        ],
      );

  static void _require(bool ok, String why) {
    if (!ok) throw TransitionError(why);
  }

  static String _nameOf(String? id, List<Instructor> roster) {
    for (final i in roster) {
      if (i.id == id) return i.displayName;
    }
    return 'an instructor';
  }

  /// Applies Gemini triage, then routes with the rules. Safety questions are
  /// forced to the allergens skill regardless of the model's category.
  static HelpRequest applyTriage(
    HelpRequest r,
    TriageResult t, {
    required List<Instructor> roster,
    required Map<String, int> openLoad,
    required DateTime now,
    bool forceSafety = false,
  }) {
    _require(r.status == RequestStatus.submitted,
        'triage only applies to submitted requests (was ${r.status.name})');
    final category = forceSafety ? RequestCategory.safetyAllergen : t.category;
    final triaged = r.copyWith(
      category: category,
      urgency: forceSafety ? Urgency.high : t.urgency,
      summaryForInstructor: t.summaryForInstructor,
      aiUncertainty: t.aiUncertainty,
      englishQuestion: t.englishQuestion,
    );
    return _routeFrom(triaged, roster: roster, openLoad: openLoad, now: now);
  }

  static HelpRequest _routeFrom(
    HelpRequest r, {
    required List<Instructor> roster,
    required Map<String, int> openLoad,
    required DateTime now,
    String by = 'rules',
  }) {
    final skill = r.neededSkill ?? Skills.technique;
    final decision = route(
      neededSkill: skill,
      roster: roster,
      exclude: r.declinedBy.toSet(),
      openLoad: openLoad,
    );
    final safety = r.category == RequestCategory.safetyAllergen;
    if (!decision.routed) {
      return _move(
        r.copyWith(
            suggestedOwnerId: null,
            suggestedReason: decision.reason,
            ownerId: null),
        RequestStatus.needsOwner,
        by: by,
        now: now,
        note: decision.reason,
        nextStep: nextStepFor(RequestStatus.needsOwner, skill: skill, safety: safety),
      );
    }
    final owner = decision.owner!;
    return _move(
      r.copyWith(
          suggestedOwnerId: owner.id,
          suggestedReason: decision.reason,
          ownerId: null),
      RequestStatus.suggested,
      by: by,
      now: now,
      note: decision.reason,
      nextStep: nextStepFor(RequestStatus.suggested, ownerName: owner.displayName),
    );
  }

  /// Re-runs routing for a needs-owner request, e.g. when an instructor comes
  /// online. Returns the request unchanged if still unroutable.
  static HelpRequest reroute(
    HelpRequest r, {
    required List<Instructor> roster,
    required Map<String, int> openLoad,
    required DateTime now,
  }) {
    _require(r.status == RequestStatus.needsOwner,
        'reroute only applies to needs-owner requests');
    final next = _routeFrom(r, roster: roster, openLoad: openLoad, now: now);
    return next.status == RequestStatus.needsOwner ? r : next;
  }

  /// An instructor takes ownership. Allowed from suggested (by the suggested
  /// instructor) or needsOwner (by any instructor covering the skill).
  /// Run inside a transaction: it rejects a request that already has an owner.
  static HelpRequest accept(HelpRequest r, Instructor by, {required DateTime now}) {
    _require(r.ownerId == null, 'already owned by ${r.ownerId}');
    _require(
        r.status == RequestStatus.suggested || r.status == RequestStatus.needsOwner,
        'cannot accept a ${r.status.name} request');
    if (r.status == RequestStatus.suggested) {
      _require(r.suggestedOwnerId == by.id,
          'suggested for ${r.suggestedOwnerId}, not ${by.id}');
    } else {
      final skill = r.neededSkill ?? Skills.technique;
      _require(by.covers(skill) || by.role == InstructorRole.coordinator,
          '${by.displayName} does not cover $skill');
    }
    return _move(
      r.copyWith(ownerId: by.id),
      RequestStatus.accepted,
      by: by.id,
      now: now,
      nextStep: nextStepFor(RequestStatus.accepted, ownerName: by.displayName),
    );
  }

  /// A coordinator manually assigns a needs-owner (or suggested) request.
  /// Manual routing; the assignee still has to answer.
  static HelpRequest assign(
    HelpRequest r,
    Instructor coordinator,
    Instructor assignee, {
    required DateTime now,
  }) {
    _require(coordinator.role == InstructorRole.coordinator,
        '${coordinator.displayName} is not a coordinator');
    _require(r.ownerId == null, 'already owned by ${r.ownerId}');
    _require(
        r.status == RequestStatus.suggested || r.status == RequestStatus.needsOwner,
        'cannot assign a ${r.status.name} request');
    return _move(
      r.copyWith(ownerId: assignee.id, suggestedOwnerId: assignee.id),
      RequestStatus.accepted,
      by: coordinator.id,
      now: now,
      note: 'Assigned to ${assignee.displayName} by ${coordinator.displayName}',
      nextStep:
          nextStepFor(RequestStatus.accepted, ownerName: assignee.displayName),
    );
  }

  /// The suggested instructor or the owner declines; routing moves on to the
  /// next eligible instructor, or the request returns to needs-owner.
  static HelpRequest decline(
    HelpRequest r,
    Instructor by, {
    required List<Instructor> roster,
    required Map<String, int> openLoad,
    required DateTime now,
    String? reason,
  }) {
    final isSuggested =
        r.status == RequestStatus.suggested && r.suggestedOwnerId == by.id;
    final isOwner = r.status == RequestStatus.accepted && r.ownerId == by.id;
    _require(isSuggested || isOwner,
        '${by.displayName} cannot decline a ${r.status.name} request');
    final declined = _move(
      r.copyWith(
        declinedBy: [...r.declinedBy, by.id],
        ownerId: null,
        suggestedOwnerId: null,
      ),
      RequestStatus.needsOwner,
      by: by.id,
      now: now,
      note: 'Declined by ${by.displayName}${reason == null ? '' : ': $reason'}',
      nextStep: "${by.displayName} couldn't take this. Finding someone else.",
    );
    return _routeFrom(declined, roster: roster, openLoad: openLoad, now: now);
  }

  static HelpRequest answer(
    HelpRequest r,
    Instructor by,
    String text, {
    required DateTime now,
  }) {
    _require(r.status == RequestStatus.accepted, 'cannot answer a ${r.status.name} request');
    _require(r.ownerId == by.id, 'only the owner can answer');
    _require(text.trim().isNotEmpty, 'answer is empty');
    return _move(
      r.copyWith(answerText: text.trim(), answeredBy: by.id, answeredAt: now),
      RequestStatus.answered,
      by: by.id,
      now: now,
      nextStep: nextStepFor(RequestStatus.answered, ownerName: by.displayName),
    );
  }

  static HelpRequest resolve(HelpRequest r, String learnerId, {required DateTime now}) {
    _require(r.learnerId == learnerId, 'only the requester can resolve');
    _require(r.status == RequestStatus.answered, 'cannot resolve a ${r.status.name} request');
    return _move(r, RequestStatus.resolved,
        by: learnerId, now: now, nextStep: nextStepFor(RequestStatus.resolved));
  }

  static HelpRequest stillStuck(
    HelpRequest r,
    String learnerId,
    String note, {
    required List<Instructor> roster,
    required DateTime now,
  }) {
    _require(r.learnerId == learnerId, 'only the requester can reply');
    _require(r.status == RequestStatus.answered, 'cannot reopen a ${r.status.name} request');
    return _move(
      r.copyWith(details: [...r.details, note]),
      RequestStatus.accepted,
      by: learnerId,
      now: now,
      note: 'Still stuck: $note',
      nextStep: nextStepFor(RequestStatus.accepted,
          ownerName: _nameOf(r.ownerId, roster)),
    );
  }

  static HelpRequest cancel(HelpRequest r, String learnerId, {required DateTime now}) {
    _require(r.learnerId == learnerId, 'only the requester can cancel');
    _require(!r.status.isTerminal, 'request already ${r.status.name}');
    return _move(r, RequestStatus.cancelled,
        by: learnerId, now: now, nextStep: nextStepFor(RequestStatus.cancelled));
  }

  static HelpRequest addDetails(HelpRequest r, String learnerId, String text,
      {required DateTime now}) {
    _require(r.learnerId == learnerId, 'only the requester can add details');
    _require(!r.status.isTerminal, 'request already ${r.status.name}');
    return r.copyWith(details: [...r.details, text], updatedAt: now);
  }

  /// Knowledge loop: the owner approves their answer to a substitution
  /// request as a reviewed substitution for the recipe.
  static ReviewedSubstitution approveAsReviewed(HelpRequest r, Instructor by) {
    _require(r.category == RequestCategory.substitution,
        'only substitution answers can become reviewed substitutions');
    _require(
        r.status == RequestStatus.answered || r.status == RequestStatus.resolved,
        'answer first');
    _require(r.ownerId == by.id, 'only the owner can approve');
    _require(r.substitutionIngredientId != null && r.proposedSubstitute != null,
        'request has no ingredient/substitute');
    return ReviewedSubstitution(
      ingredientId: r.substitutionIngredientId!,
      substitute: r.proposedSubstitute!,
      note: r.answerText ?? '',
      approvedBy: by.displayName,
      sourceRequestId: r.id,
    );
  }
}
