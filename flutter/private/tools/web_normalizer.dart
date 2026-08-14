// Copyright 2026 The rules_flutter Authors. All rights reserved.
// Use of this source code is governed by the Apache License that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String _fingerprintMarker = '__RULES_FLUTTER_WEB_FINGERPRINT__';

final RegExp _versionValue = RegExp(
  r'''(\bserviceWorkerVersion\s*[:=]\s*["'])([0-9]+)(["'])''',
);
final RegExp _legacyVersionQuery = RegExp(
  r'''(flutter_service_worker\.js\?v=)([0-9]+)(["'`])''',
);
final RegExp _resourcesMap = RegExp(
  r'const\s+RESOURCES\s*=\s*(\{[\s\S]*?\});',
);

/// Normalizes Flutter's generated web cache-busting value in [outputPath].
///
/// [templatesPath] is the project's `web` directory. It lets the normalizer
/// distinguish values produced from Flutter placeholders and legacy templates
/// from deliberately hardcoded application values.
void normalizeWebBuild(String outputPath, String templatesPath) {
  final Directory output = Directory(outputPath);
  if (!output.existsSync()) {
    throw StateError('Web build output does not exist: $outputPath');
  }

  final Directory templates = Directory(templatesPath);
  final List<File> candidates = <File>[];
  final File bootstrap = File('${output.path}${Platform.pathSeparator}flutter_bootstrap.js');
  final File bootstrapTemplate = File(
    '${templates.path}${Platform.pathSeparator}flutter_bootstrap.js',
  );
  final bool bootstrapReceivesVersion = !bootstrapTemplate.existsSync() ||
      _templateDirectlyReceivesFlutterVersion(bootstrapTemplate.readAsStringSync());
  if (bootstrap.existsSync() && bootstrapReceivesVersion) {
    candidates.add(bootstrap);
  }

  if (templates.existsSync()) {
    for (final FileSystemEntity entity in templates.listSync(recursive: true)) {
      if (entity is! File || _basename(entity.path) != 'index.html') {
        continue;
      }
      final String template = entity.readAsStringSync();
      final bool receivesVersion = _templateDirectlyReceivesFlutterVersion(template) ||
          (bootstrapReceivesVersion && template.contains('{{flutter_bootstrap_js}}'));
      if (!receivesVersion) {
        continue;
      }
      final String relative = _relativePath(templates.path, entity.path);
      final File generated = File(_join(output.path, relative));
      if (generated.existsSync()) {
        candidates.add(generated);
      }
    }
  }

  final Set<String> injectedValues = <String>{};
  for (final File file in candidates) {
    final String content = file.readAsStringSync();
    for (final Match match in _versionValue.allMatches(content)) {
      injectedValues.add(match.group(2)!);
    }
    for (final Match match in _legacyVersionQuery.allMatches(content)) {
      injectedValues.add(match.group(2)!);
    }
  }
  if (injectedValues.isEmpty) {
    return;
  }
  if (injectedValues.length != 1) {
    throw StateError(
      'Flutter web templates contain inconsistent injected service-worker versions: '
      '${injectedValues.toList()..sort()}',
    );
  }
  final String injectedValue = injectedValues.single;

  final List<File> normalized = <File>[];
  for (final File file in candidates) {
    final String original = file.readAsStringSync();
    final String marked = _replaceInjectedValue(original, injectedValue, _fingerprintMarker);
    if (marked != original) {
      file.writeAsStringSync(marked);
      normalized.add(file);
    }
  }
  if (normalized.isEmpty) {
    return;
  }

  final String fingerprint = fingerprintWebFiles(output);
  for (final File file in normalized) {
    final String marked = file.readAsStringSync();
    if (!marked.contains(_fingerprintMarker)) {
      throw StateError('Fingerprint marker disappeared from ${file.path}');
    }
    file.writeAsStringSync(marked.replaceAll(_fingerprintMarker, fingerprint));
  }

  _repairServiceWorker(output, normalized);
}

/// Computes the deterministic SHA-256 fingerprint used for a web bundle.
///
/// Files are sorted by slash-separated relative path. Each UTF-8 path and file
/// payload is prefixed by its unsigned 64-bit big-endian byte length. Hidden
/// files and `flutter_service_worker.js` are excluded.
String fingerprintWebFiles(Directory output) {
  final List<File> files = output
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((File file) {
        final String relative = _relativePath(output.path, file.path);
        final List<String> segments = relative.split('/');
        return _basename(file.path) != 'flutter_service_worker.js' &&
            !segments.any((String segment) => segment.startsWith('.'));
      })
      .toList()
    ..sort((File a, File b) =>
        _relativePath(output.path, a.path).compareTo(_relativePath(output.path, b.path)));

  final BytesBuilder fingerprintInput = BytesBuilder(copy: false);
  for (final File file in files) {
    final Uint8List pathBytes = utf8.encode(_relativePath(output.path, file.path));
    final Uint8List fileBytes = file.readAsBytesSync();
    fingerprintInput
      ..add(_uint64BigEndian(pathBytes.length))
      ..add(pathBytes)
      ..add(_uint64BigEndian(fileBytes.length))
      ..add(fileBytes);
  }
  return sha256Hex(fingerprintInput.takeBytes());
}

