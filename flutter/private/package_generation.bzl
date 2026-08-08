"""Helpers for generating BUILD files for Dart/Flutter packages."""

load("//flutter/private:pubspec_lock.bzl", "lock_direct_packages", "parse_pubspec_lock")

_DEF_LOAD_STMT = 'load("@rules_flutter//flutter:defs.bzl", "dart_library", "flutter_library")'

_DEF_VISIBILITY = '    visibility = ["//visibility:public"],'

def _sanitize_published_pubspec(repository_ctx, pubspec_rel):
    """Drop sections of a published pubspec that break standalone resolution.

    - `resolution: workspace` markers only make sense inside the source
      monorepo and make `pub deps` refuse to resolve the package.
    - `dev_dependencies`/`dependency_overrides` of a published library are
      irrelevant to consumers and sometimes reference unpublished packages
      (e.g. analyzer 9.0.0's heap_snapshot), failing the solve outright.
    """
    content = repository_ctx.read(pubspec_rel)
    dropped_sections = ("dev_dependencies:", "dependency_overrides:")

    needs_rewrite = False
    output_lines = []
    skipping = False
    for line in content.splitlines():
        stripped = line.strip()
        if skipping:
            # Section ends at the next non-comment line without indentation.
            if line and not line.startswith((" ", "\t")) and not stripped.startswith("#"):
                skipping = False
            else:
                continue
        if line.startswith("resolution:"):
            needs_rewrite = True
            continue
        if line.startswith(dropped_sections):
            needs_rewrite = True
            skipping = True
            continue
        output_lines.append(line)

    if needs_rewrite:
        repository_ctx.file(pubspec_rel, "\n".join(output_lines) + "\n")

def _ensure_lock(repository_ctx, package_name, package_dir, resolve_deps = True):
    """Ensure a `pubspec.lock` exists, running `pub get` when it does not.

    Only repositories that execute out of their own vendored closure
    (`pub.package` tags, `resolve_deps = True`) need a solve. Leaf packages
    declared by a hub's lock are already pinned by that lock and never resolve
    anything themselves, so they skip this entirely.
    """

    # Lock-hub leaves and Flutter SDK packages are immutable inputs. In
    # particular, do not sanitize their pubspecs: that would mutate the
    # downloaded SDK and can make two generated packages observe different
    # repository contents depending on fetch order.
    if not resolve_deps:
        return False

    if package_dir in (".", ""):
        pubspec_rel = "pubspec.yaml"
        lock_rel = "pubspec.lock"
        pub_cache_rel = ".pub_cache"
    else:
        pubspec_rel = package_dir + "/pubspec.yaml"
        lock_rel = package_dir + "/pubspec.lock"
        pub_cache_rel = package_dir + "/.pub_cache"

    pubspec_path = repository_ctx.path(pubspec_rel)
    if not pubspec_path.exists:
        return False

    _sanitize_published_pubspec(repository_ctx, pubspec_rel)

    # Flutter SDK packages ship their own lock, so the solve is skipped for
    # them rather than re-derived.
    lock_path = repository_ctx.path(lock_rel)
    if lock_path.exists and repository_ctx.read(lock_rel).strip():
        return False

    command, tool = _find_pub_command(repository_ctx)
    if not command:
        fail(
            ("No Dart or Flutter executable is available to resolve package '{pkg}'.\n" +
             "A pub.package repository must resolve at fetch time because tools " +
             "execute from its vendored .pub_cache.").format(pkg = package_name),
        )

    workdir = str(repository_ctx.path(package_dir if package_dir not in (".", "") else "."))
    run_env = {
        "PUB_CACHE": str(repository_ctx.path(pub_cache_rel)),
        "PUB_ENVIRONMENT": "rules_flutter:repository",

        # The toolchain SDK's bin/cache is sealed read-only; both launchers
        # would otherwise try to take the startup lockfile there.
        "FLUTTER_ALREADY_LOCKED": "true",
        "FLUTTER_SUPPRESS_ANALYTICS": "true",
    }

    # Let `dart pub` resolve `sdk: flutter` dependencies against the toolchain
    # SDK. Derived from the sdk_dart launcher (a symlink into the platform SDK
    # repository), so it also holds for packages that resolve with plain dart.
    sdk_dart = getattr(repository_ctx.attr, "sdk_dart", None)
    if sdk_dart != None:
        dart_path = repository_ctx.path(sdk_dart)
        if dart_path.exists:
            run_env["FLUTTER_ROOT"] = str(dart_path.realpath.dirname.dirname)

    if tool == "flutter":
        run_env["FLUTTER_UPDATE_DISABLED"] = "true"
        run_env["CI"] = "true"

    repository_ctx.report_progress(
        "Resolving pub dependencies for {}".format(package_name),
    )

    result = repository_ctx.execute(
        command + ["get"],
        working_directory = workdir,
        environment = run_env,
        quiet = True,
    )
    if result.return_code != 0:
        fail("Failed to run `{tool} pub get` for package '{pkg}' (dir: {dir}).\nstdout: {stdout}\nstderr: {stderr}".format(
            tool = tool,
            pkg = package_name,
            dir = package_dir,
            stdout = result.stdout,
            stderr = result.stderr,
        ))

    # A successful solve always writes the lock. Asserting it rather than
    # falling back keeps "resolved" from silently meaning "guessed".
    if not repository_ctx.path(lock_rel).exists:
        fail("`{tool} pub get` for package '{pkg}' did not write {lock}.".format(
            tool = tool,
            pkg = package_name,
            lock = lock_rel,
        ))
    return True

