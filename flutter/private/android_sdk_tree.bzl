"""Materializes the standard Android SDK directory shape for Gradle."""

def _manifest(ctx, name, files):
    output = ctx.actions.declare_file("{}_{}.manifest".format(ctx.label.name, name))
    ctx.actions.write(output, "\n".join([f.path for f in files]) + "\n")
    return output

def _android_sdk_tree_impl(ctx):
    platform_manifest = _manifest(ctx, "platforms", ctx.files.platform_files)
    component_manifest = _manifest(ctx, "components", ctx.files.component_files)
    ndk_manifest = _manifest(ctx, "ndk", ctx.files.ndk_files)
    output = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run_shell(
        arguments = [output.path, platform_manifest.path, component_manifest.path, ndk_manifest.path],
        command = """
set -eu
out="$1"
platform_manifest="$2"
component_manifest="$3"
ndk_manifest="$4"
mkdir -p "$out/platforms" "$out/build-tools/{build_tools_version}" "$out/platform-tools" "$out/licenses"
# The SDK tree is thousands of files (the NDK alone is ~4GB) that Gradle only
# ever reads. Hardlinking them costs a directory entry each instead of a byte
# copy, while still producing a real directory tree — unlike symlinks, which
# AGP resolves through realpath and would point back into the exec root.
# `link_files=0` (the `copy_mode` attr) restores the byte copies.
LINK_FILES={link_files}
place() {{
  # $1 source, $2 destination.
  if [ "$LINK_FILES" = "1" ] && ln "$1" "$2" 2>/dev/null; then
    return 0
  fi
  cp -p "$1" "$2"
}}
copy_tree() {{
  manifest="$1"
  marker="$2"
  destination="$3"
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    relative="${{source#*${{marker}}}}"
    if [ "$relative" = "$source" ]; then
      echo "Android SDK input '$source' does not contain expected path '$marker'" >&2
      exit 1
    fi
    mkdir -p "$destination/$(dirname "$relative")"
    place "$source" "$destination/$relative"
  done < "$manifest"
}}
copy_tree "$platform_manifest" "/platforms/" "$out/platforms"
while IFS= read -r source; do
  [ -n "$source" ] || continue
  case "$source" in
    *"/build-tools/{platform}/{build_tools_version}/"*)
      relative="${{source#*/build-tools/{platform}/{build_tools_version}/}}"
      mkdir -p "$out/build-tools/{build_tools_version}/$(dirname "$relative")"
      place "$source" "$out/build-tools/{build_tools_version}/$relative"
      ;;
    *"/platform-tools/{platform}/"*)
      relative="${{source#*/platform-tools/{platform}/}}"
      mkdir -p "$out/platform-tools/$(dirname "$relative")"
      place "$source" "$out/platform-tools/$relative"
      ;;
  esac
done < "$component_manifest"
printf '%s\n' '8933bad161af4178b1185d1a37fbf41ea5269c55' > "$out/licenses/android-sdk-license"
if [ -s "$ndk_manifest" ]; then
  mkdir -p "$out/ndk/{ndk_version}"
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    relative="${{source#*external/}}"
    relative="${{relative#*/}}"
    mkdir -p "$out/ndk/{ndk_version}/$(dirname "$relative")"
    place "$source" "$out/ndk/{ndk_version}/$relative"
  done < "$ndk_manifest"
  properties="$out/ndk/{ndk_version}/source.properties"
  if [ ! -f "$properties" ]; then
    echo "Android NDK {ndk_version} is missing source.properties" >&2
    exit 1
  fi
  actual="$(sed -n 's/^Pkg.Revision[[:space:]]*=[[:space:]]*//p' "$properties" | head -n 1)"
  if [ "$actual" != "{ndk_version}" ]; then
    echo "Android NDK revision mismatch: declared {ndk_version}, source.properties contains '${{actual:-missing}}'" >&2
    exit 1
  fi
fi
""".format(
            build_tools_version = ctx.attr.build_tools_version,
            ndk_version = ctx.attr.ndk_version,
            platform = ctx.attr.platform,
            link_files = "0" if ctx.attr.copy_mode else "1",
        ),
        inputs = depset(
            direct = [platform_manifest, component_manifest, ndk_manifest],
            transitive = [
                ctx.attr.platform_files[DefaultInfo].files,
                ctx.attr.component_files[DefaultInfo].files,
                ctx.attr.ndk_files[DefaultInfo].files if ctx.attr.ndk_files else depset(),
            ],
        ),
        outputs = [output],
        mnemonic = "AndroidSdkTree",
        progress_message = "Materializing hermetic Android SDK for %{label}",
    )
    return [DefaultInfo(files = depset([output]))]

android_sdk_tree = rule(
    implementation = _android_sdk_tree_impl,
    attrs = {
        "build_tools_version": attr.string(mandatory = True),
        "component_files": attr.label(mandatory = True),
        "copy_mode": attr.bool(
            default = False,
            doc = """Byte-copy every SDK file instead of hardlinking it. Escape
hatch for filesystems or tools that cannot handle a hardlinked SDK tree.""",
        ),
        "ndk_files": attr.label(),
        "ndk_version": attr.string(),
        "platform": attr.string(mandatory = True),
        "platform_files": attr.label(mandatory = True),
    },
)
