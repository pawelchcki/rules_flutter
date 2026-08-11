#!/bin/bash
set -euo pipefail

DART_BIN="$(find -L "${TEST_SRCDIR:-$PWD}" -path "*flutter_sdk/bin/dart" -type f 2>/dev/null | head -n 1)"
NORMALIZER_TEST="$(find -L "${TEST_SRCDIR:-$PWD}" -path "*/flutter/private/tools/web_normalizer_test.dart" -type f 2>/dev/null | head -n 1)"
if [ -z "$DART_BIN" ] || [ -z "$NORMALIZER_TEST" ]; then
    echo "✗ web normalizer test inputs missing from runfiles" >&2
    exit 1
fi

"$DART_BIN" "$NORMALIZER_TEST"
