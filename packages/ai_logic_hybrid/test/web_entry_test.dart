@TestOn('vm')
library;

import 'package:ai_logic_hybrid/src/web/web_hybrid_inference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the web entry point yields no backend off the web', () {
    expect(webHybridInference(), isNull);
  });
}
