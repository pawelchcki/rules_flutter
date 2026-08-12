#!/bin/bash
set -euo pipefail

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "expected '$needle' in '$haystack'"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" != *"$needle"* ]] || fail "did not expect '$needle' in '$haystack'"
}

runfile() {
    local path="$1"
    if [[ -n "${RUNFILES_DIR:-}" && -e "$RUNFILES_DIR/$path" ]]; then
        printf '%s\n' "$RUNFILES_DIR/$path"
        return
    fi
    printf '%s\n' "$TEST_SRCDIR/$path"
}

workspace="${TEST_WORKSPACE:-rules_flutter}"
setup="$(runfile "$workspace/flutter/private/linux_toolchain_setup.sh")"
launcher="$(runfile "$workspace/flutter/private/linux_tool_launcher.sh")"
initial_cache="$(runfile "$workspace/flutter/private/linux_cmake_initial_cache.cmake")"

test_root="$(mktemp -d "${TEST_TMPDIR:-/tmp}/linux-toolchain-setup.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
root="$test_root/root"
mkdir -p "$root/lib64" "$root/usr/bin" "$root/usr/share" "$root/usr/lib/x86_64-linux-gnu"

# The fake loader accepts the invocation shape used by the real dynamic loader
# and runs the requested fake package binary.
printf '%s\n' '#!/bin/bash' 'set -euo pipefail' \
    '[[ "$1" == "--library-path" ]] && shift 2' 'exec "$@"' > "$root/lib64/ld-linux-x86-64.so.2"
chmod +x "$root/lib64/ld-linux-x86-64.so.2"

printf '%s\n' '#!/bin/bash' 'exit 0' > "$root/usr/bin/patchelf"
chmod +x "$root/usr/bin/patchelf"
printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "$@" > "$TOOL_TEST_LOG"' > "$root/usr/bin/clang"
chmod +x "$root/usr/bin/clang"
cp "$root/usr/bin/clang" "$root/usr/bin/clang++"

printf '%s\n' 'GROUP ( /usr/lib/libc.so.6 /lib/libc.so.6 )' > "$root/usr/lib/x86_64-linux-gnu/libc.so"
printf '%s\n' 'GROUP ( /usr/lib/libm.so.6 /lib/libm.so.6 )' > "$root/usr/lib/x86_64-linux-gnu/libm.so"

# The setup helper copies this fake CMake into its action-local relocation.
printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "$@" > "$CMAKE_TEST_LOG"' > "$root/usr/bin/cmake"
chmod +x "$root/usr/bin/cmake"
for tool in ar ld nm objcopy objdump ranlib readelf strip ninja pkg-config; do
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$root/usr/bin/$tool"
    chmod +x "$root/usr/bin/$tool"
done

export BUILD_WORKSPACE_TMP="$test_root/workspace"
export FLUTTER_ROOT="$test_root/flutter"
export LINUX_ROOT="$root"
export LINUX_LOADER="$root/lib64/ld-linux-x86-64.so.2"
export LINUX_LIB_PATH="$root/lib:$root/usr/lib"
export LINUX_TOOL_BIN="$BUILD_WORKSPACE_TMP/bin"
export LINUX_LINKER_SCRIPTS="$BUILD_WORKSPACE_TMP/linker-scripts"
export LINUX_GNU_TRIPLE="x86_64-linux-gnu"
export LINUX_TOOL_LAUNCHER="$launcher"
export LINUX_CMAKE_INITIAL_CACHE="$initial_cache"
source "$setup"

[[ "$PATH" == "$LINUX_TOOL_BIN:"* ]] || fail "tool wrappers were not prepended to PATH"
[[ "$PKG_CONFIG_SYSROOT_DIR" == "$root" ]] || fail "missing pkg-config sysroot"
assert_contains "$PKG_CONFIG_LIBDIR" "$root/usr/lib/x86_64-linux-gnu/pkgconfig"
[[ -x "$LINUX_TOOL_BIN/clang" && -x "$LINUX_TOOL_BIN/cmake" ]] || fail "wrappers were not created"
assert_contains "$(<"$LINUX_LINKER_SCRIPTS/libc.so")" '=/usr/lib'
assert_contains "$(<"$LINUX_LINKER_SCRIPTS/libm.so")" '=/lib'

export TOOL_TEST_LOG="$test_root/compiler.log"
"$LINUX_TOOL_BIN/clang" -c hello.cc
compiler_args="$(<"$TOOL_TEST_LOG")"
assert_contains "$compiler_args" "--sysroot=$root"
assert_contains "$compiler_args" "-resource-dir=$root/usr/lib/llvm-14/lib/clang/14.0.0"
assert_contains "$compiler_args" "-B$LINUX_TOOL_BIN/"
assert_contains "$compiler_args" "-L$LINUX_LINKER_SCRIPTS"
assert_contains "$compiler_args" '-c'

export CMAKE_TEST_LOG="$test_root/cmake.log"
"$LINUX_TOOL_BIN/cmake" -S source -B build -DCMAKE_TOOLCHAIN_FILE=consumer-toolchain.cmake
cmake_args="$(<"$CMAKE_TEST_LOG")"
assert_contains "$cmake_args" '-C'
assert_contains "$cmake_args" "$initial_cache"
assert_contains "$cmake_args" '-DCMAKE_TOOLCHAIN_FILE=consumer-toolchain.cmake'

for mode in '-E echo command' '-P script.cmake' '--build build' '--help' '--version'; do
    # Intentional word splitting: each test mode is a tiny fixed argument list.
    "$LINUX_TOOL_BIN/cmake" $mode
    cmake_args="$(<"$CMAKE_TEST_LOG")"
    assert_not_contains "$cmake_args" "$initial_cache"
done
