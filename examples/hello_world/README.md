# hello_world

A minimal Flutter application built with
[rules_flutter](https://github.com/SpencerC/rules_flutter). Copy this
directory to start a new Bazel-built Flutter project — it consumes
`rules_flutter` as an ordinary `bazel_dep`, with no overrides.

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
4. Add `"@hello_world_deps//:all"` to the `deps` of `:lib` (or
   `"@hello_world_deps//:<package>"` for a single package).

## Layout

| File                    | Purpose                                            |
| ----------------------- | -------------------------------------------------- |
| `MODULE.bazel`          | Toolchain registration + pub repositories          |
| `BUILD.bazel`           | `flutter_library` + `flutter_test` + `flutter_app` |
| `pubspec.lock`          | Checked-in dependency resolution (generated)       |
| `lib/`, `test/`, `web/` | A standard Flutter counter app                     |

Note: in this repository's CI the example builds against the working tree
via `--override_module=rules_flutter=<repo root>`; as a standalone checkout
it resolves the released version from the Bazel Central Registry.
