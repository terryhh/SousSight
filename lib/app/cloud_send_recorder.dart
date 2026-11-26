// Ledger-backed [CloudSendRecorder], and the Live coach's hook at the
// coordinator/transport boundary (DESIGN.md §5: Live connect and each resume
// write a leg).
//
// Live: [LiveLegTracker] + [LedgeredLiveTransport] make each connect attempt
// and each resume exactly one leg. The AI Logic transport (SS-074) opens the
// leg itself through its guard, right before the socket opens; the wrapper
// settles it. No transport file is changed here.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';

import '../ai/hybrid/hybrid_types.dart';
import '../ai/hybrid/inference_ledger.dart';
import '../core/cloud_send.dart';
import '../live/live_backend_guard.dart' show kLiveFeature, kLiveLegKinds;
import '../live/live_types.dart';

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

  @override
  void notSent(HybridErrorCode code) => _ledger.withdraw(_entry, error: code);
}

/// One Live transport's ledger legs. A leg opens when a socket is about to
/// open ([admitted], the shape of `LiveLegRecorder`, so the AI Logic
/// transport's `LiveCloudGuard.admit` can call it) and is closed by
/// [LedgeredLiveTransport] when the connect or resume settles.
class LiveLegTracker {
  LiveLegTracker(this.recorder);
  final CloudSendRecorder recorder;
  CloudSend? _open;

  bool get hasOpenLeg => _open != null;

  /// A socket is about to open (connect or resume): write a pending leg.
  void admitted(String feature, Set<DataKind> kinds) {
    // A previous leg that never settled did not finish cleanly.
    _open?.failed(HybridErrorCode.network);
    _open = recorder.begin(feature, kinds);
  }

  void confirmed() {
    _open?.confirmed();
    _open = null;
  }

  void failed(HybridErrorCode code) {
    _open?.failed(code);
    _open = null;
  }
}

/// Settles Live legs around [inner]: every connect attempt and every resume
/// is exactly one leg. A failed one stays visible as unknown.
///
/// With [selfRecording] (the AI Logic transport, whose guard calls
/// [LiveLegTracker.admitted] right before each socket opens), this wrapper
/// only settles the legs; a connect or resume refused before its socket opened
/// writes nothing, because nothing was sent. Otherwise (the legacy ephemeral
/// transport) it opens the legs itself: at connect, and at the transport's
/// `LiveConnectionNotice(reconnecting: true)`.
class LedgeredLiveTransport implements LiveTransport {
  LedgeredLiveTransport(this.inner, this.legs, {this.selfRecording = false});

  final LiveTransport inner;
  final LiveLegTracker legs;
  final bool selfRecording;

  @override
  late final Stream<LiveEvent> events = inner.events.transform(
    StreamTransformer<LiveEvent, LiveEvent>.fromHandlers(
      handleData: (event, sink) {
        if (event case LiveConnectionNotice(:final reconnecting)) {
          if (reconnecting) {
            if (!selfRecording && !legs.hasOpenLeg) {
              legs.admitted(kLiveFeature, kLiveLegKinds);
            }
          } else {
            legs.confirmed();
          }
        }
        sink.add(event);
      },
      handleError: (error, stack, sink) {
        legs.failed(HybridErrorCode.network);
        sink.addError(error, stack);
      },
    ),
  );

  @override
  Future<void> connect({required String systemInstruction}) async {
    if (!selfRecording) legs.admitted(kLiveFeature, kLiveLegKinds);
    try {
      await inner.connect(systemInstruction: systemInstruction);
    } on TimeoutException {
      legs.failed(HybridErrorCode.timeout);
      rethrow;
    } catch (_) {
      legs.failed(HybridErrorCode.network);
      rethrow;
    }
    legs.confirmed();
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
    // A connect or resume still open when the session closes did not finish.
    legs.failed(HybridErrorCode.cancelled);
    return inner.close();
  }
}
