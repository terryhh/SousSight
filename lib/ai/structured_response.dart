import 'dart:convert';

/// A schema is a generation aid, not a trust boundary. Reject malformed or
/// oversized results instead of allowing model defaults to imply success.
Map<String, dynamic> decodeObject(String? text) {
  if (text == null || text.length > 16000) {
    throw const FormatException('Missing or oversized model response');
  }
  final value = jsonDecode(text);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object');
  }
  return value;
}

String requiredText(
  Map<String, dynamic> data,
  String key, {
  int maxLength = 600,
}) {
  final value = data[key];
  if (value is! String || value.length > maxLength) {
    throw FormatException('Invalid $key');
  }
  return value.trim();
}

String? nullableText(
  Map<String, dynamic> data,
  String key, {
  int maxLength = 600,
}) {
  if (!data.containsKey(key)) throw FormatException('Missing $key');
  return data[key] == null
      ? null
      : requiredText(data, key, maxLength: maxLength);
}

T requiredEnum<T extends Enum>(
  Map<String, dynamic> data,
  String key,
  List<T> values,
) {
  for (final value in values) {
    if (value.name == data[key]) return value;
  }
  throw FormatException('Invalid $key');
}

String firstWords(String value, int count) =>
    value.trim().split(RegExp(r'\s+')).take(count).join(' ');