def _find_pub_command(repository_ctx):
    """Locate a flutter or dart executable and return the pub command prefix."""

    os_name = repository_ctx.os.name.lower()
    flutter_candidates = [
        "flutter/bin/flutter",
        "bin/flutter",
        "flutter/bin/flutter.bat",
        "bin/flutter.bat",
    ]
    dart_candidates = [
        "flutter/bin/cache/dart-sdk/bin/dart",
        "bin/dart",
        "flutter/bin/cache/dart-sdk/bin/dart.exe",
        "bin/dart.exe",
    ]

    for candidate in flutter_candidates:
        path = repository_ctx.path(candidate)
        if path.exists:
            return _pub_command_prefix(str(path), "flutter"), "flutter"

    for candidate in dart_candidates:
        path = repository_ctx.path(candidate)
        if path.exists:
            return _pub_command_prefix(str(path), "dart"), "dart"

    # Toolchain SDK launchers passed by pub_dev_repository. These keep the
    # fetch-time resolution hermetic: without them, machines lacking a host
    # Flutter (e.g. CI workers) silently fell back to pubspec parsing and the
    # repository was left without its vendored .pub_cache.
    #
    # dart comes first deliberately: `dart pub` resolves `sdk: flutter`
    # dependencies through FLUTTER_ROOT (exported by _ensure_lock) without
    # the flutter tool's artifact-cache refresh — which on non-macOS hosts
    # unconditionally rewrites the ios-usb artifact stamps and therefore can
    # never run against the sealed SDK cache.
    sdk_dart = getattr(repository_ctx.attr, "sdk_dart", None)
    if sdk_dart != None:
        path = repository_ctx.path(sdk_dart)
        if path.exists:
            return _pub_command_prefix(str(path), "dart"), "dart"
    sdk_flutter = getattr(repository_ctx.attr, "sdk_flutter", None)
    if sdk_flutter != None:
        path = repository_ctx.path(sdk_flutter)
        if path.exists:
            return _pub_command_prefix(str(path), "flutter"), "flutter"

    host_dart = repository_ctx.which("dart.exe" if os_name.startswith("windows") else "dart")
    if host_dart:
        return _pub_command_prefix(str(host_dart), "dart"), "dart"

    host_flutter = repository_ctx.which("flutter.bat" if os_name.startswith("windows") else "flutter")
    if host_flutter:
        return _pub_command_prefix(str(host_flutter), "flutter"), "flutter"

    return None, None

def _pub_command_prefix(executable, tool):
    if executable.endswith(".bat") or executable.endswith(".cmd"):
        prefix = ["cmd.exe", "/c", "\"{}\"".format(executable)]
    else:
        prefix = [executable]
    if tool == "flutter":
        prefix.append("--no-version-check")
    return prefix + ["pub"]

