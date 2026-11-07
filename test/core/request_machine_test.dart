import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/core/request_machine.dart';
import 'package:soussight/core/routing.dart';

final t0 = DateTime.utc(2026, 11, 7, 20);

HelpRequest submitted({HandoffTrigger trigger = HandoffTrigger.substitution}) =>
    HelpRequest(
      id: 'r1',
      learnerId: 'learner-1',
      sessionId: 's1',
      recipeId: 'chickpea_wrap_v1',
      stepId: 'mix',
      question: 'No lemon. Can I use vinegar?',
      trigger: trigger,
      status: RequestStatus.submitted,
      nextStep: RequestMachine.nextStepFor(RequestStatus.submitted),
      history: [HistoryEntry(status: RequestStatus.submitted, at: t0, by: 'learner-1')],
      createdAt: t0,
      updatedAt: t0,
      substitutionIngredientId: 'lemon',
      proposedSubstitute: 'white vinegar',
    );

const subTriage = TriageResult(
  category: RequestCategory.substitution,
  urgency: Urgency.normal,
  summaryForInstructor: 'Missing lemon juice; asks about vinegar.',
);

Instructor byId(String id) => demoRoster().firstWhere((i) => i.id == id);

void main() {
  final roster = demoRoster();

  test('triage routes a substitution to Marcus as a suggestion', () {
    final r = RequestMachine.applyTriage(submitted(), subTriage,
        roster: roster, openLoad: const {}, now: t0);
    expect(r.status, RequestStatus.suggested);
    expect(r.suggestedOwnerId, 'marcus');
    expect(r.ownerId, isNull);
    expect(r.suggestedReason, contains('substitutions'));
    expect(r.history.last.status, RequestStatus.suggested);
  });

  test('safety question lands in needs-owner because Priya is offline', () {
    final r = RequestMachine.applyTriage(
        submitted(trigger: HandoffTrigger.safety), subTriage,
        roster: roster, openLoad: const {}, now: t0, forceSafety: true);
    expect(r.category, RequestCategory.safetyAllergen);
    expect(r.status, RequestStatus.needsOwner);
    expect(r.nextStep, contains("Don't serve it"));
    expect(r.suggestedReason, contains('Priya'));
  });

  test('needs-owner reroutes when Priya comes online', () {
    final waiting = RequestMachine.applyTriage(
        submitted(trigger: HandoffTrigger.safety), subTriage,
        roster: roster, openLoad: const {}, now: t0, forceSafety: true);
    final online = [
      for (final i in roster) i.id == 'priya' ? i.copyWith(available: true) : i,
    ];
    final r = RequestMachine.reroute(waiting, roster: online, openLoad: const {}, now: t0);
    expect(r.status, RequestStatus.suggested);
    expect(r.suggestedOwnerId, 'priya');
  });

  test('full lifecycle: accept, answer, resolve', () {
    var r = RequestMachine.applyTriage(submitted(), subTriage,
        roster: roster, openLoad: const {}, now: t0);
    r = RequestMachine.accept(r, byId('marcus'), now: t0);
    expect(r.status, RequestStatus.accepted);
    expect(r.ownerId, 'marcus');
    r = RequestMachine.answer(r, byId('marcus'), 'Yes, use 1 tbsp white vinegar.', now: t0);
    expect(r.status, RequestStatus.answered);
    r = RequestMachine.resolve(r, 'learner-1', now: t0);
    expect(r.status, RequestStatus.resolved);
    expect(r.history.map((h) => h.status), [
      RequestStatus.submitted,
      RequestStatus.suggested,
      RequestStatus.accepted,
      RequestStatus.answered,
      RequestStatus.resolved,
    ]);
  });

  test('only the suggested instructor can accept; double accept is rejected', () {
    final r = RequestMachine.applyTriage(submitted(), subTriage,
        roster: roster, openLoad: const {}, now: t0);
    expect(() => RequestMachine.accept(r, byId('ana'), now: t0),
        throwsA(isA<TransitionError>()));
    final owned = RequestMachine.accept(r, byId('marcus'), now: t0);
    expect(() => RequestMachine.accept(owned, byId('marcus'), now: t0),
        throwsA(isA<TransitionError>()));
  });

  test('decline moves to the next eligible instructor, then to needs-owner', () {
    var r = RequestMachine.applyTriage(submitted(), subTriage,
        roster: roster, openLoad: const {}, now: t0);
    r = RequestMachine.decline(r, byId('marcus'), roster: roster, openLoad: const {}, now: t0);
    // Only Marcus covers substitutions.
    expect(r.status, RequestStatus.needsOwner);
    expect(r.declinedBy, ['marcus']);
    expect(r.ownerId, isNull);
  });

  test('coordinator can manually assign a needs-owner request', () {
    var r = RequestMachine.applyTriage(
        submitted(trigger: HandoffTrigger.safety), subTriage,
        roster: roster, openLoad: const {}, now: t0, forceSafety: true);
    r = RequestMachine.assign(r, byId('coordinator'), byId('ana'), now: t0);
    expect(r.status, RequestStatus.accepted);
    expect(r.ownerId, 'ana');
  });

  test('still stuck reopens to the owner; cancel is learner-only', () {
    var r = RequestMachine.applyTriage(submitted(), subTriage,
        roster: roster, openLoad: const {}, now: t0);
    r = RequestMachine.accept(r, byId('marcus'), now: t0);
    r = RequestMachine.answer(r, byId('marcus'), 'Use vinegar.', now: t0);
    r = RequestMachine.stillStuck(r, 'learner-1', 'How much?', roster: roster, now: t0);
    expect(r.status, RequestStatus.accepted);
    expect(r.details, ['How much?']);
    expect(() => RequestMachine.cancel(r, 'someone-else', now: t0),
        throwsA(isA<TransitionError>()));
    expect(RequestMachine.cancel(r, 'learner-1', now: t0).status, RequestStatus.cancelled);
  });

  test('knowledge loop: owner approves a substitution answer', () {
    var r = RequestMachine.applyTriage(submitted(), subTriage,
        roster: roster, openLoad: const {}, now: t0);
    r = RequestMachine.accept(r, byId('marcus'), now: t0);
    r = RequestMachine.answer(r, byId('marcus'), 'Yes: same amount of white vinegar.', now: t0);
    final s = RequestMachine.approveAsReviewed(r, byId('marcus'));
    expect(s.ingredientId, 'lemon');
    expect(s.substitute, 'white vinegar');
    expect(s.approvedBy, 'Marcus');
    expect(s.sourceRequestId, 'r1');
  });

  test('routing prefers the least-loaded eligible instructor', () {
    final d = route(
      neededSkill: Skills.technique,
      roster: roster,
      openLoad: const {'ana': 2, 'marcus': 0},
    );
    expect(d.owner?.id, 'marcus');
    expect(openLoadFrom([
      RequestMachine.applyTriage(submitted(), subTriage,
          roster: roster, openLoad: const {}, now: t0),
    ]), {'marcus': 1});
  });

  test('model maps round-trip', () {
    final r = RequestMachine.applyTriage(submitted(), subTriage,
        roster: roster, openLoad: const {}, now: t0);
    final back = HelpRequest.fromMap(r.id, r.toMap());
    expect(back.status, r.status);
    expect(back.category, r.category);
    expect(back.history.length, r.history.length);
    expect(back.suggestedOwnerId, 'marcus');
  });
}
