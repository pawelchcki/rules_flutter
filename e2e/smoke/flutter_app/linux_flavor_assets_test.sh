#!/bin/bash
set -euo pipefail

artifacts="$(find -L "${TEST_SRCDIR:-$PWD}" -type d -name 'flavored_app.linux_build_artifacts' -print -quit 2>/dev/null)"
if [[ -z "$artifacts" ]]; then
  echo "flavored Linux artifact directory not found" >&2
  exit 1
fi

manifest="$artifacts/data/flutter_assets/AssetManifest.bin"
if [[ ! -f "$manifest" ]]; then
  echo "AssetManifest.bin missing from flavored Linux bundle" >&2
  exit 1
fi

grep -a -q 'assets/common.txt' "$manifest"
grep -a -q 'assets/flavored.txt' "$manifest"
grep -R -a -q 'smoke-flavor-only-asset' "$artifacts/data/flutter_assets"
