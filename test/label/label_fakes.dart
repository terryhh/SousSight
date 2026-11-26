import 'dart:async';
import 'dart:typed_data';

import 'package:ai_logic_hybrid/ai_logic_hybrid.dart';
import 'package:soussight/ai/hybrid/hybrid_types.dart';

/// A minimal JPEG: SOI, an APP0 segment, a baseline SOF0 header, EOI.
Uint8List fakeJpeg({int width = 640, int height = 480, int padTo = 0}) {
  final bytes = <int>[
    0xFF, 0xD8, //
    0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
    0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xFF, 0xC0, 0x00, 0x11, 0x08,
    height >> 8, height & 0xFF, width >> 8, width & 0xFF,
    0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  ];
  while (bytes.length < padTo - 2) {
    bytes.add(0x00);
  }
  bytes.addAll([0xFF, 0xD9]);
  return Uint8List.fromList(bytes);
}

LocalModelLimits _limits({required bool image, int maxTokens = 9216}) =>
    LocalModelLimits(
      modelFamily: image ? 'Gemini Nano' : 'Apple Foundation Models',
      supportsImage: image,
      supportsJsonSchema: image,
      maxTotalTokens: maxTokens,
      defaultOutputReserve: 512,
      imageTokenEstimate: 1000,
      validatedLanguages: const ['en'],
    );

const _allModes = {
  HybridMode.preferOnDevice,
  HybridMode.onlyOnDevice,
  HybridMode.onlyInCloud,
};

/// Web / Android: the local model reads images.
final webCaps = HybridCapabilities(
  platform: 'web',
  local: _limits(image: true),
  supportedModes: _allModes,
);

/// iOS: a local text model with no image input.
final iosCaps = HybridCapabilities(
  platform: 'ios',
  local: _limits(image: false, maxTokens: 4096),
  supportedModes: const {HybridMode.onlyOnDevice, HybridMode.onlyInCloud},
);

/// No local model at all.
const noneCaps = HybridCapabilities.none();

/// Holds each prompt open until the test answers it.
class ManualConsentGate implements ConsentGate {
  final List<ConsentAsk> asks = [];
  final List<Completer<ConsentGrant?>> _pending = [];

  bool get isOpen => _pending.isNotEmpty;

  @override
  Future<ConsentGrant?> request(ConsentAsk ask) {
    asks.add(ask);
    final completer = Completer<ConsentGrant?>();
    _pending.add(completer);
    return completer.future;
  }

  void grant() => _pending.removeAt(0).complete(ConsentGrant(asks.last));
  void grantFor(ConsentAsk ask) =>
      _pending.removeAt(0).complete(ConsentGrant(ask));
  void decline() => _pending.removeAt(0).complete(null);
}

const readableWithPeanut =
    '{"readable": true, "allergensMentioned": ["peanut", "milk"], '
    '"quote": "Contains: milk, peanuts."}';
const unreadableJson =
    '{"readable": false, "allergensMentioned": [], "quote": ""}';
