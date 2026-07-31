"""Unit tests for the `sdks:` check that compares a lock against the toolchain."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:pub_lock_sdks.bzl",
    "constraint_lower_bound",
    "parse_lock_sdk_constraints",
    "version_below_lower_bound",
)

_LOCK = """packages:
  meta:
    dependency: transitive
    description:
      name: meta
      sha256: "abc"
      url: "https://pub.dev"
    source: hosted
    version: "1.18.0"
sdks:
  dart: ">=3.10.0-0 <4.0.0"
  flutter: ">=3.18.0-18.0.pre.54"
"""

def _parses_the_sdks_block_test_impl(ctx):
    env = unittest.begin(ctx)
    sdks = parse_lock_sdk_constraints(_LOCK)
    asserts.equals(env, ">=3.10.0-0 <4.0.0", sdks.get("dart"))
    asserts.equals(env, ">=3.18.0-18.0.pre.54", sdks.get("flutter"))
    return unittest.end(env)

def _lock_without_sdks_block_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, {}, parse_lock_sdk_constraints("packages:\n  meta:\n    version: \"1.0.0\"\n"))
    return unittest.end(env)

def _reads_the_lower_bound_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [3, 18, 0], constraint_lower_bound(">=3.18.0-18.0.pre.54"))
    asserts.equals(env, [3, 10, 0], constraint_lower_bound(">=3.10.0-0 <4.0.0"))

    # No `>=` term, or one that cannot be read: no opinion rather than a guess.
    asserts.equals(env, None, constraint_lower_bound("<4.0.0"))
    asserts.equals(env, None, constraint_lower_bound("any"))
    asserts.equals(env, None, constraint_lower_bound(">=main"))
    return unittest.end(env)

def _flags_only_a_toolchain_below_the_floor_test_impl(ctx):
    env = unittest.begin(ctx)

    # The failure this catches: lock resolved by a newer Flutter.
    asserts.true(env, version_below_lower_bound("3.41.2", ">=3.44.0"))
    asserts.true(env, version_below_lower_bound("3.44.0", ">=3.44.1"))

    # Satisfied, including the prerelease floor a real lock records: a release
    # version is >= any prerelease of the same triple.
    asserts.false(env, version_below_lower_bound("3.44.1", ">=3.18.0-18.0.pre.54"))
    asserts.false(env, version_below_lower_bound("3.18.0", ">=3.18.0-18.0.pre.54"))
    asserts.false(env, version_below_lower_bound("3.44.1", ">=3.44.1"))

    # Nothing readable to compare against: never fail the build on a guess.
    asserts.false(env, version_below_lower_bound("3.44.1", "any"))
    asserts.false(env, version_below_lower_bound("3.44.1", "<4.0.0"))
    asserts.false(env, version_below_lower_bound("stable", ">=3.44.0"))
    return unittest.end(env)

_parses_the_sdks_block_test = unittest.make(_parses_the_sdks_block_test_impl)
_lock_without_sdks_block_test = unittest.make(_lock_without_sdks_block_test_impl)
_reads_the_lower_bound_test = unittest.make(_reads_the_lower_bound_test_impl)
_flags_only_a_toolchain_below_the_floor_test = unittest.make(_flags_only_a_toolchain_below_the_floor_test_impl)

def pub_lock_sdks_test_suite(name):
    unittest.suite(
        name,
        _parses_the_sdks_block_test,
        _lock_without_sdks_block_test,
        _reads_the_lower_bound_test,
        _flags_only_a_toolchain_below_the_floor_test,
    )
