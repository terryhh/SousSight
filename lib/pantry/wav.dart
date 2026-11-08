import 'dart:typed_data';

/// Wraps little-endian PCM16 samples in a canonical 44-byte RIFF/WAVE header so
/// the clip can be sent to Gemini as an inline `audio/wav` part.
Uint8List pcm16ToWav(
  Uint8List pcm, {
  int sampleRate = 16000,
  int channels = 1,
}) {
  const bitsPerSample = 16;
  final dataLength = pcm.length - pcm.length % 2;
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final header = ByteData(44)
    ..setUint32(0, 0x52494646) // "RIFF"
    ..setUint32(4, 36 + dataLength, Endian.little)
    ..setUint32(8, 0x57415645) // "WAVE"
    ..setUint32(12, 0x666d7420) // "fmt "
    ..setUint32(16, 16, Endian.little) // PCM fmt chunk size
    ..setUint16(20, 1, Endian.little) // PCM format
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, byteRate, Endian.little)
    ..setUint16(32, channels * bitsPerSample ~/ 8, Endian.little)
    ..setUint16(34, bitsPerSample, Endian.little)
    ..setUint32(36, 0x64617461) // "data"
    ..setUint32(40, dataLength, Endian.little);
  return Uint8List(44 + dataLength)
    ..setRange(0, 44, header.buffer.asUint8List())
    ..setRange(44, 44 + dataLength, pcm);
}
