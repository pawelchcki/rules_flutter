import 'package:test/test.dart';

// Import the library directly.
import '../merge_plists.dart';

/// `macos/Runner/DebugProfile.entitlements` exactly as `flutter create`
/// emits it.
const _debugProfile = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
''';

/// `macos/Runner/Release.entitlements` exactly as `flutter create` emits it.
const _release = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
''';

/// The addition a networked app writes once and gets in both configurations.
const _networkAddition = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
''';

/// rules_flutter's own iOS Dart VM service supplement.
const _vmServiceSupplement = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSBonjourServices</key>
    <array>
        <string>_dartVmService._tcp</string>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Allow Flutter tools to find and connect to the Dart VM service.</string>
</dict>
</plist>
''';

String merge(
  String? base,
  List<String> additions, {
  MergeMode mode = MergeMode.strictAdd,
}) =>
    mergePlists(
      base: base == null ? null : (path: 'base.entitlements', xml: base),
      additionSources: [
        for (var i = 0; i < additions.length; i++)
          (path: 'addition$i.entitlements', xml: additions[i]),
      ],
      mode: mode,
    );

/// The keys of a rendered plist, in order.
List<String> keysOf(String plist) =>
    parsePlist(plist, 'rendered').map((e) => e.key).toList();

String valueOf(String plist, String key) =>
    parsePlist(plist, 'rendered').firstWhere((e) => e.key == key).rawValue;

void main() {
  group('strict-add', () {
    test('adds a key the base does not declare', () {
      final merged = merge(_release, [_networkAddition]);
      expect(
        keysOf(merged),
        containsAll([
          'com.apple.security.app-sandbox',
          'com.apple.security.network.client',
          'com.apple.security.network.server',
        ]),
      );
    });

    test('preserves base keys and their order', () {
      final merged = merge(_release, [_networkAddition]);
      expect(keysOf(merged).first, 'com.apple.security.app-sandbox');
    });

    test('dedupes a key the base already declares with the same value', () {
      // The load-bearing case: DebugProfile.entitlements already grants
      // network.server, and the same addition is merged into both configs.
      final merged = merge(_debugProfile, [_networkAddition]);
      expect(
        keysOf(merged).where((k) => k == 'com.apple.security.network.server'),
        hasLength(1),
      );
      expect(keysOf(merged), contains('com.apple.security.network.client'));
    });

    test('is insensitive to whitespace when comparing values', () {
      const spaced = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true />
</dict>
</plist>
''';
      expect(() => merge(_release, [spaced]), returnsNormally);
    });

    test('hard-fails on a key the base declares with a different value', () {
      const conflicting = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
</dict>
</plist>
''';
      expect(
        () => merge(_release, [conflicting]),
        throwsA(isA<PlistFormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('com.apple.security.app-sandbox'),
            contains('base.entitlements'),
            contains('addition0.entitlements'),
          ),
        )),
      );
    });

    test('merges several additions in order', () {
      const extra = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
</dict>
</plist>
''';
      final merged = merge(_release, [_networkAddition, extra]);
      expect(
        keysOf(merged),
        containsAll([
          'com.apple.security.network.client',
          'com.apple.security.files.user-selected.read-write',
        ]),
      );
    });

    test('merges into an absent base (iOS ships no Runner.entitlements)', () {
      final merged = merge(null, [_networkAddition]);
      expect(keysOf(merged), [
        'com.apple.security.network.client',
        'com.apple.security.network.server',
      ]);
    });

    test('carries nested values through verbatim', () {
      const nested = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.example.app</string>
	</array>
</dict>
</plist>
''';
      final merged = merge(_release, [nested]);
      expect(
        valueOf(merged, 'com.apple.security.application-groups'),
        contains('group.com.example.app'),
      );
    });
  });

  group('supplement', () {
    test('adds the VM service keys to a plist that has neither', () {
      const appPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Runner</string>
</dict>
</plist>
''';
      final merged = merge(appPlist, [_vmServiceSupplement],
          mode: MergeMode.supplement);
      expect(keysOf(merged), [
        'CFBundleName',
        'NSBonjourServices',
        'NSLocalNetworkUsageDescription',
      ]);
    });

    test('keeps the app\'s own usage description', () {
      const appPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Tin Can finds peers on your network.</string>
</dict>
</plist>
''';
      final merged = merge(appPlist, [_vmServiceSupplement],
          mode: MergeMode.supplement);
      expect(
        valueOf(merged, 'NSLocalNetworkUsageDescription'),
        contains('Tin Can finds peers on your network.'),
      );
    });

    test('unions NSBonjourServices with the app\'s own services', () {
      const appPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>NSBonjourServices</key>
	<array>
		<string>_tincan._udp</string>
	</array>
</dict>
</plist>
''';
      final merged = merge(appPlist, [_vmServiceSupplement],
          mode: MergeMode.supplement);
      final services = valueOf(merged, 'NSBonjourServices');
      expect(services, contains('_tincan._udp'));
      expect(services, contains('_dartVmService._tcp'));
    });

    test('does not duplicate a service the app already declares', () {
      const appPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>NSBonjourServices</key>
	<array>
		<string>_dartVmService._tcp</string>
	</array>
</dict>
</plist>
''';
      final merged = merge(appPlist, [_vmServiceSupplement],
          mode: MergeMode.supplement);
      final services = valueOf(merged, 'NSBonjourServices');
      expect('_dartVmService._tcp'.allMatches(services), hasLength(1));
    });

    test('keeps the base value when the types are not both string arrays', () {
      const appPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>NSBonjourServices</key>
	<string>not-an-array</string>
</dict>
</plist>
''';
      final merged = merge(appPlist, [_vmServiceSupplement],
          mode: MergeMode.supplement);
      expect(valueOf(merged, 'NSBonjourServices'), contains('not-an-array'));
    });
  });

  group('parsePlist rejects what it cannot merge', () {
    test('a document with no <plist> root', () {
      expect(
        () => parsePlist('<dict/>', 'x.plist'),
        throwsA(isA<PlistFormatException>()
            .having((e) => e.message, 'message', contains('<plist>'))),
      );
    });

    test('a plist whose root is an array', () {
      const arrayRoot = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<array/>
</plist>
''';
      expect(
        () => parsePlist(arrayRoot, 'x.plist'),
        throwsA(isA<PlistFormatException>()
            .having((e) => e.message, 'message', contains('<dict>'))),
      );
    });

    test('a duplicate key in one dict', () {
      const dupe = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>a</key>
	<true/>
	<key>a</key>
	<false/>
</dict>
</plist>
''';
      expect(
        () => parsePlist(dupe, 'x.plist'),
        throwsA(isA<PlistFormatException>()
            .having((e) => e.message, 'message', contains('twice'))),
      );
    });

    test('a value with no preceding key', () {
      const orphan = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<true/>
</dict>
</plist>
''';
      expect(
        () => parsePlist(orphan, 'x.plist'),
        throwsA(isA<PlistFormatException>()
            .having((e) => e.message, 'message', contains('<key>'))),
      );
    });

    test('a key with no value', () {
      const keyless = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>a</key>
</dict>
</plist>
''';
      expect(
        () => parsePlist(keyless, 'x.plist'),
        throwsA(isA<PlistFormatException>()
            .having((e) => e.message, 'message', contains('no value'))),
      );
    });
  });
}
