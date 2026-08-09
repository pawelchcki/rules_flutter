"""Generates a package_config.json for a vendored pub repository, once."""

def _sdk_files(flutter_toolchain):
    return flutter_toolchain.flutterinfo.sdk_groups.get(
        "dart",
        flutter_toolchain.flutterinfo.sdk_files,
    )

def _dart_package_config_impl(ctx):
    config = ctx.actions.declare_file(ctx.label.name + "/package_config.json")

    flutter_toolchain = ctx.toolchains["//flutter:toolchain_type"]
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("dart_package_config: no Flutter toolchain is registered.")
    flutter_bin = flutter_toolchain.flutterinfo.tool_files[0]

    # rootUri is emitted relative to the config file's own directory, so the
    # config resolves in any action whose exec root has the same layout — which
    # is every action, sandboxed or not. That is what lets one generated file
    # serve every protoc invocation instead of one synthesis per invocation.
    script = """#!/bin/bash
set -euo pipefail

FLUTTER_ROOT="$(cd "$(dirname "$PWD/{flutter_bin}")/.." && pwd -P)"
export FLUTTER_ROOT
DART_BIN="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
if [ ! -x "$DART_BIN" ]; then
    echo "✗ FATAL ERROR: Dart binary not found at $DART_BIN" >&2
    exit 1
fi

export PUBSPEC_LOCK_PATH="$PWD/{lock}"
export PUB_CACHE_ABS="$PWD/{package_root}/.pub_cache"
export WORKSPACE_ABS="$PWD/{package_root}"
export PACKAGE_CONFIG_PATH="$PWD/{config}"
mkdir -p "$(dirname "$PACKAGE_CONFIG_PATH")"

exec "$DART_BIN" "$PWD/{pub_tool}" package-config
""".format(
        lock = ctx.file.lock.path,
        package_root = ctx.file.lock.dirname,
        config = config.path,
        flutter_bin = flutter_bin.path,
        pub_tool = ctx.file._pub_tool.path,
    )

    ctx.actions.run_shell(
        inputs = depset(
            direct = ctx.files.package_files + [ctx.file._pub_tool, flutter_bin],
            transitive = [_sdk_files(flutter_toolchain)],
        ),
        outputs = [config],
        command = script,
        mnemonic = "DartPackageConfig",
        progress_message = "Generating package_config.json for %{label}",
    )

    return [DefaultInfo(files = depset([config]))]

dart_package_config = rule(
    implementation = _dart_package_config_impl,
    attrs = {
        "package_files": attr.label(
            mandatory = True,
            doc = "All files of the pub repository, including its vendored .pub_cache.",
        ),
        "lock": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The repository's pubspec.lock, whose directory is the package root.",
        ),
        "_pub_tool": attr.label(
            default = Label("//flutter/private:tools/pub_tool.dart"),
            allow_single_file = True,
        ),
    },
    toolchains = ["//flutter:toolchain_type"],
    doc = """Writes a `.dart_tool`-shaped package_config.json resolving a
vendored pub repository's closure, so consumers can pass `dart --packages=`
without synthesizing the config per invocation.""",
)
