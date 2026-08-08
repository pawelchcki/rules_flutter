"""Extensions for bzlmod.

Installs a flutter toolchain.
Every module can define a toolchain version under the default name, "flutter".
The latest of those versions will be selected (the rest discarded),
and will always be registered by rules_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

load("@hermetic_android_toolchains//ndk:repositories.bzl", "ANDROID_NDK_LICENSE_ENV", "hermetic_android_ndk_platform_repository", "hermetic_android_ndk_repository")
load("@hermetic_android_toolchains//private:utils.bzl", "ANDROID_PLATFORMS")
load("@hermetic_android_toolchains//sdk:repositories.bzl", "ANDROID_SDK_LICENSE_ENV", "hermetic_android_sdk_platform_repository", "hermetic_android_sdk_repository")
load("//flutter/private:android_repositories.bzl", "android_toolchains_repository", "gradle_repository")
load("//flutter/private:pub_repository.bzl", "pub_dev_repository")
load("//flutter/private:version_select.bzl", "highest_version")
load("//flutter/private:versions.bzl", "TOOL_VERSIONS")
load(":repositories.bzl", "flutter_register_toolchains")

_DEFAULT_NAME = "flutter"

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one flutter toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "flutter_version": attr.string(doc = "Explicit version of flutter.", mandatory = True),
    "precache": attr.string_list(doc = """\
Artifact groups (web, android, ios, macos, linux, windows) that must be present
in the SDK cache after fetch. Stable archives already ship these; when one is
missing, `flutter precache` runs at repository fetch time. Unioned across
registrations of the same toolchain name.
""", default = []),
    "warm_first_run_stamps": attr.bool(doc = """\
Run one `flutter precache` at fetch time so the tool's first-run artifact
stamps exist before the SDK cache is sealed (~70s of fetch work). Required by
anything that runs `flutter test`, `analyze` or `build`; pure-Dart consumers
can set this False to skip it. False only takes effect when every registration
of this toolchain name asks for it.
""", default = True),
    "integrity": attr.string_dict(doc = """\
