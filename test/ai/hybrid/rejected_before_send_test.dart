// The iOS bridge's pre-send refusal (`rejectedBeforeSend`) still takes a
// cloud-only photo to the Dart adapter, and the ledger can then prove the
// first attempt sent nothing (SS-105). Fakes only.

import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_dispatcher.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/trust/privacy_receipt.dart';
import 'package:soussight/trust/trust_labels.dart';

class _Privacy implements PrivacySettings {
  @override
  bool localOnly(String feature) => false;
}

class _Consent implements ConsentGate {
  int asks = 0;
  @override
  Future<ConsentGrant?> request(ConsentAsk ask) async {
    asks++;
    return ConsentGrant(ask);
  }
}

class _Adapter implements CloudFallbackSender {
  final requests = <HybridRequest>[];
  @override
  Future<HybridResult> send(HybridRequest request) async {
    requests.add(request);
    return HybridResult(
      requestId: request.requestId,
      text: 'adapter answer',
      source: InferenceSource.cloud,
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

void main() {
  test('an iOS pre-send refusal falls back to the adapter, and the receipt '
      'counts one photo request sent, none uncertain', () async {
    final bridge = FakeHybridInference(capabilities: fakeIosCapabilities);
    final adapter = _Adapter();
    final consent = _Consent();
    final ledger = InferenceLedger(sessionId: 's1');
    var seq = 0;
    final dispatcher = DefaultHybridDispatcher(
      inference: bridge,
      privacy: _Privacy(),
      cloudRoutes: CloudRoutes.parse('hybridFallback'),
      consent: consent,
      ledger: ledger,
      cloudFallback: adapter,
      newId: () => 'id-${++seq}',
    );
    bridge.script.add(
      const HybridException(
        HybridErrorCode.rejectedBeforeSend,
        'iOS hybrid sessions are text only',
      ),
    );
    final result = await dispatcher
        .start(
          HybridTask(
            feature: 'label_check',
            parts: [
              const HybridText('What is in the photo?'),
              HybridInlineData(Uint8List.fromList([1, 2, 3]), 'image/jpeg'),
            ],
            maxOutputTokens: 256,
            timeout: const Duration(seconds: 10),
          ),
          sessionId: 's1',
        )
        .result;
    expect(result.text, 'adapter answer');
    expect(adapter.requests, hasLength(1));
    expect(result.legs, hasLength(2));
    final refused = result.legs.first;
    expect(refused.error, HybridErrorCode.rejectedBeforeSend);
    expect(refused.provenance, Provenance.unknown);
    expect(legOutcome(refused), LegOutcome.notFinishedLocal);
    expect(
      errorLabel(HybridErrorCode.rejectedBeforeSend),
      'refused before sending',
    );

    final receipt = PrivacyReceipt.fromLegs(ledger.legs);
    expect(receipt.photoRequestsSent, 1);
    expect(receipt.photoRequestsMaybeSent, 0);
    expect(receipt.maybeSent, isEmpty);
    expect(receipt.summary, endsWith('recorded requests that sent photos: 1.'));
  });
}