def generate_package_build(repository_ctx, package_name, package_dir = ".", sdk_repo = "@flutter_sdk", include_hosted_deps = True, include_pub_cache_data = False, resolve_deps = True):
    """Generate a BUILD.bazel for the given package directory.

    Args:
        repository_ctx: Repository rule context.
        package_name: The Bazel target / Dart package name.
        package_dir: Relative directory containing the package ("." for root).
        sdk_repo: Optional repository label used to resolve SDK-provided
            dependencies (e.g. `@flutter_sdk`). When omitted, a sensible
            default for the current host platform is used.
        include_hosted_deps: When true, the package is a hosted pub.dev leaf
            that stages its own payload. Flutter SDK packages pass False
            because their dependencies are already vendored in the SDK.
        include_pub_cache_data: When true and the package contains a local
            `.pub_cache`, expose it as data so package preparation can publish
            those vendored artifacts transitively.
        resolve_deps: Whether to run a real `pub get` at fetch time. Leaf
            repositories declared by a hub's pubspec.lock pass False — the
            lock already pinned them and nothing executes from their closure;
            tool repositories registered via pub.package tags keep True.
    """

    has_lock = _ensure_lock(
        repository_ctx,
        package_name,
        package_dir,
        resolve_deps = resolve_deps,
    ) or _package_lock_exists(repository_ctx, package_dir)
    rule_kind = _determine_rule_kind(repository_ctx, package_dir)
    srcs = _collect_lib_sources(repository_ctx, package_dir)
    metadata_files = _collect_metadata_files(repository_ctx, package_dir)
    deps = (
        _collect_sdk_deps(repository_ctx, package_dir, sdk_repo) if has_lock else _collect_pubspec_sdk_deps(repository_ctx, package_dir, sdk_repo)
    )
    pub_cache_files_target = None
    if include_pub_cache_data and _package_pub_cache_exists(repository_ctx, package_dir):
        pub_cache_files_target = "_pub_cache_files"

    lines = [
        "# Generated BUILD file for package: {}".format(package_name),
        _DEF_LOAD_STMT,
        "",
    ]

    if has_lock:
        # The lock is consumed directly by rules_flutter (e.g. the shared
        # protoc-gen-dart package_config), so it needs a target of its own.
        lines.extend(['exports_files(["pubspec.lock"])', ""])

    lines.extend([
        "{}(".format(rule_kind),
        '    name = "{}",'.format(package_name),
    ])

    if srcs:
        lines.append("    srcs = [")
        for src in srcs:
            lines.append('        "{}",'.format(src))
        lines.append("    ],")

    # A lockless SDK package is already part of FLUTTER_ROOT. Giving it a
    # pubspec without a lock asks the rule macro to synthesize pubspec.lock and
    # run dependency preparation, neither of which is valid for packages such
    # as sky_engine and flutter_gpu.
    if has_lock or include_hosted_deps:
        lines.append('    pubspec = "pubspec.yaml",')
    if has_lock:
        lines.append('    lock = "pubspec.lock",')

    if deps:
        lines.append("    deps = [")
        for dep in deps:
            lines.append('        "{}",'.format(dep))
        lines.append("    ],")

    data_entries = ['"{}"'.format(name) for name in metadata_files]
    if pub_cache_files_target:
        data_entries.append('":{}"'.format(pub_cache_files_target))

    # Hosted pub packages publish themselves into the assembled cache; SDK
    # packages (include_hosted_deps=False) are resolved from FLUTTER_ROOT.
    # The published copy must carry the full package payload — packages ship
    # fonts, assets, and other non-Dart files the bundler reads (e.g.
    # golden_toolkit's Roboto font).
    payload_target = None
    if include_hosted_deps:
        payload_target = "_package_payload"
        data_entries.append('":{}"'.format(payload_target))
        lines.append("    pub_package = True,")

        # Lets the library rule stage the package directly from its own
        # payload (one action, one tree) instead of the full prepare path.
        lines.append('    pub_payload = ":{}",'.format(payload_target))

    # Generated package targets contribute only their own payload to the
    # cache; the top-level consumer assembles the full cache once from the
    # transitive depset. Merging dep caches at every level duplicates shared
    # transitive packages O(graph depth) times.
    lines.append("    assemble_dep_caches = False,")

    if data_entries:
        lines.append("    data = [{}],".format(", ".join(data_entries)))

    lines.append(_DEF_VISIBILITY)
    lines.append(")")

    if pub_cache_files_target:
        # The vendored closure is consumed only as opaque action inputs
        # (tools resolve files by path under external/<repo>/.pub_cache), so
        # expose it as ONE source-directory artifact instead of a per-file
        # glob: a pub.package closure runs to tens of thousands of files, and
        # a file-level glob turns each into a configured target — measured at
        # ~40k targets (~150s of cold analysis) for protoc_plugin alone. Repo
        # contents only change on refetch, so directory-level invalidation is
        # exact here.
        lines.extend([
            "",
            "filegroup(",
            '    name = "{}",'.format(pub_cache_files_target),
            "    srcs = glob(",
            '        [".pub_cache"],',
            "        exclude_directories = 0,",
            "        allow_empty = True,",
            "    ),",
            ")",
        ])

    if payload_target:
        lines.extend([
            "",
            "filegroup(",
            '    name = "{}",'.format(payload_target),
            "    srcs = glob(",
            '        ["**"],',
            "        exclude = [",
            '            ".pub_cache/**",',
            '            "BUILD",',
            '            "BUILD.bazel",',
            '            "PUB_PACKAGE_INFO",',
            '            "REPO.bazel",',
            '            "pubspec.lock",',
            "        ],",
            "        allow_empty = True,",
            "    ),",
            ")",
        ])

    lines.extend([
        "",
        "alias(",
        '    name = "lib",',
        '    actual = ":{}",'.format(package_name),
        _DEF_VISIBILITY,
        ")",
        "",
        # Whole-repo payload for consumers that execute out of this repo by
        # path (e.g. the dart_proto_library aspect running protoc_plugin).
        # Top-level directories are exposed as source-directory artifacts
        # rather than a recursive file glob — see _pub_cache_files above.
        # Exceptions that stay per-file globs:
        #   - "lib" (and a hypothetical self-named directory): a directory
        #     glob entry whose name matches a target in this package resolves
        #     to the TARGET, not the directory — pulling the whole
        #     dart_library dep graph into the filegroup (and, in SDK repos, a
        #     dependency cycle through the toolchain).
        #   - "bin": holds executable entrypoints (e.g. protoc_plugin.dart)
        #     that should stay content-digest-tracked, and the package rule's
        #     own srcs may carry bin/*.dart as FILE artifacts — an action
        #     receiving the same path as both a file and a directory input
        #     fails sandbox staging. For the same reason, do not combine this
        #     filegroup with ":{package}" or ":_package_payload" in a single
        #     action's inputs.
        "filegroup(",
        '    name = "{}_files",'.format(package_name),
        "    srcs = glob(",
        '        ["*"],',
        "        exclude = [",
        '            "BUILD",',
        '            "BUILD.bazel",',
        '            "bin",',
        '            "lib",',
        '            "{}",'.format(package_name),
        "        ],",
        "        exclude_directories = 0,",
        "    ) + glob(",
        "        [",
        '            "bin/**",',
        '            "lib/**",',
        '            "{}/**",'.format(package_name),
        "        ],",
        "        allow_empty = True,",
        "    ),",
        _DEF_VISIBILITY,
        ")",
    ])

    build_path = "BUILD.bazel" if package_dir in (".", "") else package_dir + "/BUILD.bazel"
    repository_ctx.file(build_path, "\n".join(lines) + "\n")

