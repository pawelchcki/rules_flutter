"""Unit tests for flutter_test source analysis partitioning."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_test.bzl", "partition_analyzable_sources")

def _nested_package_partition_test_impl(ctx):
    env = unittest.begin(ctx)
    lib, support = partition_analyzable_sources([
        struct(short_path = "app/lib/main.dart"),
        struct(short_path = "app/lib/support.dart"),
        struct(short_path = "app/test/widget_test.dart"),
        struct(short_path = "app/test/helpers/fake.dart"),
    ], "app")
    asserts.equals(env, ["app/lib/main.dart", "app/lib/support.dart"], [f.short_path for f in lib])
    asserts.equals(env, ["app/test/widget_test.dart", "app/test/helpers/fake.dart"], [f.short_path for f in support])
    return unittest.end(env)

def _root_package_partition_test_impl(ctx):
    env = unittest.begin(ctx)
    lib, support = partition_analyzable_sources([
        struct(short_path = "lib/main.dart"),
        struct(short_path = "test/widget_test.dart"),
    ], "")
    asserts.equals(env, ["lib/main.dart"], [f.short_path for f in lib])
    asserts.equals(env, ["test/widget_test.dart"], [f.short_path for f in support])
    return unittest.end(env)

_nested_package_partition_test = unittest.make(_nested_package_partition_test_impl)
_root_package_partition_test = unittest.make(_root_package_partition_test_impl)

def flutter_test_test_suite(name):
    unittest.suite(name, _nested_package_partition_test, _root_package_partition_test)
