/// The failure type that ends a dev tool command.
///
/// Its own library rather than a declaration inside `run_command.dart` so the
/// machinery a command drives — the web module server, chiefly — can raise a
/// run-ending failure without importing the command that drives it.
/// `run_command.dart` re-exports it, so `import 'run_command.dart'` keeps
/// working.
library;

/// Exception thrown by dev tool commands to indicate failure with an exit code.
///
/// Replaces direct `exit()` calls so callers can catch and handle gracefully.
class DevToolException implements Exception {
  final String message;
  final int exitCode;

  DevToolException(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}
