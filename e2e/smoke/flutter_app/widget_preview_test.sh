#!/bin/bash
set -euo pipefail

runner="$(find -L "${TEST_SRCDIR:-$PWD}" -type f -name 'preview_widget_preview_runner.sh' -print -quit 2>/dev/null)"
if [[ -z "$runner" ]]; then
  echo "Widget Preview runner not found" >&2
  exit 1
fi

fixture="${TEST_TMPDIR}/source-workspace"
package_dir="$fixture/flutter_app"
mkdir -p "$package_dir/.widget_preview/nested"
printf 'name: preview_fixture\nenvironment:\n  sdk: ">=3.12.0 <4.0.0"\n' > "$package_dir/pubspec.yaml"
printf 'generated state\n' > "$package_dir/.widget_preview/nested/state"

BUILD_WORKSPACE_DIRECTORY="$fixture" "$runner" clean
if [[ -e "$package_dir/.widget_preview" ]]; then
  echo "Widget Preview clean left generated state behind" >&2
  exit 1
fi

set +e
help_output="$(BUILD_WORKSPACE_DIRECTORY="$fixture" "$runner" start --help 2>&1)"
help_status=$?
set -e
if [[ $help_status -ne 0 ]]; then
  echo "$help_output" >&2
  exit "$help_status"
fi
if ! grep -q 'widget-preview start --web-server --help' <<<"$help_output"; then
  echo "Widget Preview start route was not visible in help output:" >&2
  echo "$help_output" >&2
  exit 1
fi
