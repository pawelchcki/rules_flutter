import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  test('resolves the nested package root', () {
    expect(supportedMessage(), 'nested package works');
    expect(supportedMarkerValue(), 0xFF870F57);
  });
}
