import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';
import 'package:soussight/ai/hybrid/inference_ledger.dart';
import 'package:soussight/ai/hybrid/payload_digest.dart';

InferenceLeg _leg(
  String id, {
  bool transfer = true,
  Provenance p = Provenance.unknown,
}) => InferenceLeg(
  requestId: id,
  feature: 'pantry_scan',
  mode: HybridMode.preferOnDevice,
  kinds: const {DataKind.text},
  transferPermitted: transfer,
  provenance: p,
);

void main() {
  group('InferenceLedger', () {
    test(
      'a leg is pending and unknown until completed, and listeners hear both',
      () {
        var t = DateTime.utc(2026, 11, 25, 12);
        final ledger = InferenceLedger(sessionId: 's1', clock: () => t);
        var notified = 0;
        ledger.addListener(() => notified++);

        final entry = ledger.begin(_leg('r1', p: Provenance.sdkOnDevice));
        expect(entry.pending, isTrue);
        expect(
          entry.leg.provenance,
          Provenance.unknown,
          reason: 'never claim a source before the SDK reports one',
        );
        expect(entry.uploadUnknown, isTrue);

        t = t.add(const Duration(seconds: 2));
        ledger.complete(
          entry,
          provenance: Provenance.sdkCloud,
          modelLabel: 'gemini-x',
        );
        expect(entry.pending, isFalse);
        expect(
          entry.completedAt!.difference(entry.startedAt),
          const Duration(seconds: 2),
        );
        expect(entry.leg.provenance, Provenance.sdkCloud);
        expect(entry.leg.modelLabel, 'gemini-x');
        expect(entry.reportedSent, isTrue);
        expect(notified, 2);

        ledger.complete(entry, provenance: Provenance.sdkOnDevice);
        expect(
          entry.leg.provenance,
          Provenance.sdkCloud,
          reason: 'completion is final',
        );
      },
    );

    test('other cloud senders record finished legs; views separate allowed from sent', () {
      final ledger = InferenceLedger(sessionId: 's1');
      ledger.record(_leg('live-connect', p: Provenance.cloudAdapter));
      ledger.record(_leg('local', transfer: false, p: Provenance.sdkOnDevice));
      final e = ledger.begin(_leg('failed'));
      ledger.complete(
        e,
        provenance: Provenance.unknown,
        error: HybridErrorCode.network,
      );

      expect(ledger.allowedToLeave.map((e) => e.leg.requestId), [
        'live-connect',
        'failed',
      ]);
      expect(ledger.reportedSent.map((e) => e.leg.requestId), ['live-connect']);
      expect(ledger.entries.every((e) => e.sessionId == 's1'), isTrue);
    });

    test('a new session starts empty and late completions from the old one are ignored', () {
      final ledger = InferenceLedger(sessionId: 's1');
      final old = ledger.begin(_leg('r1'));
      ledger.startSession('s2');
      expect(ledger.entries, isEmpty);
      ledger.complete(old, provenance: Provenance.sdkCloud);
      expect(ledger.entries, isEmpty);
      expect(ledger.record(_leg('r2')).sessionId, 's2');
    });
  });

  group('payload digest', () {
    test('sha256 matches FIPS 180-4 vectors', () {
      expect(
        sha256Hex(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        sha256Hex(
          utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      expect(
        sha256Hex(List<int>.filled(1000000, 0x61)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('changes with any byte that could leave the device', () {
      HybridTask t({String text = 'hi', int byte = 1, String? si}) =>
          HybridTask(
            feature: 'pantry_scan',
            systemInstruction: si,
            parts: [
              HybridText(text),
              HybridInlineData(Uint8List.fromList([byte]), 'image/jpeg'),
            ],
            maxOutputTokens: 10,
            timeout: const Duration(seconds: 1),
          );
      final base = hybridPayloadDigest(t());
      expect(hybridPayloadDigest(t()), base);
      expect(hybridPayloadDigest(t(text: 'hj')), isNot(base));
      expect(hybridPayloadDigest(t(byte: 2)), isNot(base));
      expect(hybridPayloadDigest(t(si: 'x')), isNot(base));
    });

    test('data kinds come from parts', () {
      final task = HybridTask(
        feature: 'pantry_voice',
        parts: [
          HybridInlineData(Uint8List(1), 'audio/webm'),
          HybridInlineData(Uint8List(1), 'image/png'),
        ],
        maxOutputTokens: 1,
        timeout: const Duration(seconds: 1),
      );
      expect(taskDataKinds(task), {DataKind.audio, DataKind.image});
    });
  });
}
