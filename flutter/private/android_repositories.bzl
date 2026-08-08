"""Repositories composing upstream Android archives with Gradle."""

_PLATFORMS = {
    "darwin": ["@platforms//os:macos"],
    "linux": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "windows": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

def _gradle_repository_impl(ctx):
    ctx.download_and_extract(
        url = ctx.attr.url,
        integrity = ctx.attr.integrity,
        stripPrefix = "gradle-{}".format(ctx.attr.version),
    )
    ctx.file("BUILD.bazel", """package(default_visibility = [\"//visibility:public\"])
filegroup(name = \"gradle\", srcs = [\".\"])
""")

gradle_repository = repository_rule(
    implementation = _gradle_repository_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "integrity": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

def _android_toolchains_repository_impl(ctx):
    content = """load(\"@rules_flutter//flutter:android_toolchain.bzl\", \"android_toolchain\")
load(\"@rules_flutter//flutter/private:android_sdk_tree.bzl\", \"android_sdk_tree\")
package(default_visibility = [\"//visibility:public\"])
toolchain_type(name = \"toolchain_type\")
"""
    for platform, constraints in _PLATFORMS.items():
        ndk_files = ""
        if ctx.attr.ndk_repository:
            ndk_files = 'ndk_files = "@androidndk_{platform}//:ndk_files",'.format(platform = platform)
        content += """android_sdk_tree(
    name = \"sdk_{platform}\",
    platform_files = \"@{sdk_repository}//:platform_files\",
    component_files = \"@{sdk_repository}_{platform}//:sdk_component_files\",
    {ndk_files}
    platform = \"{platform}\",
    build_tools_version = \"{build_tools_version}\",
    ndk_version = \"{ndk_version}\",
)
android_toolchain(
    name = \"android_{platform}\",
    sdk = \":sdk_{platform}\",
    gradle = \"@{gradle_repository}//:gradle\",
    sdk_version = \"{sdk_version}\",
    build_tools_version = \"{build_tools_version}\",
    ndk_version = \"{ndk_version}\",
    gradle_version = \"{gradle_version}\",
)
toolchain(
    name = \"{platform}_toolchain\",
    exec_compatible_with = {constraints},
    toolchain = \":android_{platform}\",
    toolchain_type = \"@rules_flutter//flutter:android_toolchain_type\",
)
""".format(
            build_tools_version = ctx.attr.build_tools_version,
            constraints = repr(constraints),
            gradle_repository = ctx.attr.gradle_repository,
            gradle_version = ctx.attr.gradle_version,
            ndk_files = ndk_files,
            ndk_version = ctx.attr.ndk_version,
            platform = platform,
            sdk_repository = ctx.attr.sdk_repository,
            sdk_version = ctx.attr.sdk_version,
        )
    ctx.file("BUILD.bazel", content)

android_toolchains_repository = repository_rule(
    implementation = _android_toolchains_repository_impl,
    attrs = {
        "sdk_repository": attr.string(mandatory = True),
        "gradle_repository": attr.string(mandatory = True),
        "ndk_repository": attr.string(),
        "sdk_version": attr.string(mandatory = True),
        "build_tools_version": attr.string(mandatory = True),
        "ndk_version": attr.string(),
        "gradle_version": attr.string(mandatory = True),
    },
)
