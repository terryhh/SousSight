// The ledger side of an on-demand illustration (SS-098).
//
// Writes straight to the session's [InferenceLedger] so a send has three
// honest endings: confirmed (a cloud answer, read back from the settled
// leg), failed (it may have been sent), or withdrawn (admitted but stopped
// before dispatch: not allowed to leave, nothing sent).

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart'
    show HybridErrorCode, HybridMode;

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_ledger.dart';
import 'illustration_prompts.dart' show kIllustrationFeature;

/// What the settled leg says about a confirmed send.
class IllustrationReceipt {
  const IllustrationReceipt({
    required this.modelLabel,
    required this.provenance,
  });
  final String modelLabel;
  final Provenance provenance;
}

abstract class IllustrationSend {
  /// The leg is still pending in the active ledger. False when a listener
  /// rotated the ledger (a new session) during admission: there is then no
  /// record to send under, so the send must not happen.
  bool get admitted;

  /// The cloud answered. Returns the settled leg's receipt, or null when
  /// the ledger no longer holds this leg (a new session replaced it), in
  /// which case nothing may claim the send.
  IllustrationReceipt? confirmed(String modelLabel);

  /// The send failed after dispatch: it may have been sent.
  void failed(HybridErrorCode code);

  /// Stopped after admission and before dispatch: nothing was sent.
  void withdrawn();
}

abstract class IllustrationLedger {
  /// Admits one pending text-to-image leg. Call before dispatch.
  IllustrationSend begin();
}

class InferenceLedgerIllustrations implements IllustrationLedger {
  InferenceLedgerIllustrations(this.ledger);
  final InferenceLedger ledger;
  int _seq = 0;

  @override
  IllustrationSend begin() => _Send(
    ledger,
    ledger.begin(
      InferenceLeg(
        requestId:
            '$kIllustrationFeature-'
            '${DateTime.now().microsecondsSinceEpoch}-${++_seq}',
        feature: kIllustrationFeature,
        mode: HybridMode.onlyInCloud,
        kinds: const {DataKind.text},
        transferPermitted: true,
        provenance: Provenance.unknown,
      ),
    ),
  );
}

class _Send implements IllustrationSend {
  _Send(this._ledger, this._entry);
  final InferenceLedger _ledger;
  final LedgerEntry _entry;

  bool get _open => _ledger.entries.contains(_entry) && _entry.pending;

  @override
  bool get admitted => _open;

  @override
  IllustrationReceipt? confirmed(String modelLabel) {
    if (!_open) return null;
    _ledger.complete(
      _entry,
      provenance: Provenance.cloudAdapter,
      modelLabel: modelLabel,
    );
    if (!_ledger.entries.contains(_entry) || _entry.pending) return null;
    final leg = _entry.leg;
    return IllustrationReceipt(
      modelLabel: leg.modelLabel ?? modelLabel,
      provenance: leg.provenance,
    );
  }

  @override
  void failed(HybridErrorCode code) {
    if (!_open) return;
    _ledger.complete(_entry, provenance: Provenance.unknown, error: code);
  }

  @override
  void withdrawn() {
    if (!_open) return;
    final leg = _entry.leg;
    // Not allowed to leave: the leg is rewritten before it settles, so the
    // trust view never says "may have been sent" for it.
    _entry.leg = InferenceLeg(
      requestId: leg.requestId,
      feature: leg.feature,
      mode: leg.mode,
      kinds: leg.kinds,
      transferPermitted: false,
      provenance: Provenance.unknown,
    );
    _ledger.complete(
      _entry,
      provenance: Provenance.unknown,
      error: HybridErrorCode.cancelled,
    );
  }
}
