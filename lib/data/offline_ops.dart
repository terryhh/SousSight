// SS-072: an already-open cooking session keeps working when the connection
// drops. Step changes become operations that apply on this device at once and
// are saved later, each in one transaction that records its id so a retry can
// never apply twice. Reopening the app while offline is out of scope.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/services.dart';

/// Session field listing the ids of the step operations already saved.
const String appliedOpIdsField = 'appliedOpIds';

/// How many saved operation ids the session keeps. A retry only ever repeats
/// one of the most recent operations, so a short list is enough.
const int maxAppliedOpIds = 32;

enum StepOpKind {
  /// Finish the expected step and move to [StepOp.toStepId].
  advance,

  /// Finish the last step. Its own kind, because the last step does not move
  /// ("next" is "current"), so only the kind and the op id stop a retry from
  /// completing it twice.
  complete,
}

/// A timer the cook started; its end time is absolute, so saving it late
/// never moves the deadline.
@immutable
class OpTimer {
  const OpTimer({required this.id, required this.label, required this.endsAt});
  final String id;
  final String label;
  final DateTime endsAt;
}

/// One step change: `{opId, kind, expectedStepId, timerEndsAt?}`.
class StepOp {
  StepOp({
    required this.opId,
    required this.kind,
    required this.expectedStepId,
    required this.toStepId,
    this._timer,
  });

  final String opId;
  final StepOpKind kind;

  /// The step the cook was on. The save is dropped if the session has moved.
  final String expectedStepId;

  /// The step shown afterwards (the same step for [StepOpKind.complete]).
  final String toStepId;

  OpTimer? _timer;

  /// A timer started after this step change and before it was first sent.
  OpTimer? get timer => _timer;

  bool _sent = false;

  /// True once a save was attempted; its timer can no longer change, because
  /// that attempt may already have been applied.
  bool get sent => _sent;
}

enum StepOpOutcome {
  /// Saved now.
  applied,

  /// Already saved (a retry after a lost acknowledgement), or the last step
  /// was already complete. Nothing was written.
  duplicate,

  /// The session is no longer on [StepOp.expectedStepId]. Nothing was written.
  stale,
}

@immutable
class StepOpCommit {
  const StepOpCommit(this.outcome, this.session);
  final StepOpOutcome outcome;

  /// The saved session after this operation (unchanged unless applied).
  final CookingSession session;
}

@immutable
class StepOpDecision {
  const StepOpDecision(this.outcome, {this.next, this.appliedOpIds = const []});
  final StepOpOutcome outcome;

  /// The session to write; null when nothing is written.
  final CookingSession? next;

  /// The bounded id list to write with [next].
  final List<String> appliedOpIds;
}

bool _alreadyDone(StepOp op, CookingSession s) =>
    op.kind == StepOpKind.complete &&
    s.completedStepIds.contains(op.expectedStepId);

/// Whether [op] would change [s]: the same test the save makes, minus the id
/// list. Used to re-apply pending operations over a snapshot.
bool stepOpApplies(StepOp op, CookingSession s) =>
    s.currentStepId == op.expectedStepId && !_alreadyDone(op, s);

/// The step change itself, with its timer. Does not touch revision.
CookingSession applyStepOp(StepOp op, CookingSession s) {
  final next = s.copyWith(
    currentStepId: op.kind == StepOpKind.advance
        ? op.toStepId
        : s.currentStepId,
    completedStepIds: {...s.completedStepIds, op.expectedStepId}.toList(),
  );
  final timer = op.timer;
  return timer == null ? next : withTimer(next, timer);
}

CookingSession withoutTimer(CookingSession s) =>
    s.copyWith(timerDeadline: null, timerLabel: null, timerId: null);

CookingSession withTimer(CookingSession s, OpTimer timer) => s.copyWith(
  timerDeadline: timer.endsAt,
  timerLabel: timer.label,
  timerId: timer.id,
);

/// The rule every store runs inside its transaction.
StepOpDecision decideStepOp(
  StepOp op,
  CookingSession current,
  List<String> appliedOpIds, {
  required DateTime now,
}) {
  if (appliedOpIds.contains(op.opId) || _alreadyDone(op, current)) {
    return const StepOpDecision(StepOpOutcome.duplicate);
  }
  if (current.currentStepId != op.expectedStepId) {
    return const StepOpDecision(StepOpOutcome.stale);
  }
  final ids = [...appliedOpIds, op.opId];
  return StepOpDecision(
    StepOpOutcome.applied,
    next: applyStepOp(
      op,
      current,
    ).copyWith(revision: current.revision + 1, updatedAt: now),
    appliedOpIds: ids.sublist(
      ids.length > maxAppliedOpIds ? ids.length - maxAppliedOpIds : 0,
    ),
  );
}

