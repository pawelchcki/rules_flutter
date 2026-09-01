import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 3) {
    stderr.writeln(
      'usage: run_dart2js.dart <dart> <output-dir> <dart arguments...>',
    );
    exitCode = 64;
    return;
  }

  final dart = arguments[0];
  final outputDir = Directory(arguments[1]);
  final result = await Process.start(
    dart,
    arguments.sublist(2),
    mode: ProcessStartMode.inheritStdio,
  );
  final resultCode = await result.exitCode;
  if (resultCode != 0) {
    exitCode = resultCode;
    return;
  }

  // dart2js emits dependency metadata beside the deployment JavaScript. It is
  // not consumed by Flutter's web bundler, and contains the compiler's absolute
  // working directory (including remote-executor host and action IDs). Keep the
  // declared tree artifact deterministic by dropping only that auxiliary file.
  if (await outputDir.exists()) {
    await for (final entity in outputDir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.deps')) {
        await entity.delete();
      }
    }
  }
}
