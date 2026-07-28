/// Serving DWDS's injected client, which DWDS cannot serve for itself.
///
/// This file exists to keep one upstream defect in one place. DWDS injects a
/// `<script>` tag for `dwds/src/injected/client.js` into every page it debugs,
/// and answers that request from its own package source with
/// `Isolate.resolvePackageUri('package:dwds/src/injected/client.js')`
/// (`dwds/src/handlers/injector.dart`).
///
/// That resolution cannot work in a Bazel-built binary. In an AOT executable
/// the VM resolves `package:` URIs by searching upward from
/// `Platform.executable` for `.dart_tool/package_config.json`; a binary under
/// `bazel-out/` has none above it, so the lookup returns null, DWDS throws, and
/// shelf turns the exception into a 500 whose String body defaults to
/// `text/plain`. The browser then refuses to execute the script and the page
/// gets no debugging connection — the app renders, and nothing else works.
///
/// Under `dart run` the upward search finds the source checkout's
/// `.dart_tool/`, so this is invisible to any test that launches the tool that
/// way. That is precisely how it shipped.
///
/// The fix is to stop looking for the file at runtime: it is a declared `data`
/// dependency of `//tools/dev_tool:flutter_bazel` and is read from runfiles, so
/// no package resolution is involved and the launch style, working directory
/// and install location are all irrelevant.
///
/// Remove this once DWDS lets an embedder supply the client asset directly.
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

import 'runfiles_helper.dart';

/// Runfiles key for the client, using the apparent repo name — see
/// `runfiles_helper.dart` for why that is what [resolveRunfile] wants.
const dwdsInjectedClientRunfile =
    'dev_tool_deps__dwds/lib/src/injected/client.js';

/// The request path DWDS's injector answers.
///
/// Matched as a suffix: the script tag is emitted relative to whatever path the
/// app is served under, so the request does not always arrive at the root.
const dwdsInjectedClientPath = 'dwds/src/injected/client.js';

/// A located copy of DWDS's injected client, ready to serve.
class DwdsInjectedClient {
  /// Absolute path to the client in runfiles.
  final String path;

  const DwdsInjectedClient(this.path);

  /// Locate the client, or throw explaining what is wrong.
  ///
  /// Called once when the web server starts rather than per request, so a
  /// missing runfile fails the launch with a reason instead of surfacing later
  /// as a blank page and a MIME-type complaint in the browser console.
  factory DwdsInjectedClient.fromRunfiles() {
    final path = resolveRunfile(dwdsInjectedClientRunfile);
    if (path == null) {
      throw StateError(
        "Could not find DWDS's injected client in runfiles "
        '($dwdsInjectedClientRunfile). Web debugging cannot work without it — '
        'the browser would load the app with no debugging connection.\n'
        'Build the dev tool through Bazel so its runfiles are present: '
        'bazel build //tools/dev_tool:flutter_bazel',
      );
    }
    return DwdsInjectedClient(path);
  }

  /// A handler that serves the client and declines everything else.
  ///
  /// Belongs *ahead* of DWDS's own middleware: that middleware claims this path
  /// and is what fails on it, so reaching it at all is the bug. Every other
  /// request 404s, which is how [shelf.Cascade] is told to fall through to the
  /// handlers that own the rest of the URL space.
  shelf.Handler get handler => (request) {
        if (!request.url.path.endsWith(dwdsInjectedClientPath)) {
          return shelf.Response.notFound('');
        }
        return shelf.Response.ok(
          File(path).openRead(),
          headers: {'content-type': 'application/javascript'},
        );
      };
}