/// Reads the id list from a stored session document, ignoring malformed data.
List<String> readAppliedOpIds(Map<String, dynamic>? data) {
  final raw = data?[appliedOpIdsField];
  return raw is List ? raw.whereType<String>().toList() : const [];
}

/// The transaction body for a document store: decide from the stored map,
/// and return the map to write (null when nothing is written). The map is the
/// session's own fields plus [appliedOpIdsField], not yet store-encoded.
({StepOpCommit commit, Map<String, dynamic>? write}) stepOpTransaction(
  String sessionId,
  Map<String, dynamic> data,
  StepOp op, {
  required DateTime now,
}) {
  final current = CookingSession.fromMap(sessionId, data);
  final decision = decideStepOp(op, current, readAppliedOpIds(data), now: now);
  final next = decision.next;
  return (
    commit: StepOpCommit(decision.outcome, next ?? current),
    write: next == null
        ? null
        : {...next.toMap(), appliedOpIdsField: decision.appliedOpIds},
  );
}

/// Keeps the stored id list when an ordinary session update rewrites the
/// whole document from [CookingSession.toMap], which does not carry it.
Map<String, dynamic> keepAppliedOpIds(
  Map<String, dynamic>? stored,
  Map<String, dynamic> next,
) {
  final ids = readAppliedOpIds(stored);
  return ids.isEmpty ? next : {...next, appliedOpIdsField: ids};
}

/// Saves one step operation atomically with its id.
abstract interface class StepOpStore {
  Future<StepOpCommit> commitStepOp(String sessionId, StepOp op);
}

/// For in-memory repositories (rehearsal and tests): the id list lives next
/// to the repository and is updated inside the same read-modify-write.
class RepositoryStepOpStore implements StepOpStore {
  RepositoryStepOpStore(this._sessions, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final SessionRepository _sessions;
  final DateTime Function() _clock;
  final Map<String, List<String>> _applied = {};

  @override
  Future<StepOpCommit> commitStepOp(String sessionId, StepOp op) async {
    var outcome = StepOpOutcome.duplicate;
    final saved = await _sessions.update(sessionId, (current) {
      final decision = decideStepOp(
        op,
        current,
        _applied[sessionId] ?? const [],
        now: _clock(),
      );
      outcome = decision.outcome;
      if (decision.next == null) return current;
      _applied[sessionId] = decision.appliedOpIds;
      return decision.next!;
    });
    return StepOpCommit(outcome, saved);
  }
}

/// The pending step changes of one open cooking session.
///
/// Operations are kept until the store answers, are re-applied over every
/// incoming snapshot ([overlay]) so a cached or reconnect snapshot cannot roll
/// the screen back, and are sent one at a time, in order, whenever
/// `isOnline` says so.
class OfflineStepQueue extends ChangeNotifier {
  OfflineStepQueue({
    required this._store,
    required this._isOnline,
    this._connectivityChanges,
    this.retryDelay = const Duration(seconds: 5),
    String Function()? newOpId,
  }) : _newOpId = newOpId ?? const Uuid().v4;

  final StepOpStore _store;
  final bool Function() _isOnline;
  final Stream<void>? _connectivityChanges;
  final String Function() _newOpId;

  /// Wait before retrying a save that failed while the device looked online.
  final Duration retryDelay;

  /// Told about each operation the store answered (it is no longer pending).
  void Function(StepOp op, StepOpCommit commit)? onSettled;

  /// Saves a timer that no pending step change carries.
  Future<void> Function(OpTimer timer)? saveTimer;

  /// Clears the saved timer if, and only if, it is still [timerId].
  Future<void> Function(String timerId)? clearTimer;

  /// Told when a save failed while the device looked online.
  void Function(Object error)? onSaveFailed;

  final List<StepOp> _pending = [];
  OpTimer? _looseTimer;

  /// A dismissed timer that a sent (possibly already saved) step change may
  /// carry. The sent change stays as it was; after it is answered, the timer
  /// is cleared, but only if the session still has this timer.
  String? _clearTimerId;
  String? _sessionId;
  int _epoch = 0;
  Future<void>? _draining;
  Timer? _retry;
  StreamSubscription<void>? _changes;
  bool _disposed = false;

  /// Read live from the one connectivity source; never cached.
  bool get online => _isOnline();
  List<StepOp> get pending => List.unmodifiable(_pending);
  int get pendingSteps => _pending.length;
  bool get hasPendingWork =>
      _pending.isNotEmpty || _looseTimer != null || _clearTimerId != null;