bool _templateDirectlyReceivesFlutterVersion(String template) {
  return template.contains('{{flutter_service_worker_version}}') ||
      RegExp(r'(?:const|var)\s+serviceWorkerVersion\s*=\s*null').hasMatch(template) ||
      template.contains("navigator.serviceWorker.register('flutter_service_worker.js')") ||
      template.contains('navigator.serviceWorker.register("flutter_service_worker.js")');
}

String _replaceInjectedValue(String content, String oldValue, String newValue) {
  String replace(Match match, int valueGroup) {
    if (match.group(valueGroup) != oldValue) {
      return match.group(0)!;
    }
    return match.group(0)!.replaceFirst(oldValue, newValue);
  }

  return content
      .replaceAllMapped(_versionValue, (Match match) => replace(match, 2))
      .replaceAllMapped(_legacyVersionQuery, (Match match) => replace(match, 2));
}

void _repairServiceWorker(Directory output, List<File> normalized) {
  final File worker = File(_join(output.path, 'flutter_service_worker.js'));
  if (!worker.existsSync() || worker.lengthSync() == 0) {
    return;
  }

  final String content = worker.readAsStringSync();
  final Match? match = _resourcesMap.firstMatch(content);
  if (match == null) {
    // Flutter 3.47+ emits a retirement worker that only unregisters itself
    // and reloads clients. It has no cache manifest to repair.
    if (isRetirementServiceWorker(content)) {
      return;
    }
    throw StateError(
      'Normalized Flutter web files, but flutter_service_worker.js has no safe RESOURCES map',
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(match.group(1)!);
  } on FormatException catch (error) {
    throw StateError('Unable to parse flutter_service_worker.js RESOURCES map: $error');
  }
  if (decoded is! Map<String, dynamic>) {
    throw StateError('flutter_service_worker.js RESOURCES is not a string map');
  }

  final Map<String, dynamic> resources = decoded;
  for (final File file in normalized) {
    final String relative = _relativePath(output.path, file.path);
    if (!resources.containsKey(relative)) {
      throw StateError(
        'Normalized $relative, but flutter_service_worker.js RESOURCES has no matching entry',
      );
    }
    final String digest = md5Hex(file.readAsBytesSync());
    resources[relative] = digest;
    if (relative == 'index.html') {
      if (!resources.containsKey('/')) {
        throw StateError(
          'Normalized root index.html, but flutter_service_worker.js RESOURCES has no / entry',
        );
      }
      resources['/'] = digest;
    }
  }

  final String repairedMatch = match.group(0)!.replaceFirst(
    match.group(1)!,
    jsonEncode(resources),
  );
  final String repaired = content.replaceRange(match.start, match.end, repairedMatch);
  worker.writeAsStringSync(repaired);
}

/// Whether [content] is Flutter's non-caching service-worker retirement shim.
///
/// Public only so the hermetic normalizer test can verify real SDK output.
bool isRetirementServiceWorker(String content) {
  return content.contains('self.registration.unregister()') &&
      RegExp(r'''self\.addEventListener\(["']activate["']''').hasMatch(content) &&
      !RegExp(r'''self\.addEventListener\(["']fetch["']''').hasMatch(content) &&
      !RegExp(r'\bcaches\s*\.').hasMatch(content);
}

Uint8List _uint64BigEndian(int value) {
  final ByteData data = ByteData(8)..setUint64(0, value, Endian.big);
  return data.buffer.asUint8List();
}

String _relativePath(String root, String path) {
  String relative = path.substring(root.length);
  while (relative.startsWith(Platform.pathSeparator)) {
    relative = relative.substring(1);
  }
  return relative.replaceAll(Platform.pathSeparator, '/');
}

String _join(String root, String slashPath) =>
    <String>[root, ...slashPath.split('/')].join(Platform.pathSeparator);

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _hex(Iterable<int> bytes) =>
    bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// Returns a lowercase SHA-256 digest. Public for the pinned-SDK e2e tests.
String sha256Hex(List<int> input) {
  const List<int> constants = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  final BytesBuilder padded = BytesBuilder(copy: false)..add(input);
  padded.addByte(0x80);
  while (padded.length % 64 != 56) {
    padded.addByte(0);
  }
  final ByteData bitLength = ByteData(8)..setUint64(0, input.length * 8, Endian.big);
  padded.add(bitLength.buffer.asUint8List());
  final Uint8List bytes = padded.takeBytes();

  final List<int> hash = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  int rotateRight(int value, int count) =>
      ((value >> count) | (value << (32 - count))) & 0xffffffff;

  for (int offset = 0; offset < bytes.length; offset += 64) {
    final ByteData block = ByteData.sublistView(bytes, offset, offset + 64);
    final List<int> words = List<int>.filled(64, 0);
    for (int index = 0; index < 16; index++) {
      words[index] = block.getUint32(index * 4, Endian.big);
    }
    for (int index = 16; index < 64; index++) {
      final int s0 = rotateRight(words[index - 15], 7) ^
          rotateRight(words[index - 15], 18) ^
          (words[index - 15] >> 3);
      final int s1 = rotateRight(words[index - 2], 17) ^
          rotateRight(words[index - 2], 19) ^
          (words[index - 2] >> 10);
      words[index] =
          (words[index - 16] + s0 + words[index - 7] + s1) & 0xffffffff;
    }

    int a = hash[0];
    int b = hash[1];
    int c = hash[2];
    int d = hash[3];
    int e = hash[4];
    int f = hash[5];
    int g = hash[6];
    int h = hash[7];
    for (int index = 0; index < 64; index++) {
      final int sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      final int choice = (e & f) ^ ((~e) & g);
      final int temp1 = (h + sum1 + choice + constants[index] + words[index]) & 0xffffffff;
      final int sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      final int majority = (a & b) ^ (a & c) ^ (b & c);
      final int temp2 = (sum0 + majority) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }
    final List<int> state = <int>[a, b, c, d, e, f, g, h];
    for (int index = 0; index < 8; index++) {
      hash[index] = (hash[index] + state[index]) & 0xffffffff;
    }
  }

  final ByteData digest = ByteData(32);
  for (int index = 0; index < hash.length; index++) {
    digest.setUint32(index * 4, hash[index], Endian.big);
  }
  return _hex(digest.buffer.asUint8List());
}

/// Returns a lowercase MD5 digest. Public for the pinned-SDK e2e tests.
String md5Hex(List<int> input) {
  const List<int> shifts = <int>[
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
  const List<int> constants = <int>[
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
  ];

  final BytesBuilder padded = BytesBuilder(copy: false)..add(input);
  padded.addByte(0x80);
  while (padded.length % 64 != 56) {
    padded.addByte(0);
  }
  final ByteData bitLength = ByteData(8)..setUint64(0, input.length * 8, Endian.little);
  padded.add(bitLength.buffer.asUint8List());
  final Uint8List bytes = padded.takeBytes();

  final List<int> hash = <int>[0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476];
  int rotateLeft(int value, int count) =>
      ((value << count) | (value >> (32 - count))) & 0xffffffff;

  for (int offset = 0; offset < bytes.length; offset += 64) {
    final ByteData block = ByteData.sublistView(bytes, offset, offset + 64);
    final List<int> words = <int>[
      for (int index = 0; index < 16; index++) block.getUint32(index * 4, Endian.little),
    ];
    int a = hash[0];
    int b = hash[1];
    int c = hash[2];
    int d = hash[3];
    for (int index = 0; index < 64; index++) {
      final int function;
      final int wordIndex;
      if (index < 16) {
        function = (b & c) | ((~b) & d);
        wordIndex = index;
      } else if (index < 32) {
        function = (d & b) | ((~d) & c);
        wordIndex = (5 * index + 1) % 16;
      } else if (index < 48) {
        function = b ^ c ^ d;
        wordIndex = (3 * index + 5) % 16;
      } else {
        function = c ^ (b | (~d));
        wordIndex = (7 * index) % 16;
      }
      final int nextD = d;
      d = c;
      c = b;
      final int sum = (a + function + constants[index] + words[wordIndex]) & 0xffffffff;
      b = (b + rotateLeft(sum, shifts[index])) & 0xffffffff;
      a = nextD;
    }
    hash[0] = (hash[0] + a) & 0xffffffff;
    hash[1] = (hash[1] + b) & 0xffffffff;
    hash[2] = (hash[2] + c) & 0xffffffff;
    hash[3] = (hash[3] + d) & 0xffffffff;
  }

  final ByteData digest = ByteData(16);
  for (int index = 0; index < hash.length; index++) {
    digest.setUint32(index * 4, hash[index], Endian.little);
  }
  return _hex(digest.buffer.asUint8List());
}

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('usage: dart web_normalizer.dart <web-output> <web-templates>');
    exitCode = 64;
    return;
  }
  try {
    normalizeWebBuild(arguments[0], arguments[1]);
  } on Object catch (error) {
    stderr.writeln('Web normalization failed: $error');
    exitCode = 1;
  }
}
