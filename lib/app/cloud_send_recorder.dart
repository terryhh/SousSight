// Ledger-backed [CloudSendRecorder], and the Live coach's hook at the
// coordinator/transport boundary (DESIGN.md §5: Live connect and each resume
// write a leg).
//
// The Live hook is a decorator over any [LiveTransport]; it does not change
// the transports themselves. It records:
// - every connect attempt (pending until connect returns; a failure stays
//   visible as "may have been sent");
// - every resume, detected from the transports' own events: a
//   `LiveConnectionNotice(reconnecting: true)` opens a leg, the next
//   non-reconnecting notice confirms it, and a stream error fails it.
// SS-074 (`lib/live/live_backend*`) can wrap its AI Logic transport with
// [LedgeredLiveTransport] instead of adding a second hook.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_ledger.dart';
import '../core/cloud_send.dart';
import '../live/live_types.dart';

/// Ledger key for Live coach legs.
const kLiveFeature = 'live';

class LedgerCloudSendRecorder implements CloudSendRecorder {
  LedgerCloudSendRecorder(this.ledger);
  final InferenceLedger ledger;
  int _seq = 0;

  String _id(String feature) =>
      '$feature-${DateTime.now().microsecondsSinceEpoch}-${++_seq}';

  @override
  CloudSend begin(String feature, Set<DataKind> kinds) => _LedgerSend(
    ledger,
    ledger.begin(
      InferenceLeg(
        requestId: _id(feature),
        feature: feature,
        mode: HybridMode.onlyInCloud,
        kinds: kinds,
        transferPermitted: true,
        provenance: Provenance.unknown,
      ),
    ),
  );

  @override
  void rejectedLocally(
    String feature,
    Set<DataKind> kinds,
    HybridErrorCode reason,
  ) => ledger.record(
    InferenceLeg(
      requestId: _id(feature),
      feature: feature,
      mode: HybridMode.onlyInCloud,
      kinds: kinds,
      transferPermitted: false,
      provenance: Provenance.unknown,
      error: reason,
    ),
  );
}

class _LedgerSend implements CloudSend {
  _LedgerSend(this._ledger, this._entry);
  final InferenceLedger _ledger;
  final LedgerEntry _entry;

  @override
  void confirmed({String? modelLabel}) => _ledger.complete(
    _entry,
    provenance: Provenance.cloudAdapter,
    modelLabel: modelLabel,
  );

  @override
  void failed(HybridErrorCode code) =>
      _ledger.complete(_entry, provenance: Provenance.unknown, error: code);
}

/// Records Live connect attempts and resumes around [inner].
class LedgeredLiveTransport implements LiveTransport {
  LedgeredLiveTransport(this.inner, this.recorder);

  final LiveTransport inner;
  final CloudSendRecorder recorder;

  static const _kinds = {DataKind.text, DataKind.image, DataKind.audio};
  CloudSend? _resume;

  @override
  late final Stream<LiveEvent> events = inner.events.transform(
    StreamTransformer<LiveEvent, LiveEvent>.fromHandlers(
      handleData: (event, sink) {
        if (event case LiveConnectionNotice(:final reconnecting)) {
          if (reconnecting) {
            _resume ??= recorder.begin(kLiveFeature, _kinds);
          } else {
            _resume?.confirmed();
            _resume = null;
          }
        }
        sink.add(event);
      },
      handleError: (error, stack, sink) {
        _resume?.failed(HybridErrorCode.network);
        _resume = null;
        sink.addError(error, stack);
      },
    ),
  );

  @override
  Future<void> connect({required String systemInstruction}) async {
    final send = recorder.begin(kLiveFeature, _kinds);
    try {
      await inner.connect(systemInstruction: systemInstruction);
    } on TimeoutException {
      send.failed(HybridErrorCode.timeout);
      rethrow;
    } catch (_) {
      send.failed(HybridErrorCode.network);
      rethrow;
    }
    send.confirmed();
  }

  @override
  Future<void> sendAudio(Uint8List pcm16khz) => inner.sendAudio(pcm16khz);

  @override
  Future<void> sendVideo(Uint8List jpeg) => inner.sendVideo(jpeg);

  @override
  Future<void> sendText(String text) => inner.sendText(text);

  @override
  Future<void> respondToTool(
    LiveToolCall call,
    Map<String, Object?> response,
  ) => inner.respondToTool(call, response);

  @override
  Future<void> close() {
    // A resume still open when the session closes did not finish.
    _resume?.failed(HybridErrorCode.cancelled);
    _resume = null;
    return inner.close();
  }
}
