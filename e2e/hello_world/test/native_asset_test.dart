import 'package:asset_fixture/fixture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads a transitive Dart code asset', () {
    expect(rulesFlutterTestSymbol(), 42);
  });
}