Escape hatch for Flutter versions not in the built-in version table: a map
from platform (macos, macos_arm64, linux, linux_arm64, windows) to the SRI
integrity of that platform's stable release archive, e.g.
{"macos": "sha256-...", "linux": "sha256-..."}. linux_arm64 has no archive of
its own — it re-architects the linux one and so takes the linux entry, while
macos_arm64 is a real separate download and needs its own.
Only the platforms you actually build on need an entry (the per-platform SDK
repositories are fetched lazily). When flutter_version is in the built-in
table this may be omitted. Merged across registrations of the same name.
""", default = {}),
})

android_toolchain = tag_class(attrs = {
    "name": attr.string(default = "android", doc = "Base name for generated Android repositories."),
    "sdk_version": attr.string(mandatory = True),
    "build_tools_version": attr.string(mandatory = True),
    "ndk_version": attr.string(),
    "gradle_distribution_url": attr.string(mandatory = True),
    "gradle_distribution_integrity": attr.string(mandatory = True),
})

def _gradle_version(url):
    filename = url.rsplit("/", 1)[-1]
    if not filename.startswith("gradle-") or not filename.endswith(".zip"):
        fail("gradle_distribution_url must end in gradle-<version>-bin.zip or gradle-<version>-all.zip")
    stem = filename[len("gradle-"):-len(".zip")]
    for suffix in ["-bin", "-all"]:
        if stem.endswith(suffix):
            return stem[:-len(suffix)]
    fail("gradle_distribution_url must name a -bin.zip or -all.zip Gradle distribution")

def _toolchain_extension(module_ctx):
    registrations = {}
    precache_groups = {}
    integrity_overrides = {}
    warm_stamps = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
                precache_groups[toolchain.name] = {}
                integrity_overrides[toolchain.name] = {}
                warm_stamps[toolchain.name] = False

            # Any registration that needs the stamps wins: skipping them breaks
            # every flutter test/analyze/build action, so the union is the only
            # safe merge.
            if toolchain.warm_first_run_stamps:
                warm_stamps[toolchain.name] = True
            registrations[toolchain.name].append(toolchain.flutter_version)
            for group in toolchain.precache:
                precache_groups[toolchain.name][group] = True

            # Integrity is bound to the (name, version) it was declared for, so
            # a map declared for one version is never applied to a different
            # version that happens to win selection.
            if toolchain.integrity:
                by_version = integrity_overrides[toolchain.name]
                if toolchain.flutter_version not in by_version:
                    by_version[toolchain.flutter_version] = {}
                for platform, sri in toolchain.integrity.items():
                    by_version[toolchain.flutter_version][platform] = sri
    for name, versions in registrations.items():
        # Deduplicate versions to avoid noise when the same version is registered multiple times
        unique_versions = {v: True for v in versions}.keys()
        if len(unique_versions) > 1:
            # Highest requested version wins (MVS: every module gets at least
            # the version it asked for), compared semver-aware not lexically.
            selected = highest_version(unique_versions)

            # buildifier: disable=print
            print("NOTE: flutter toolchain {} has multiple versions {}, selected {}".format(name, list(unique_versions), selected))
        else:
            selected = versions[0]

        # Only integrity declared for the selected version applies.
        overrides = integrity_overrides[name].get(selected, {})
        if selected not in TOOL_VERSIONS and not overrides:
            fail(("rules_flutter: Flutter {} is not in the built-in version table. " +
                  "Register it with an integrity map, e.g. " +
                  "flutter.toolchain(flutter_version = \"{}\", integrity = {{\"macos\": \"sha256-...\", \"linux\": \"sha256-...\"}}). " +
                  "Compute each SRI from the stable archive at " +
                  "https://storage.googleapis.com/flutter_infra_release/releases/stable/<platform>/flutter_<platform>_{}-stable.<ext>.").format(selected, selected, selected))

        flutter_register_toolchains(
            name = name,
            flutter_version = selected,
            precache = sorted(precache_groups[name].keys()),
            warm_first_run_stamps = warm_stamps[name],
            integrity = overrides,
            register = False,
        )

    android_tags = []
    for mod in module_ctx.modules:
        if mod.tags.android_toolchain:
            if not mod.is_root:
                fail("flutter.android_toolchain(...) may only be declared by the root module")
            android_tags.extend(mod.tags.android_toolchain)
    names = {}
    for android in android_tags:
        if android.name in names:
            fail("flutter.android_toolchain name '{}' was declared more than once".format(android.name))
        names[android.name] = True
        sdk_repo = "{}_android_sdk".format(android.name)
        gradle_repo = "{}_gradle".format(android.name)
        ndk_repo = ""

        # The SDK and NDK are each a hub repository over one repository per
        # host platform. The hub is what the toolchain depends on; it selects
        # among the platform repositories at analysis time, so a build only ever
        # fetches the archive for the host it is running on. Creating the
        # platform repositories is the caller's job, not the hub rule's --
        # `platform_repositories` is mandatory on both hubs.
        sdk_platform_repos = {}
        for platform in sorted(ANDROID_PLATFORMS.keys()):
            platform_repo = "{}_{}".format(sdk_repo, platform)
            hermetic_android_sdk_platform_repository(
                name = platform_repo,
                platform = platform,
                version = android.sdk_version,
                build_tools_version = android.build_tools_version,
            )
            sdk_platform_repos[platform] = platform_repo
        hermetic_android_sdk_repository(
            name = sdk_repo,
            platform_repositories = sdk_platform_repos,
            version = android.sdk_version,
            build_tools_version = android.build_tools_version,
        )
        if android.ndk_version:
            ndk_repo = "{}_android_ndk".format(android.name)
            ndk_platform_repos = {}
            for platform in sorted(ANDROID_PLATFORMS.keys()):
                # The upstream redirect BUILD addresses these repositories by
                # their historical fixed names.
                platform_repo = "androidndk_{}".format(platform)
                hermetic_android_ndk_platform_repository(
                    name = platform_repo,
                    platform = platform,
                    version = android.ndk_version,
                )
                ndk_platform_repos[platform] = platform_repo
            hermetic_android_ndk_repository(
                name = ndk_repo,
                platform_repositories = ndk_platform_repos,
                version = android.ndk_version,
            )
        gradle_repository(
            name = gradle_repo,
            url = android.gradle_distribution_url,
            integrity = android.gradle_distribution_integrity,
            version = _gradle_version(android.gradle_distribution_url),
        )
        android_toolchains_repository(
            name = "{}_toolchains".format(android.name),
            sdk_repository = sdk_repo,
            ndk_repository = ndk_repo,
            gradle_repository = gradle_repo,
            sdk_version = android.sdk_version,
            build_tools_version = android.build_tools_version,
            ndk_version = android.ndk_version,
            gradle_version = _gradle_version(android.gradle_distribution_url),
        )

flutter = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {
        "android_toolchain": android_toolchain,
        "toolchain": flutter_toolchain,
    },
    environ = [ANDROID_NDK_LICENSE_ENV, ANDROID_SDK_LICENSE_ENV],
)

# Pub.dev package management extension
pub_package = tag_class(attrs = {
    "name": attr.string(doc = "Repository name for the package", mandatory = True),
    "package": attr.string(doc = "Package name on pub.dev", mandatory = True),
    "version": attr.string(doc = "Package version (optional, defaults to latest)"),
    "sha256": attr.string(doc = "Expected SHA-256 of the package archive (optional; pins the download)"),
})

pub_deps_manifest = tag_class(attrs = {
    "files": attr.label_list(doc = """\
