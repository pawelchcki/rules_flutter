#!/bin/bash
# Dispatch a tool wrapper created by linux_toolchain_setup.sh.  The setup
# helper exports all LINUX_* values below before any wrapper is invoked.
set -euo pipefail

mode="$1"
binary="$2"
shift 2

_cmake_is_configure() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -E|-P|-N|--build|--install|--open|--find-package|--graphviz|--system-information|--workflow|-h|--help|--help-*|--version|-version)
                return 1
                ;;
        esac
    done
    return 0
}

case "$mode" in
    compiler)
        exec "$LINUX_LOADER" --library-path "$LINUX_LIB_PATH" "$binary" \
            --sysroot="$LINUX_ROOT" \
            -resource-dir="$LINUX_ROOT/usr/lib/llvm-14/lib/clang/14.0.0" \
            -B"$LINUX_TOOL_BIN/" \
            -L"$LINUX_LINKER_SCRIPTS" \
            -Wno-unused-command-line-argument \
            "$@"
        ;;
    cmake)
        if _cmake_is_configure "$@"; then
            exec "$LINUX_LOADER" --library-path "$LINUX_LIB_PATH" "$binary" \
                -C "$LINUX_CMAKE_INITIAL_CACHE" "$@"
        fi
        exec "$LINUX_LOADER" --library-path "$LINUX_LIB_PATH" "$binary" "$@"
        ;;
    tool)
        exec "$LINUX_LOADER" --library-path "$LINUX_LIB_PATH" "$binary" "$@"
        ;;
    *)
        echo "unknown rules_flutter Linux tool mode: $mode" >&2
        exit 2
        ;;
esac
