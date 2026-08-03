import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:flutter_bazel_dev_tool/web_module_server.dart';
import 'package:test/test.dart';

WebModuleServer serverWith({String? packageConfigPath}) => WebModuleServer(
      webToolchain: WebToolchainPaths(
        ddcOutlineDill: '/nonexistent/ddc_outline.dill',
        librariesSpec: '/nonexistent/libraries.json',
        dartSdkJs: '/nonexistent/dart_sdk.js',
        ddcModuleLoaderJs: '/nonexistent/ddc_module_loader.js',
        stackTraceMapperJs: '/nonexistent/stack_trace_mapper.js',
        dartSdkRoot: '/nonexistent/dart-sdk',
      ),
      buildOutputDir: '/nonexistent/web',
      entrypointFilename: 'web_entrypoint.dart',
      engineRevision: 'deadbeef',
      dartExecutable: '/nonexistent/dart',
      packageConfigPath: packageConfigPath,
    );

/// Never invoked: every case here throws before `Dwds.start` would reach for a
/// browser. Failing loudly rather than returning a stub keeps a regression that
/// *does* get this far from looking like a pass.
Future<Never> noChrome() async =>
    throw StateError('DWDS must not reach Chrome in these tests');

void main() {
  group('WebModuleServer.initDwds', () {
    test('refuses to start with no package config', () {
      expect(
        () => serverWith().initDwds(chromeConnection: noChrome),
        throwsA(isA<DevToolException>().having(
            (e) => e.message, 'message', contains('package_config.json'))),
      );
    });

    test('names the file when the package config is missing', () {
      const missing = '/nonexistent/package_config.json';
      expect(
        () => serverWith(packageConfigPath: missing)
            .initDwds(chromeConnection: noChrome),
        throwsA(isA<DevToolException>()
            .having((e) => e.message, 'message', contains(missing))),
      );
    });

    test('names the file when the package config is malformed', () async {
      final dir = await Directory.systemTemp.createTemp('web_module_server_');
      addTearDown(() => dir.delete(recursive: true));
      final config = File('${dir.path}/package_config.json');
      await config.writeAsString('{ this is not json');

      await expectLater(
        () => serverWith(packageConfigPath: config.path)
            .initDwds(chromeConnection: noChrome),
        throwsA(isA<DevToolException>()
            .having((e) => e.message, 'message', contains(config.path))),
      );
    });

    test('exposes no connectedApps stream until DWDS starts', () {
      // The run wires its VM service off this stream. `null` here is what the
      // old `initDwds` left behind when it gave up, and `run_command` skipped
      // the whole wiring block without a word.
      expect(serverWith().connectedApps, isNull);
    });
  });
}