Labels of `pub_deps.json` manifests whose packages become `@pub_*`
repositories. Declaring the tag at all is the opt-in signal; `files = []` is
the explicit opt-out for a module that has no manifests.

These labels are read, never analyzed, so they need no BUILD file of their
own: a manifest in a directory that is not a Bazel package is spelled
relative to the nearest enclosing package, e.g. `//:sub_dir/pub_deps.json`.
""", default = []),
})

def _sanitize_repo_name(package):
    """Generate a deterministic repository name for a package."""

    def _is_valid_char(ch):
        return (
            ("a" <= ch and ch <= "z") or
            ("A" <= ch and ch <= "Z") or
            ("0" <= ch and ch <= "9") or
            ch == "_"
        )

    sanitized = []
    for idx in range(len(package)):
        ch = package[idx]
        sanitized.append(ch if _is_valid_char(ch) else "_")
    return "pub_" + "".join(sanitized)

def _parse_pub_deps_json(content):
    """Return mapping of package -> metadata from pub_deps.json payload."""

    data = json.decode(content)
    packages = {}
    for entry in data.get("packages", []):
        name = entry.get("name")
        if not name:
            continue

        source = entry.get("source")
        version = entry.get("version")
        description = entry.get("description")
        url = _extract_description_url(description)
        if source == "hosted" and version:
            packages[name] = {
                "version": version,
                "url": url or "https://pub.dev",
                "sha256": entry.get("sha256") or "",
                "dependencies": [dep for dep in entry.get("dependencies", []) if type(dep) == "string"],
            }

    return packages

def _prune_dependency_cycles(edges):
    """Return edges with back edges removed via iterative DFS.

    The pub universe contains genuine dependency cycles (e.g. dio <->
    dio_web_adapter) that Bazel target graphs cannot express. Dropping the
    back edge keeps cache propagation intact for any consumer that reaches
    the cycle through its conventional entry point.
    """
    UNVISITED = 0
    ON_STACK = 1
    DONE = 2

    state = {name: UNVISITED for name in edges.keys()}
    pruned = {name: [] for name in edges.keys()}

    for root in sorted(edges.keys()):
        if state[root] != UNVISITED:
            continue

        # Each stack frame is [node, next_child_index].
        stack = [[root, 0]]
        state[root] = ON_STACK
        for _ in range(1000000):  # bounded loop: Starlark has no while
            if not stack:
                break
            frame = stack[-1]
            node, idx = frame[0], frame[1]
            children = edges[node]
            if idx >= len(children):
                state[node] = DONE
                stack.pop()
                continue
            frame[1] = idx + 1
            child = children[idx]
            if child not in state:
                continue
            if state[child] == ON_STACK:
                # Back edge: dropping it breaks the cycle.
                continue
            pruned[node].append(child)
            if state[child] == UNVISITED:
                state[child] = ON_STACK
                stack.append([child, 0])

    return pruned

def _extract_description_url(description):
    if type(description) == "string":
        return description
    if type(description) == "dict":
        return (
            description.get("url") or
            description.get("base_url") or
            description.get("hosted_url") or
            description.get("hosted-url")
        )
    return None

def _register_repo(repo_map, repo_name, package, version, origin, from_root = True, tagged = False, sha256 = ""):
    """Merge repository metadata ensuring consistency across lockfiles/tags.

    Root-module registrations (pub_deps.json scans and root pub.package tags)
    take precedence: a conflicting non-root tag — e.g. a ruleset pinning a
    default tooling version — is silently ignored when the root already pinned
    the package. A repository registered through any pub.package tag is marked
    `tagged` (it keeps its fetch-time vendored .pub_cache so it can be
    executed from the repository), regardless of which registration's version
    wins.
    """
    existing = repo_map.get(repo_name)
    if existing:
        if tagged:
            existing["tagged"] = True
        if not from_root and existing["from_root"]:
            return
        if from_root and not existing["from_root"]:
            repo_map[repo_name] = {
                "package": package,
                "version": version,
                "origins": [origin],
                "from_root": True,
                "tagged": existing["tagged"] or tagged,
                "sha256": sha256 or existing["sha256"],
            }
            return
        if existing["package"] != package:
            fail(
                "Repository '{}' resolves to multiple packages: '{}' from {} vs '{}' from {}".format(
                    repo_name,
                    existing["package"],
                    ", ".join(existing["origins"]),
                    package,
                    origin,
                ),
            )
        if version and existing["version"] and version != existing["version"]:
            fail(
                ("Repository '{}' has conflicting versions: '{}' from {} vs '{}' from {}\n\n" +
                 "Two modules pin the same pub package at different versions. " +
                 "The root module has the last word: add a `pub.package` tag to " +
                 "the root MODULE.bazel to force the version you want, e.g.\n\n" +
                 "    pub.package(name = \"{}\", package = \"{}\", version = \"{}\")").format(
                    repo_name,
                    existing["version"],
                    ", ".join(existing["origins"]),
                    version,
                    origin,
                    repo_name,
                    package,
                    version,
                ),
            )
        if version and not existing["version"]:
            existing["version"] = version
        if sha256 and existing["sha256"] and sha256 != existing["sha256"]:
            fail(
                "Repository '{}' has conflicting sha256 pins: '{}' from {} vs '{}' from {}".format(
                    repo_name,
                    existing["sha256"],
                    ", ".join(existing["origins"]),
                    sha256,
                    origin,
                ),
            )
        if sha256 and not existing["sha256"]:
            existing["sha256"] = sha256
        existing["origins"].append(origin)
        return

    repo_map[repo_name] = {
        "package": package,
        "version": version,
        "origins": [origin],
        "from_root": from_root,
        "tagged": tagged,
        "sha256": sha256,
    }

_NO_MANIFEST_TAGS_ERROR = """\
The pub extension found no `deps_manifest` tag in the root module.

