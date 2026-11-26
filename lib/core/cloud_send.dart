// The ledger hook for cloud senders that do not go through the hybrid
// dispatcher: grounded research and the Live coach (DESIGN.md §5).
//
// A sender records at its own boundary, so the ledger never claims more than
// happened:
// - rejected before sending (validation, local checks): [rejectedLocally],
//   a leg that was not allowed to leave;
// - about to transmit: [CloudSendRecorder.begin], a pending leg whose
//   provenance is unknown;
// - refused by a last check after [CloudSendRecorder.begin] but before
//   transmission (a ledger listener may change a setting): [CloudSend.notSent];
// - the cloud answered: [CloudSend.confirmed];
// - transmission failed or timed out: [CloudSend.failed], which keeps the leg
//   as "may have been sent".

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import '../ai/hybrid/hybrid_types.dart';

abstract class CloudSendRecorder {
  /// Call immediately before the data is transmitted.
  CloudSend begin(String feature, Set<DataKind> kinds);

  /// The sender refused the request before anything left this device.
  void rejectedLocally(
    String feature,
    Set<DataKind> kinds,
    HybridErrorCode reason,
  );
}

/// One transmission in flight. The first outcome wins; later calls are
/// ignored.
abstract class CloudSend {
  void confirmed({String? modelLabel});
  void failed(HybridErrorCode code);

  /// Nothing was transmitted after all; the leg becomes not-allowed-to-leave.
  void notSent(HybridErrorCode code);
}
