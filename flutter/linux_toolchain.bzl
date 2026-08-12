"""Hermetic Linux desktop execution toolchain used by flutter_app."""

LinuxToolchainInfo = provider(
    doc = "Pinned Linux compiler, build tools, headers, and libraries.",
    fields = {
        "debian_arch": "Debian architecture name used by the package closure.",
        "files": "All files required by a Linux desktop build action.",
        "flutter_arch": "Flutter output architecture name (x64 or arm64).",
        "gnu_triple": "GNU multiarch triple used for include and library paths.",
        "loader": "Path of the package closure's dynamic loader, relative to root.",
        "root": "Exec-root-relative root of the extracted Linux package closure.",
    },
)

def _root(target):
    """Return the exec-root-relative root directory of the package closure."""
    files = target[DefaultInfo].files
    values = files.to_list()
    if not values:
        fail("Linux toolchain package closure resolved to no files")

    if len(values) == 1 and values[0].is_directory:
        return values[0].path

    root = target.label.workspace_root
    if root:
        return root

    dirs = {value.dirname: True for value in values}
    if len(dirs) != 1:
        fail(
            ("Linux toolchain package closure ({}) is in the main repository " +
             "and spans several directories ({}), so its root is ambiguous. " +
             "Provide it as a single tree artifact or from an external repository.").format(
                target.label,
                ", ".join(sorted(dirs.keys())),
            ),
        )
    return values[0].dirname

def _linux_toolchain_impl(ctx):
    files = ctx.attr.packages[DefaultInfo].files
    info = LinuxToolchainInfo(
        debian_arch = ctx.attr.debian_arch,
        files = files,
        flutter_arch = ctx.attr.flutter_arch,
        gnu_triple = ctx.attr.gnu_triple,
        loader = ctx.attr.loader,
        root = _root(ctx.attr.packages),
    )
    return [platform_common.ToolchainInfo(linux = info)]

linux_toolchain = rule(
    implementation = _linux_toolchain_impl,
    attrs = {
        "debian_arch": attr.string(mandatory = True),
        "flutter_arch": attr.string(mandatory = True, values = ["arm64", "x64"]),
        "gnu_triple": attr.string(mandatory = True),
        "loader": attr.string(mandatory = True),
        "packages": attr.label(mandatory = True, allow_files = True),
    },
    doc = "Wraps a pinned Linux package closure as a Flutter Linux toolchain.",
)
