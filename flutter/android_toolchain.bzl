"""Hermetic Android execution toolchain used by flutter_app."""

AndroidToolchainInfo = provider(
    doc = "Pinned Android SDK, optional NDK, and Gradle distribution.",
    fields = {
        "build_tools_version": "Android build-tools version.",
        "files": "All files required by an Android build action.",
        "gradle_home": "Exec-root-relative extracted Gradle distribution root.",
        "gradle_version": "Pinned Gradle version.",
        "ndk_path": "Exec-root-relative NDK root, or None.",
        "ndk_version": "Declared NDK version, or empty string.",
        "sdk_path": "Exec-root-relative Android SDK root.",
        "sdk_version": "Android SDK/API version.",
    },
)

def _root(target, name):
    """Exec-root-relative root directory of a toolchain dependency.

    Derived from the target's own Label rather than by guessing from a file
    path. `label.workspace_root` is exactly `external/<canonical repo name>`
    for an external repo and "" for the main repo, so this needs no knowledge
    of the canonical-name separator (which changed from `~` to `+` in Bazel
    7.1) and, unlike the previous implementation, cannot silently fall through
    to a single file's parent directory when the shape is unexpected.
    """
    files = target[DefaultInfo].files
    values = files.to_list()
    if not values:
        fail("Android toolchain {} resolved to no files".format(name))

    # A single tree artifact is its own root.
    if len(values) == 1 and values[0].is_directory:
        return values[0].path

    root = target.label.workspace_root
    if root:
        return root

    # Main repository: there is no external/<repo> prefix to name, so the
    # containing directory of the files is the root. Reached by in-repo test
    # fixtures; a real hermetic SDK/Gradle always comes from an external repo.
    dirs = {value.dirname: True for value in values}
    if len(dirs) != 1:
        fail(
            ("Android toolchain {} ({}) is in the main repository and spans " +
             "several directories ({}), so its root is ambiguous. Provide it " +
             "as a single tree artifact or from an external repository.").format(
                name,
                target.label,
                ", ".join(sorted(dirs.keys())),
            ),
        )
    return values[0].dirname

def _android_toolchain_impl(ctx):
    sdk = ctx.attr.sdk[DefaultInfo].files
    gradle = ctx.attr.gradle[DefaultInfo].files
    transitive = [sdk, gradle]
    sdk_path = _root(ctx.attr.sdk, "SDK")
    ndk_path = "{}/ndk/{}".format(sdk_path, ctx.attr.ndk_version) if ctx.attr.ndk_version else None

    info = AndroidToolchainInfo(
        sdk_version = ctx.attr.sdk_version,
        build_tools_version = ctx.attr.build_tools_version,
        ndk_version = ctx.attr.ndk_version,
        sdk_path = sdk_path,
        ndk_path = ndk_path,
        gradle_home = _root(ctx.attr.gradle, "Gradle distribution"),
        gradle_version = ctx.attr.gradle_version,
        files = depset(transitive = transitive),
    )
    return [platform_common.ToolchainInfo(android = info)]

android_toolchain = rule(
    implementation = _android_toolchain_impl,
    attrs = {
        "sdk": attr.label(mandatory = True, allow_files = True),
        "gradle": attr.label(mandatory = True, allow_files = True),
        "sdk_version": attr.string(mandatory = True),
        "build_tools_version": attr.string(mandatory = True),
        "ndk_version": attr.string(),
        "gradle_version": attr.string(mandatory = True),
    },
)