rules_flutter no longer scans the workspace for `pub_deps.json`; every
manifest must be declared explicitly, which is what lets Bazel invalidate the
extension when one is added or removed.

Find your manifests:

    find . -name pub_deps.json -not -path './bazel-*'

then declare them in MODULE.bazel:

    pub = use_extension("@rules_flutter//flutter:extensions.bzl", "pub")
    pub.deps_manifest(files = [
        "//my_app:pub_deps.json",
    ])

A manifest whose directory is not a Bazel package (no BUILD file) is spelled
relative to the nearest enclosing package, e.g. `//:my_app/pub_deps.json`.

If this module genuinely has no manifests, acknowledge that explicitly with:

    pub.deps_manifest(files = [])
"""

def _pub_extension(module_ctx):
    """Extension implementation for pub.dev packages."""
    repos = {}
    seen_manifests = {}
    dep_edges = {}
    root_declared_manifest_tag = False

    for mod in module_ctx.modules:
        for tag in mod.tags.deps_manifest:
            if mod.is_root:
                root_declared_manifest_tag = True
            for label in tag.files:
                label_key = str(label)
                if label_key in seen_manifests:
                    continue
                seen_manifests[label_key] = True

                deps_path = module_ctx.path(label)

                # module_ctx.path() happily returns a path for a source file
                # that does not exist; without this guard the read below fails
                # with a bare I/O error naming an execroot path.
                if not deps_path.exists:
                    fail(
                        "pub.deps_manifest declares {}, but no such file exists (looked at {}).".format(
                            label_key,
                            str(deps_path),
                        ),
                    )
                module_ctx.watch(deps_path)
                packages = _parse_pub_deps_json(module_ctx.read(deps_path))
                for package, info in packages.items():
                    repo_name = _sanitize_repo_name(package)
                    _register_repo(
                        repos,
                        repo_name,
                        package,
                        info.get("version"),
                        label_key,
                        from_root = mod.is_root,
                        sha256 = info.get("sha256") or "",
                    )
                    merged = {dep: True for dep in dep_edges.get(package, [])}
                    for dep in info.get("dependencies", []):
                        merged[dep] = True
                    dep_edges[package] = sorted(merged.keys())

    if not root_declared_manifest_tag:
        fail(_NO_MANIFEST_TAGS_ERROR)

    for mod in module_ctx.modules:
        for pkg in mod.tags.package:
            origin = "{}/MODULE.bazel:{}".format(mod.name or "root", pkg.name)
            _register_repo(
                repos,
                pkg.name,
                pkg.package,
                pkg.version,
                origin,
                from_root = mod.is_root,
                tagged = True,
                sha256 = pkg.sha256,
            )

    # Restrict recorded edges to hosted packages that actually have repos and
    # break dependency cycles so the generated target graph is a DAG.
    known_packages = {meta["package"]: True for meta in repos.values()}
    hosted_edges = {
        package: [dep for dep in deps if dep in known_packages]
        for package, deps in dep_edges.items()
    }
    pruned_edges = _prune_dependency_cycles(hosted_edges)

    for repo_name in sorted(repos.keys()):
        meta = repos[repo_name]
        package = meta["package"]
        if package in pruned_edges:
            pub_dev_repository(
                name = repo_name,
                package = package,
                version = meta["version"],
                hosted_deps = pruned_edges[package],
                hosted_deps_explicit = True,
                keep_vendored_cache = meta["tagged"],
                resolve_deps = meta["tagged"],
                sha256 = meta["sha256"],
            )
        else:
            pub_dev_repository(
                name = repo_name,
                package = package,
                version = meta["version"],
                keep_vendored_cache = meta["tagged"],
                resolve_deps = meta["tagged"],
                sha256 = meta["sha256"],
            )

    # `bazel mod tidy` maintains use_repo() from this. The extension cannot
    # see BUILD files, so it deliberately over-approximates and reports every
    # generated repository as a direct dep. Under-approximating breaks the
    # build: `@pub_analyzer`, `@pub_path` and `@pub_protoc_plugin` are all
    # referenced from BUILD files while being transitive (or registered by a
    # non-root module's pub.package tag), so any narrower rule would have
    # tidy prune them.
    return module_ctx.extension_metadata(
        root_module_direct_deps = sorted(repos.keys()),
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

pub = module_extension(
    implementation = _pub_extension,
    tag_classes = {
        "deps_manifest": pub_deps_manifest,
        "package": pub_package,
    },
)
