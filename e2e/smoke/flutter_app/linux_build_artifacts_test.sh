#!/bin/bash
# Verifies the complete release bundle emitted by the hermetic Linux build.
set -euo pipefail

# -L: runfiles materialize tree artifacts as symlinked directories.
ARTIFACTS_DIR="$(find -L "${TEST_SRCDIR:-$PWD}" -path "*app.linux_build_artifacts" -type d 2>/dev/null | head -n 1)"
if [ -z "$ARTIFACTS_DIR" ]; then
    echo "✗ app.linux build artifacts not found" >&2
    exit 1
fi

for path in \
    hello_world \
    data/icudtl.dat \
    data/flutter_assets/AssetManifest.bin \
    lib/libapp.so \
    lib/libflutter_linux_gtk.so; do
    if [ ! -f "$ARTIFACTS_DIR/$path" ]; then
        echo "✗ Linux bundle is missing $path" >&2
        exit 1
    fi
done

if [ ! -x "$ARTIFACTS_DIR/hello_world" ]; then
    echo "✗ Linux bundle executable is not executable" >&2
    exit 1
fi

echo "✓ hermetic Linux build emitted a complete release bundle"
