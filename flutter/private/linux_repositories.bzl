"""Repository helpers for the hermetic Linux desktop toolchain."""

LINUX_ARCHITECTURES = {
    "amd64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        flutter_arch = "x64",
        gnu_triple = "x86_64-linux-gnu",
        loader = "lib64/ld-linux-x86-64.so.2",
    ),
    "arm64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        flutter_arch = "arm64",
        gnu_triple = "aarch64-linux-gnu",
        loader = "lib/ld-linux-aarch64.so.1",
    ),
}

LINUX_PACKAGES = [
    "binutils",
    "clang",
    "cmake",
    "libgtk-3-dev",
    "libstdc++-12-dev",
    "ninja-build",
    "patchelf",
    "pkg-config",
]

LINUX_PACKAGE_COMPONENTS = ["main", "universe"]
LINUX_PACKAGE_SNAPSHOT = "https://snapshot.ubuntu.com/ubuntu/20250219T154000Z"
LINUX_PACKAGE_SUITES = ["jammy"]

def _linux_toolchains_repository_impl(ctx):
    content = """load("@rules_flutter//flutter:linux_toolchain.bzl", "linux_toolchain")
package(default_visibility = ["//visibility:public"])
"""
    for architecture, meta in LINUX_ARCHITECTURES.items():
        content += """linux_toolchain(
    name = "linux_{architecture}",
    packages = "@{packages_repository}_{architecture}//:files",
    debian_arch = "{architecture}",
    flutter_arch = "{flutter_arch}",
    gnu_triple = "{gnu_triple}",
    loader = "{loader}",
)
toolchain(
    name = "{architecture}_toolchain",
    exec_compatible_with = {compatible_with},
    target_compatible_with = {compatible_with},
    toolchain = ":linux_{architecture}",
    toolchain_type = "@rules_flutter//flutter:linux_toolchain_type",
)
""".format(
            architecture = architecture,
            compatible_with = repr(meta.compatible_with),
            flutter_arch = meta.flutter_arch,
            gnu_triple = meta.gnu_triple,
            loader = meta.loader,
            packages_repository = ctx.attr.packages_repository,
        )
    ctx.file("BUILD.bazel", content)

linux_toolchains_repository = repository_rule(
    implementation = _linux_toolchains_repository_impl,
    attrs = {
        "packages_repository": attr.string(mandatory = True),
    },
)
