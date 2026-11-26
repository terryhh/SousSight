// The minimal read interface the trust UI needs from the session ledger.
//
// The real `InferenceLedger` (DESIGN.md §5, card SS-061) lives in
// lib/ai/hybrid/ and is written on another branch. It satisfies this by
// declaring `implements LedgerSource` (or through an adapter); until then the
// trust UI codes against this interface only.

import 'package:flutter/foundation.dart';

import '../ai/hybrid/hybrid_types.dart';

/// Session-scoped, in-memory list of every inference leg, in order.
/// Notifies listeners whenever a leg is added.
abstract class LedgerSource implements Listenable {
  List<InferenceLeg> get legs;
}

/// A simple in-memory [LedgerSource] for tests, Rehearsal mode and as a
/// stand-in until the dispatcher's ledger is wired.
class ListLedgerSource extends ChangeNotifier implements LedgerSource {
  ListLedgerSource([Iterable<InferenceLeg> legs = const []])
    : _legs = [...legs];

  final List<InferenceLeg> _legs;

  @override
  List<InferenceLeg> get legs => List.unmodifiable(_legs);

  void add(InferenceLeg leg) {
    _legs.add(leg);
    notifyListeners();
  }

  void addAll(Iterable<InferenceLeg> legs) {
    _legs.addAll(legs);
    notifyListeners();
  }
}
