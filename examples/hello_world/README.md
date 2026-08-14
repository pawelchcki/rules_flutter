# hello_world

A minimal Flutter application built with
[ruleslab_flutter](https://github.com/pawelchcki/ruleslab_flutter). Copy this
directory to start a new Bazel-built Flutter project — it consumes the
`rules_flutter` Bazel module as an ordinary `bazel_dep`. The temporary
`hermetic_android_toolchains` archive override is needed only until that
transitive module has its first Bazel Central Registry release.

```bash
bazel test //:widget_test    # run the widget test hermetically
bazel build //:app.web       # build the web bundle
bazel run //:app.dev         # dev server with hot reload
```

No host Flutter install is required: the `flutter` module extension in
[`MODULE.bazel`](MODULE.bazel) downloads a sealed SDK and registers
toolchains.

## Adding a pub dependency

1. Add the package to [`pubspec.yaml`](pubspec.yaml).
2. `bazel run //:lib.update` — re-resolves and rewrites `pubspec.lock`.
3. The lock is already declared in `MODULE.bazel` as
   `pub.lock(name = "hello_world_deps", file = "//:pubspec.lock")`, so the new
   package joins that hub automatically.
4. `:lib` already depends on `"@hello_world_deps//:all"`; optionally narrow
   that to `"@hello_world_deps//:<package>"` for individual packages.

## Layout

| File                    | Purpose                                            |
| ----------------------- | -------------------------------------------------- |
| `MODULE.bazel`          | Toolchain registration + pub repositories          |
| `BUILD.bazel`           | `flutter_library` + `flutter_test` + `flutter_app` |
| `pubspec.lock`          | Checked-in dependency resolution (generated)       |
| `lib/`, `test/`, `web/` | A standard Flutter counter app                     |

Note: in this repository's CI the example builds against the working tree
via `--override_module=rules_flutter=<repo root>`; as a standalone checkout
it resolves the released version from the Bazel Central Registry once 0.2.0
is published.
