// Session-scoped, in-memory record of every inference attempt (DESIGN.md §5).

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter/foundation.dart';

import 'hybrid_types.dart';

/// One leg as the ledger holds it. A leg is written before its send, so it
/// may be [pending]; while pending its provenance is [Provenance.unknown].
class LedgerEntry {
  LedgerEntry._({
    required this.sessionId,
    required this.leg,
    required this.startedAt,
    this.completedAt,
  });

  final String sessionId;
  InferenceLeg leg;
  final DateTime startedAt;
  DateTime? completedAt;

  bool get pending => completedAt == null;

  /// The send was allowed to upload ("allowed to leave").
  bool get allowedToLeave => leg.transferPermitted;

  /// An SDK or adapter reported a cloud answer ("reported as sent").
  bool get reportedSent =>
      leg.provenance == Provenance.sdkCloud ||
      leg.provenance == Provenance.cloudAdapter;

  /// Allowed to upload but the outcome does not say whether data left.
  bool get uploadUnknown =>
      leg.transferPermitted && leg.provenance == Provenance.unknown;
}

class InferenceLedger extends ChangeNotifier {
  InferenceLedger({required this._sessionId, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  String _sessionId;
  int _generation = 0;
  final List<LedgerEntry> _entries = [];

  String get sessionId => _sessionId;

  /// Bumped by every [startSession]. Work that began under an older
  /// generation belongs to a ledger that is gone and must not send.
  int get generation => _generation;
  List<LedgerEntry> get entries => List.unmodifiable(_entries);
  List<InferenceLeg> get legs => [for (final e in _entries) e.leg];

  Iterable<LedgerEntry> get allowedToLeave =>
      _entries.where((e) => e.allowedToLeave);
  Iterable<LedgerEntry> get reportedSent =>
      _entries.where((e) => e.reportedSent);

  /// A new cooking session starts an empty ledger.
  void startSession(String sessionId) {
    _sessionId = sessionId;
    _generation++;
    _entries.clear();
    notifyListeners();
  }

  /// Writes [leg] before its send. Its provenance is recorded as
  /// [Provenance.unknown] until [complete].
  LedgerEntry begin(InferenceLeg leg) {
    final entry = LedgerEntry._(
      sessionId: _sessionId,
      leg: _copy(leg, provenance: Provenance.unknown, error: null),
      startedAt: _clock(),
    );
    _entries.add(entry);
    notifyListeners();
    return entry;
  }

  /// Records the outcome of a leg written with [begin].
  void complete(
    LedgerEntry entry, {
    required Provenance provenance,
    String? modelLabel,
    HybridErrorCode? error,
  }) {
    if (!_entries.contains(entry) || !entry.pending) return;
    entry
      ..leg = _copy(
        entry.leg,
        provenance: provenance,
        modelLabel: modelLabel,
        error: error,
      )
      ..completedAt = _clock();
    notifyListeners();
  }

  /// Writes a finished leg in one step: a blocked fallback, or a send by
  /// another cloud sender (Live connect and each resume, grounded research,
  /// nearby lookups) that reports its own outcome.
  LedgerEntry record(InferenceLeg leg) {
    final now = _clock();
    final entry = LedgerEntry._(
      sessionId: _sessionId,
      leg: leg,
      startedAt: now,
      completedAt: now,
    );
    _entries.add(entry);
    notifyListeners();
    return entry;
  }

  static InferenceLeg _copy(
    InferenceLeg leg, {
    required Provenance provenance,
    String? modelLabel,
    required HybridErrorCode? error,
  }) => InferenceLeg(
    requestId: leg.requestId,
    feature: leg.feature,
    mode: leg.mode,
    kinds: leg.kinds,
    transferPermitted: leg.transferPermitted,
    provenance: provenance,
    modelLabel: modelLabel ?? leg.modelLabel,
    error: error,
  );
}
