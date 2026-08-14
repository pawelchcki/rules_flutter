#!/bin/bash
set -euo pipefail

artifacts="$(find -L "${TEST_SRCDIR:-$PWD}" -type d -name 'wasm_app.web_build_artifacts' -print -quit 2>/dev/null)"
if [[ -z "$artifacts" ]]; then
  echo "Wasm web artifact directory not found" >&2
  exit 1
fi

for path in \
  main.dart.wasm \
  main.dart.mjs \
  main.dart.js \
  flutter_bootstrap.js \
  index.html \
  flutter_service_worker.js; do
  if [[ ! -f "$artifacts/$path" ]]; then
    echo "missing Wasm web artifact: $path" >&2
    exit 1
  fi
done

# The normalizer either repairs the cache manifest or preserves Flutter's safe
# retirement worker; both forms must remain syntactically recognizable.
if ! grep -Eq 'const RESOURCES|self\.registration\.unregister\(\)' "$artifacts/flutter_service_worker.js"; then
  echo "service worker has neither normalized resources nor retirement metadata" >&2
  exit 1
fi
