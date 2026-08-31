import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  final bundle = Directory(
    Runfiles.create().rlocation('_main/nested_app/app_flutter_assets'),
  );

  test('application assets use bare paths', () {
    expect(File('${bundle.path}/assets/message.txt').existsSync(), isTrue);
    expect(
      File(
        '${bundle.path}/packages/nested_app/assets/message.txt',
      ).existsSync(),
      isFalse,
    );
  });

  test('application fonts use bare families and paths', () {
    final entries =
        jsonDecode(File('${bundle.path}/FontManifest.json').readAsStringSync())
            as List<dynamic>;
    final font = entries.cast<Map<String, dynamic>>().singleWhere(
      (entry) => entry['family'] == 'NestedFixture',
    );
    expect(
      ((font['fonts'] as List<dynamic>).single
          as Map<String, dynamic>)['asset'],
      'assets/fixture.ttf',
    );
  });
}
