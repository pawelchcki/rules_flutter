"""This module implements the language-specific toolchain rule.
"""

FlutterInfo = provider(
    doc = "Information about how to invoke the tool executable.",
    fields = {
        "flutter_bin": "The `flutter` launcher File. Use `.path` in actions and a runfiles-relative path at runtime.",
        "tool_files": "Files required in runfiles to make the tool executable available.",
        "sdk_files": "Depset of all Flutter SDK files needed for the tool to work properly.",
        "sdk_groups": "Capability name to SDK-file depset. Absent groups fall back to sdk_files for custom toolchains.",
    },
)

def _flutter_toolchain_impl(ctx):
    if not ctx.attr.target_tool:
        fail("flutter_toolchain requires target_tool (the hermetic `flutter` launcher).")

    tool_files = ctx.attr.target_tool.files.to_list()
    if not tool_files:
        fail("flutter_toolchain: target_tool produced no files.")
    flutter_bin = tool_files[0]

    # Make the $(FLUTTER_BIN) variable available in places like genrules,
    # which are expanded against runfiles manifest paths.
    manifest_path = (
        "external/" + flutter_bin.short_path[3:] if flutter_bin.short_path.startswith("../") else ctx.workspace_name + "/" + flutter_bin.short_path
    )
    template_variables = platform_common.TemplateVariableInfo({
        "FLUTTER_BIN": manifest_path,
    })
    default = DefaultInfo(
        files = depset(tool_files),
        runfiles = ctx.runfiles(files = tool_files),
    )

    # Keep the (large) SDK file set as a depset end-to-end: consumers merge it
    # into action inputs/runfiles without ever flattening it per target.
    sdk_files = ctx.attr.sdk_files.files if ctx.attr.sdk_files else depset()

    # Keep custom toolchains source-compatible: before capability-scoped SDK
    # inputs existed they supplied only sdk_files, so each capability must use
    # that complete closure unless it was explicitly populated.
    sdk_groups = {}
    for capability in ["dart", "framework", "base", "test", "web", "android", "ios", "macos", "linux", "windows"]:
        group = getattr(ctx.attr, "sdk_{}_files".format(capability))
        sdk_groups[capability] = group.files if group else sdk_files

    flutterinfo = FlutterInfo(
        flutter_bin = flutter_bin,
        tool_files = tool_files,
        sdk_files = sdk_files,
        sdk_groups = sdk_groups,
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        flutterinfo = flutterinfo,
        template_variables = template_variables,
        default = default,
    )
    return [
        default,
        toolchain_info,
        template_variables,
    ]

flutter_toolchain = rule(
    implementation = _flutter_toolchain_impl,
    attrs = {
        "target_tool": attr.label(
            doc = "A hermetically downloaded executable target for the target platform.",
            mandatory = True,
            allow_single_file = True,
        ),
        "sdk_files": attr.label(
            doc = "Flutter SDK files needed for the tool to work properly.",
            mandatory = False,
            allow_files = True,
        ),
        # Generated toolchains populate these with the smallest SDK closure
        # appropriate to the consuming action. All are optional deliberately:
        # third-party/custom toolchains that only expose sdk_files retain the
        # historical full-SDK behavior.
        "sdk_dart_files": attr.label(allow_files = True),
        "sdk_framework_files": attr.label(allow_files = True),
        "sdk_base_files": attr.label(allow_files = True),
        "sdk_test_files": attr.label(allow_files = True),
        "sdk_web_files": attr.label(allow_files = True),
        "sdk_android_files": attr.label(allow_files = True),
        "sdk_ios_files": attr.label(allow_files = True),
        "sdk_macos_files": attr.label(allow_files = True),
        "sdk_linux_files": attr.label(allow_files = True),
        "sdk_windows_files": attr.label(allow_files = True),
    },
    doc = """Defines a flutter compiler/runtime toolchain.

For usage see https://docs.bazel.build/versions/main/toolchains.html#defining-toolchains.
""",
)
