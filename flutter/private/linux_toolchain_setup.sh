#!/bin/bash
# Set up action-local wrappers for the declared Linux package closure. This
# file is sourced by FlutterBuild after its temporary workspace exists.
set -euo pipefail

: "${LINUX_ROOT:?}"
: "${LINUX_LOADER:?}"
: "${LINUX_LIB_PATH:?}"
: "${LINUX_TOOL_BIN:?}"
: "${LINUX_LINKER_SCRIPTS:?}"
: "${LINUX_TOOL_LAUNCHER:?}"
: "${LINUX_CMAKE_INITIAL_CACHE:?}"

mkdir -p "$LINUX_TOOL_BIN" "$LINUX_LINKER_SCRIPTS"

if [ ! -x "$LINUX_LOADER" ]; then
    echo "✗ FATAL ERROR: hermetic Linux loader not found at $LINUX_LOADER" >&2
    exit 1
fi

# Ubuntu's libc development package uses absolute filenames in its two GNU ld
# scripts. Rewrite scratch copies with '=' sysroot markers and put them first
# on the library path; without this, ld would read /lib from the executor.
_linux_linker_script() {
    local source="$1"
    local destination="$2"
    local content
    content="$(<"$source")"
    content="${content// \/usr\/lib/ =\/usr\/lib}"
    content="${content// \/lib/ =\/lib}"
    printf '%s\n' "$content" > "$destination"
}
_linux_linker_script "$LINUX_ROOT/usr/lib/$LINUX_GNU_TRIPLE/libc.so" "$LINUX_LINKER_SCRIPTS/libc.so"
_linux_linker_script "$LINUX_ROOT/usr/lib/$LINUX_GNU_TRIPLE/libm.so" "$LINUX_LINKER_SCRIPTS/libm.so"

_linux_tool_wrapper() {
    local name="$1"
    local mode="$2"
    local binary="$3"
    printf '#!/bin/bash\nexec %q %q %q "$@"\n' \
        "$LINUX_TOOL_LAUNCHER" "$mode" "$binary" > "$LINUX_TOOL_BIN/$name"
    chmod +x "$LINUX_TOOL_BIN/$name"
}

_linux_tool_wrapper clang compiler "$LINUX_ROOT/usr/bin/clang"
_linux_tool_wrapper clang++ compiler "$LINUX_ROOT/usr/bin/clang++"
for tool in ar ld nm objcopy objdump ranlib readelf strip ninja pkg-config; do
    _linux_tool_wrapper "$tool" tool "$LINUX_ROOT/usr/bin/$tool"
done

# CMake records /proc/self/exe as CMAKE_COMMAND and later invokes that path
# from a nested Ninja working directory, bypassing the PATH wrapper. Give it
# an action-local executable whose absolute interpreter and RPATH both point
# at declared toolchain inputs, so the recorded path remains runnable.
CMAKE_HOME="$BUILD_WORKSPACE_TMP/.rules_flutter_linux_cmake"
CMAKE_HERMETIC="$CMAKE_HOME/bin/cmake"
mkdir -p "$CMAKE_HOME/bin"
cp -L "$LINUX_ROOT/usr/bin/cmake" "$CMAKE_HERMETIC"
chmod u+w "$CMAKE_HERMETIC"
# CMake locates Modules as ../share/cmake-<version> from its executable.
ln -s "$LINUX_ROOT/usr/share" "$CMAKE_HOME/share"
"$LINUX_LOADER" --library-path "$LINUX_LIB_PATH" "$LINUX_ROOT/usr/bin/patchelf" \
    --set-interpreter "$LINUX_LOADER" \
    --set-rpath "$LINUX_LIB_PATH" \
    "$CMAKE_HERMETIC"
_linux_tool_wrapper cmake cmake "$CMAKE_HERMETIC"

export LINUX_ROOT LINUX_LOADER LINUX_LIB_PATH LINUX_TOOL_BIN LINUX_LINKER_SCRIPTS
export LINUX_TOOL_LAUNCHER LINUX_CMAKE_INITIAL_CACHE
export PATH="$LINUX_TOOL_BIN:$FLUTTER_ROOT/bin:/usr/bin:/bin"
export PKG_CONFIG_SYSROOT_DIR="$LINUX_ROOT"
export PKG_CONFIG_LIBDIR="$LINUX_ROOT/usr/lib/$LINUX_GNU_TRIPLE/pkgconfig:$LINUX_ROOT/usr/lib/pkgconfig:$LINUX_ROOT/usr/share/pkgconfig"
unset PKG_CONFIG_PATH
