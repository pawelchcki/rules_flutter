"""Analysis tests for flutter_app build customization attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_BUILD_MNEMONICS = ["FlutterBuild", "FlutterBuildAndroid", "FlutterBuildIos"]

def _build_command_test_impl(ctx):
    env = analysistest.begin(ctx)

    action = _flutter_build_action(env)
    script = " ".join(action.argv) if action != None else None
    asserts.true(env, action != None, "expected a FlutterBuild action")

    if script != None:
        for expected in ctx.attr.expected_substrings:
            asserts.true(
                env,
                expected in script,
                "expected FlutterBuild command to contain '{}'".format(expected),
            )
        for absent in ctx.attr.absent_substrings:
            asserts.false(
                env,
                absent in script,
                "expected FlutterBuild command to NOT contain '{}'".format(absent),
            )

        cursor = -1
        for expected in ctx.attr.ordered_substrings:
            position = script.find(expected)
            asserts.true(
                env,
                position > cursor,
                "expected '{}' after the previous ordered substring".format(expected),
            )
            cursor = position

        input_paths = [f.path for f in action.inputs.to_list()]
        for expected in ctx.attr.expected_inputs:
            asserts.true(
                env,
                [p for p in input_paths if p.endswith(expected)] != [],
                "expected '{}' among FlutterBuild inputs".format(expected),
            )
        for absent in ctx.attr.absent_inputs:
            asserts.equals(
                env,
                [],
                [p for p in input_paths if p.endswith(absent)],
                "expected '{}' to be absent from FlutterBuild inputs".format(absent),
            )

    return analysistest.end(env)

build_command_test = analysistest.make(
    _build_command_test_impl,
    attrs = {
        "expected_substrings": attr.string_list(
            doc = "Substrings that must appear in the FlutterBuild action script.",
        ),
        "absent_substrings": attr.string_list(
            doc = "Substrings that must not appear in the FlutterBuild action script.",
        ),
        "ordered_substrings": attr.string_list(
            doc = "Substrings that must occur in order in the FlutterBuild action script.",
        ),
        "expected_inputs": attr.string_list(
            doc = "Path suffixes that must match FlutterBuild action inputs.",
        ),
        "absent_inputs": attr.string_list(
            doc = "Path suffixes that must not match FlutterBuild action inputs.",
        ),
    },
)

def _flutter_build_action(env):
    """Return the flutter build action for the target under test."""
    for action in analysistest.target_actions(env):
        if action.mnemonic in _BUILD_MNEMONICS:
            return action
    return None

def _android_offline_test_impl(ctx):
    env = analysistest.begin(ctx)

    action = _flutter_build_action(env)
    asserts.true(env, action != None, "expected a FlutterBuild action")

    if action != None:
        script = " ".join(action.argv)
        for expected in ctx.attr.expected_substrings:
            asserts.true(
                env,
                expected in script,
                "expected FlutterBuild command to contain '{}'".format(expected),
            )
        for absent in ctx.attr.absent_substrings:
            asserts.false(
                env,
                absent in script,
                "expected FlutterBuild command to NOT contain '{}'".format(absent),
            )

        # The assertion that actually carries the hermeticity claim. Mentioning
        # the mirror in the script proves only that a path got interpolated;
        # what makes the action's key describe its result -- and what justifies
        # dropping requires-network -- is those files being *inputs*.
        input_paths = [f.path for f in action.inputs.to_list()]
        for expected in ctx.attr.expected_inputs:
            asserts.true(
                env,
                [p for p in input_paths if p.endswith(expected)] != [],
                "expected '{}' among the FlutterBuild action's {} inputs".format(
                    expected,
                    len(input_paths),
                ),
            )

    return analysistest.end(env)

_ANDROID_OFFLINE_TEST_ATTRS = {
    "expected_substrings": attr.string_list(
        doc = "Substrings that must appear in the FlutterBuild action script.",
    ),
    "expected_inputs": attr.string_list(
        doc = "Path suffixes that must each match at least one action input.",
    ),
    "absent_substrings": attr.string_list(
        doc = "Substrings that must not appear in the FlutterBuild action script.",
    ),
}

# Same body, two rules: analysistest bakes the build settings into the rule via
# config_settings, so "offline on" and "offline off" cannot be one rule with a
# parameter.
android_offline_test = analysistest.make(
    _android_offline_test_impl,
    attrs = _ANDROID_OFFLINE_TEST_ATTRS,
)

android_online_test = analysistest.make(
    _android_offline_test_impl,
    attrs = _ANDROID_OFFLINE_TEST_ATTRS,
)

def _embed_guard_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "assemble_dep_caches = False")
    return analysistest.end(env)

# Embedding a library without an assembled dependency cache (as generated
# package repositories are) must fail at analysis time, not silently produce
# a runtime package config that drops every hosted dependency.
embed_guard_test = analysistest.make(
    _embed_guard_test_impl,
    expect_failure = True,
)

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_failure)
    return analysistest.end(env)

failure_test = analysistest.make(
    _failure_test_impl,
    attrs = {
        "expected_failure": attr.string(mandatory = True),
    },
    expect_failure = True,
)

def _android_toolchain_roots_test_impl(ctx):
    env = analysistest.begin(ctx)

    info = analysistest.target_under_test(env)[platform_common.ToolchainInfo].android
    asserts.equals(env, ctx.attr.expected_sdk_path, info.sdk_path)
    asserts.equals(env, ctx.attr.expected_gradle_home, info.gradle_home)

    return analysistest.end(env)

# The roots are derived from each dependency's own Label, not guessed from a
# file path. The hazard this pins down is not the derivation itself but the
# main-repo branch: it used to be an unconditional silent fall-through to the
# first file's parent directory, which produced a plausible-looking-but-wrong
# root for any multi-directory dependency instead of failing.
android_toolchain_roots_test = analysistest.make(
    _android_toolchain_roots_test_impl,
    attrs = {
        "expected_gradle_home": attr.string(
            doc = "Expected exec-root-relative Gradle distribution root.",
        ),
        "expected_sdk_path": attr.string(
            doc = "Expected exec-root-relative Android SDK root.",
        ),
    },
)