  /// Starts tracking [sessionId]. Work queued for another session is dropped.
  void bind(String sessionId) {
    if (_sessionId == sessionId) return;
    _epoch++;
    _sessionId = sessionId;
    _pending.clear();
    _looseTimer = null;
    _clearTimerId = null;
    _retry?.cancel();
    _changes ??= _connectivityChanges?.listen((_) {
      if (_disposed) return;
      notifyListeners();
      if (online && hasPendingWork) unawaited(flush());
    });
  }

  /// Queues a step change. A timer waiting on its own rides along with it.
  StepOp enqueue({
    required StepOpKind kind,
    required String expectedStepId,
    required String toStepId,
  }) {
    final op = StepOp(
      opId: _newOpId(),
      kind: kind,
      expectedStepId: expectedStepId,
      toStepId: toStepId,
      timer: _looseTimer,
    );
    _looseTimer = null;
    _pending.add(op);
    notifyListeners();
    return op;
  }

  /// Records a timer to save later: with the newest step change if that has
  /// not been sent yet, otherwise on its own after the step changes.
  void recordTimer(OpTimer timer) {
    if (_clearTimerId == timer.id) _clearTimerId = null;
    final last = _pending.lastOrNull;
    if (last != null && !last.sent) {
      last._timer = timer;
    } else {
      _looseTimer = timer;
    }
    notifyListeners();
  }

  /// Forgets a pending timer the cook dismissed. An unsent change drops it;
  /// a sent one is left unchanged and the timer is cleared after it is
  /// answered ([clearTimerLater]). True if a pending change carried it.
  bool dismissTimer(String timerId) {
    var found = false;
    if (_looseTimer?.id == timerId) {
      _looseTimer = null;
      found = true;
    }
    for (final op in _pending) {
      if (op.timer?.id != timerId) continue;
      found = true;
      if (op.sent) {
        _clearTimerId = timerId;
      } else {
        op._timer = null;
      }
    }
    if (found) notifyListeners();
    return found;
  }

  /// Clears the saved timer [timerId] once pending step changes are saved,
  /// and only if the session still holds that timer then.
  void clearTimerLater(String timerId) {
    _clearTimerId = timerId;
    notifyListeners();
  }

  /// [base] (the last saved state) with every pending change re-applied.
  CookingSession overlay(CookingSession base) {
    var s = base;
    for (final op in _pending) {
      if (stepOpApplies(op, s)) {
        s = applyStepOp(op, s).copyWith(revision: s.revision + 1);
      }
    }
    if (_clearTimerId case final id? when s.timerId == id) s = withoutTimer(s);
    final loose = _looseTimer;
    return loose == null ? s : withTimer(s, loose);
  }

  /// Sends pending work if online. Completes when this round is done; work
  /// added while a round runs is picked up by that round or the next.
  Future<void> flush() {
    final running = _draining;
    if (running != null) return running.then((_) => flush());
    final run = _drain();
    _draining = run;
    run.whenComplete(() {
      if (identical(_draining, run)) _draining = null;
    });
    return run;
  }

  Future<void> _drain() async {
    final epoch = _epoch;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    bool current() => !_disposed && epoch == _epoch;
    while (current()) {
      // Read connectivity right before each send.
      if (!online) {
        notifyListeners();
        return;
      }
      final op = _pending.firstOrNull;
      if (op != null) {
        op._sent = true;
        final StepOpCommit commit;
        try {
          commit = await _store.commitStepOp(sessionId, op);
        } catch (error) {
          if (current()) _failed(error);
          return;
        }
        if (!current()) return;
        _pending.remove(op);
        onSettled?.call(op, commit);
        notifyListeners();
        continue;
      }
      final clearId = _clearTimerId;
      final clear = clearTimer;
      if (clearId != null && clear != null) {
        try {
          await clear(clearId);
        } catch (error) {
          if (current()) _failed(error);
          return;
        }
        if (!current()) return;
        if (_clearTimerId == clearId) _clearTimerId = null;
        notifyListeners();
        continue;
      }
      final timer = _looseTimer;
      final save = saveTimer;
      if (timer == null || save == null) return;
      try {
        await save(timer);
      } catch (error) {
        if (current()) _failed(error);
        return;
      }
      if (!current()) return;
      if (identical(_looseTimer, timer)) _looseTimer = null;
      notifyListeners();
    }
  }

  void _failed(Object error) {
    // Offline: the connectivity event resumes. Online (or a platform that
    // cannot tell): retry after a pause.
    if (online) {
      _retry?.cancel();
      _retry = Timer(retryDelay, () {
        if (!_disposed && hasPendingWork) unawaited(flush());
      });
      onSaveFailed?.call(error);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _retry?.cancel();
    unawaited(_changes?.cancel());
    super.dispose();
  }
}