def _package_pub_cache_exists(repository_ctx, package_dir):
    pub_cache_rel = ".pub_cache" if package_dir in (".", "") else package_dir + "/.pub_cache"
    pub_cache_path = repository_ctx.path(pub_cache_rel)
    return pub_cache_path.exists and pub_cache_path.is_dir

def _determine_rule_kind(repository_ctx, package_dir):
    """Decide which rule kind (flutter or dart) to emit."""

    pubspec_rel = "pubspec.yaml" if package_dir in (".", "") else package_dir + "/pubspec.yaml"
    pubspec_path = repository_ctx.path(pubspec_rel)
    if not pubspec_path.exists:
        return "dart_library"

    content = repository_ctx.read(pubspec_rel)
    in_environment = False
    env_indent = 0
    has_flutter = False
    has_sdk = False

    for raw_line in content.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))

        if not in_environment:
            if stripped == "environment:":
                in_environment = True
                env_indent = indent
            continue

        if indent <= env_indent:
            in_environment = False
            if stripped == "environment:":
                in_environment = True
                env_indent = indent
            continue

        key = stripped.split(":", 1)[0]
        if key == "flutter":
            has_flutter = True
        if key == "sdk":
            has_sdk = True

    if has_flutter:
        return "flutter_library"
    if has_sdk:
        return "dart_library"
    return "flutter_library"

def _walk_files(root_path):
    """Return every file under root_path, as root-relative slash-separated paths.

    repository_ctx.path().readdir() keeps this in Starlark; the previous
    implementation shelled out to a host `python3`, an undeclared host tool.
    Starlark has no recursion and no `while`, so the traversal is an explicit
    worklist under a bounded loop.
    """
    pending = [(root_path, "")]
    found = []
    for _ in range(1000000):
        if not pending:
            break
        path, prefix = pending.pop()
        for child in path.readdir():
            rel = prefix + child.basename
            if child.is_dir:
                pending.append((child, rel + "/"))
            else:
                found.append(rel)
    return sorted(found)

def _collect_lib_sources(repository_ctx, package_dir):
    """Collect Dart sources needed for a generated pub package target."""

    source_roots = []
    for source_dir in ["lib", "bin"]:
        rel = source_dir if package_dir in (".", "") else package_dir + "/" + source_dir
        path = repository_ctx.path(rel)
        if path.exists and path.is_dir:
            source_roots.append((source_dir, path))

    if not source_roots:
        return []

    sources = []
    for source_dir, root_path in source_roots:
        for rel in _walk_files(root_path):
            if rel.endswith(".dart"):
                sources.append("{}/{}".format(source_dir, rel))

    return sorted(sources)

