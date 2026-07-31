"""AndroidManifest.xml permission merging.

Two callers, one mechanism. `flutter create` declares
`android.permission.INTERNET` only in the debug (and profile) variant
manifests under `android/app/src/debug/`; Gradle's manifest merger folds
them into debug APKs, and `flutter_android_app` reproduces that fold here.
The same rule also backs `flutter_android_app(permissions = [...])`, which
folds the app's *own* permissions in for every compilation mode — the seam a
networked app needs, since the debug variant's INTERNET belongs to the Dart
VM service and never reaches release.

Either way this runs the strict rules_flutter merger tool
(`merge_android_manifests.dart`) over a base manifest and an overlay.

The merger accepts only `<uses-permission>` / `<uses-permission-sdk-23>`
elements in the overlay and hard-fails on anything else, so it can never
silently mis-merge a variant manifest it does not fully understand.
"""

_TOOL = Label("//flutter/private/tools:merge_android_manifests.dart")

def _flutter_android_manifest_merge_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    tool = ctx.file._merge_tool
    output = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = [
            tool.path,
            "--base",
            ctx.file.base.path,
            "--overlay",
            ctx.file.overlay.path,
            "--output",
            output.path,
        ],
        inputs = depset(
            direct = [tool, ctx.file.base, ctx.file.overlay],
            transitive = [flutter_sdk_info.tool_files],
        ),
        outputs = [output],
        mnemonic = "FlutterManifestMerge",
        progress_message = "Merging Android variant manifest %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([output]))]

flutter_android_manifest_merge = rule(
    implementation = _flutter_android_manifest_merge_impl,
    attrs = {
        "base": attr.label(
            doc = "The main AndroidManifest.xml (already preprocessed for " +
                  "Gradle variables) the overlay merges into.",
            allow_single_file = True,
            mandatory = True,
        ),
        "overlay": attr.label(
            doc = "A manifest whose <uses-permission> elements merge into " +
                  "the base — either a variant manifest (e.g. " +
                  "android/app/src/debug/AndroidManifest.xml) or one " +
                  "written by flutter_android_permissions_manifest.",
            allow_single_file = True,
            mandatory = True,
        ),
        "_merge_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ],
    doc = "Merges a variant AndroidManifest.xml overlay's permissions into a base manifest.",
)
