#!/bin/bash
set -euo pipefail

RUNFILES_ROOT="${TEST_SRCDIR:-$PWD}"
WORKSPACE="$(find -L "$RUNFILES_ROOT" -path "*codegen_app/lib_prepared_flutter_workspace" -type d 2>/dev/null | head -n 1)"
DART_TOOL="$(find -L "$RUNFILES_ROOT" -path "*codegen_app/lib_dart_tool" -type d 2>/dev/null | head -n 1)"
if [ -z "$WORKSPACE" ] || [ -z "$DART_TOOL" ]; then
    echo "✗ prepared codegen output trees missing from runfiles" >&2
    exit 1
fi

for GENERATED in lib/model.g.dart lib/generated/assets.gen.dart; do
    if [ ! -s "$WORKSPACE/$GENERATED" ]; then
        echo "✗ generated Dart source missing: $GENERATED" >&2
        exit 1
    fi
done

for TREE in "$WORKSPACE/.dart_tool" "$DART_TOOL"; do
    for METADATA in package_config.json package_graph.json; do
        if [ ! -s "$TREE/$METADATA" ]; then
            echo "✗ package metadata missing: $TREE/$METADATA" >&2
            exit 1
        fi
    done
    if [ -e "$TREE/build" ] || [ -e "$TREE/build_resolvers" ]; then
        echo "✗ transient build_runner state leaked into $TREE" >&2
        exit 1
    fi
done

echo "✓ generated sources and package metadata preserved without build_runner state"
