#!/bin/bash
# Asserts the hermeticity guarantee: the Flutter SDK's bin/cache is sealed
# read-only at fetch time, so no build action or run helper can mutate the
# external repository.
set -euo pipefail

FLUTTER_BIN="$(find -L "${TEST_SRCDIR:-$PWD}" -path "*flutter_sdk/bin/flutter" 2>/dev/null | head -n 1)"
if [ -z "$FLUTTER_BIN" ]; then
    echo "✗ flutter binary not found in runfiles" >&2
    exit 1
fi

PYTHON_BIN="$(command -v python3 || command -v python)"
REAL_BIN="$("$PYTHON_BIN" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$FLUTTER_BIN")"
CACHE_DIR="$(dirname "$REAL_BIN")/cache"
FLUTTER_ROOT="$(dirname "$(dirname "$REAL_BIN")")"
TOOL_PUB_CACHE="$FLUTTER_ROOT/packages/flutter_tools/.pub_cache"

if [ ! -d "$CACHE_DIR" ]; then
    echo "✗ SDK cache directory not found at $CACHE_DIR" >&2
    exit 1
fi

if touch "$CACHE_DIR/.rules_flutter_mutation_probe" 2>/dev/null; then
    rm -f "$CACHE_DIR/.rules_flutter_mutation_probe"
    echo "✗ SDK bin/cache is writable; expected it to be sealed read-only at fetch time" >&2
    exit 1
fi

if [ -w "$CACHE_DIR/lockfile" ]; then
    echo "✗ SDK bin/cache/lockfile is writable; expected read-only" >&2
    exit 1
fi

echo "✓ SDK bin/cache is sealed read-only"

if [ -d "$TOOL_PUB_CACHE" ]; then
    if touch "$TOOL_PUB_CACHE/.rules_flutter_mutation_probe" 2>/dev/null; then
        rm -f "$TOOL_PUB_CACHE/.rules_flutter_mutation_probe"
        echo "✗ Flutter-tool PUB_CACHE is writable; expected it to be sealed" >&2
        exit 1
    fi
    if [ -w "$TOOL_PUB_CACHE" ]; then
        echo "✗ Flutter-tool PUB_CACHE directory is writable; expected read-only" >&2
        exit 1
    fi
fi

# Package roots must be portable references into this SDK. In particular, no
# user HOME or original Bazel output-base path may survive fetch-time warming.
"$PYTHON_BIN" - "$FLUTTER_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
configs = [root / "packages" / "flutter_tools" / ".dart_tool" / "package_config.json"]
if not configs[0].is_file():
    raise SystemExit("✗ Flutter-tool package_config.json not found")

for config_path in configs:
    config = json.loads(config_path.read_text())
    for forbidden in ("generated", "flutterRoot", "pubCache"):
        if forbidden in config:
            raise SystemExit(f"✗ {config_path} retains volatile {forbidden} metadata")
    for package in config.get("packages", []):
        uri = package.get("rootUri", "")
        if uri.startswith("file:") or pathlib.PurePosixPath(uri).is_absolute():
            raise SystemExit(f"✗ {config_path} has absolute package root: {uri}")
        package_root = (config_path.parent / uri).resolve()
        try:
            package_root.relative_to(root)
        except ValueError:
            raise SystemExit(f"✗ {config_path} package root escapes SDK: {package_root}")
        if not (package_root / "pubspec.yaml").is_file():
            raise SystemExit(f"✗ {config_path} package root lacks pubspec.yaml: {package_root}")

tool_home = root / "packages" / "flutter_tools" / ".pub_cache"
if tool_home.exists():
    for payload in tool_home.glob("hosted/*/*"):
            if payload.is_dir() and not (payload / "pubspec.yaml").is_file():
                raise SystemExit(f"✗ retained pub-cache entry is not a package payload: {payload}")
PY

echo "✓ Flutter-tool package metadata is relocatable and its cache is sealed"