def _collect_metadata_files(repository_ctx, package_dir):
    """Top-level metadata files that must reach the assembled pub cache.

    build.yaml carries builder definitions that build_runner discovers from
    the cache copy of the package.
    """
    found = []
    for name in ["build.yaml"]:
        rel = name if package_dir in (".", "") else package_dir + "/" + name
        if repository_ctx.path(rel).exists:
            found.append(name)
    return found

def _package_lock_exists(repository_ctx, package_dir):
    """Whether the package directory carries a pubspec.lock."""
    rel = "pubspec.lock" if package_dir in (".", "") else package_dir + "/pubspec.lock"
    return repository_ctx.path(rel).exists

def _collect_sdk_deps(repository_ctx, package_dir, sdk_repo):
    """Return Bazel labels for the package's SDK-provided direct dependencies.

    Hosted dependencies deliberately produce no labels. A `pubspec.lock` is a
    complete transitive closure, so the hub generated for it already carries
    every hosted package; making leaves depend on each other would only
    re-import the pub universe's genuine cycles into a Bazel target graph that
    cannot express them.

    Sibling SDK packages are different: they publish `.pub_cache` data that
    must reach consumers through the target graph, so they stay explicit —
    but only their `direct main` deps. An SDK package's dev-dependencies are
    irrelevant to consumers and genuinely circular (flutter dev-depends on
    flutter_test, which depends on flutter).

    Args:
        repository_ctx: Repository rule context.
        package_dir: Relative location of the package being generated.
        sdk_repo: Repository label to use for Flutter SDK provided packages.
    """

    rel = "pubspec.lock" if package_dir in (".", "") else package_dir + "/pubspec.lock"
    packages = parse_pubspec_lock(repository_ctx.read(rel), origin = rel)

    deps = []
    for pkg in lock_direct_packages(packages).values():
        if pkg.source != "sdk" or pkg.dependency != "direct main":
            continue
        label = _sdk_dep_label(package_dir, pkg.name, sdk_repo)
        if label:
            deps.append(label)
    return sorted(deps)

def _collect_pubspec_sdk_deps(repository_ctx, package_dir, sdk_repo):
    """Read direct `sdk: flutter` deps when an SDK package has no lock.

    This intentionally recognizes only the top-level `dependencies` mapping;
    dev dependencies and hosted/path packages do not belong in the generated
    SDK target graph.
    """
    rel = "pubspec.yaml" if package_dir in (".", "") else package_dir + "/pubspec.yaml"
    if not repository_ctx.path(rel).exists:
        return []

    result = parse_pubspec_sdk_flutter_dependencies(repository_ctx.read(rel))

    labels = []
    for pkg in result:
        label = _sdk_dep_label(package_dir, pkg, sdk_repo)
        if label:
            labels.append(label)
    return sorted(labels)

def parse_pubspec_sdk_flutter_dependencies(content):
    """Return direct `sdk: flutter` dependency names from a pubspec string.

    Args:
        content: The pubspec.yaml text to inspect.

    Returns:
        A sorted list of direct Flutter SDK dependency names.
    """
    lines = content.splitlines()
    deps_indent = -1
    current_name = None
    current_indent = -1
    result = []

    for raw_line in lines:
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))

        if deps_indent < 0:
            if stripped == "dependencies:":
                deps_indent = indent
            continue
        if indent <= deps_indent:
            break

        if current_name != None and indent > current_indent:
            if stripped == "sdk: flutter":
                result.append(current_name)
            continue

        if ":" not in stripped:
            continue
        name, value = stripped.split(":", 1)
        current_name = name.strip()
        current_indent = indent
        value = value.strip().replace(" ", "")
        if value in ("{sdk:flutter}", "{sdk:'flutter'}", '{sdk:"flutter"}'):
            result.append(current_name)

    return sorted(result)

def _sdk_dep_label(package_dir, pkg, sdk_repo):
    path = _sdk_package_path(pkg)
    if not path:
        return None

    if package_dir.startswith("flutter/"):
        return "//{}:{}".format(path, pkg)

    return "{}//{}:{}".format(sdk_repo, path, pkg)

def _sdk_package_path(pkg):
    if pkg == "sky_engine":
        return "flutter/bin/cache/pkg/{}".format(pkg)
    if pkg == "_macros":
        # `_macros` is provided by the Dart SDK internals and does not live under flutter/packages.
        return None
    return "flutter/packages/{}".format(pkg)
