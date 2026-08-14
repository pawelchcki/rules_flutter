"""Extensions for bzlmod.

Installs a flutter toolchain.
Every module can define a toolchain version under the default name, "flutter".
The latest of those versions will be selected (the rest discarded),
and will always be registered by ruleslab_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

# bazel_linux_packages exposes repository creation only through its module
# extension. Extensions cannot invoke other extensions, so compose its pinned
# repository rules directly until upstream publishes a public composition API.
# buildifier: disable=bzl-visibility
load("@bazel_linux_packages//apt/private:deb_download.bzl", "deb_download")

# buildifier: disable=bzl-visibility
load("@bazel_linux_packages//apt/private:deb_install.bzl", "deb_install")

# buildifier: disable=bzl-visibility
load("@bazel_linux_packages//apt/private:deb_repository.bzl", "deb_repository")

# buildifier: disable=bzl-visibility
load("@bazel_linux_packages//apt/private:integrities.bzl", "INTEGRITIES")
load("@hermetic_android_toolchains//ndk:repositories.bzl", "ANDROID_NDK_LICENSE_ENV", "hermetic_android_ndk_platform_repository", "hermetic_android_ndk_repository")
load("@hermetic_android_toolchains//private:utils.bzl", "ANDROID_PLATFORMS")
load("@hermetic_android_toolchains//sdk:repositories.bzl", "ANDROID_SDK_LICENSE_ENV", "hermetic_android_sdk_platform_repository", "hermetic_android_sdk_repository")
load("//flutter/private:android_repositories.bzl", "android_toolchains_repository", "gradle_repository")
load("//flutter/private:linux_repositories.bzl", "LINUX_ARCHITECTURES", "LINUX_PACKAGES", "LINUX_PACKAGE_COMPONENTS", "LINUX_PACKAGE_SNAPSHOT", "LINUX_PACKAGE_SUITES", "linux_toolchains_repository")
load("//flutter/private:pub_lock_hub.bzl", "pub_lock_hub")
load("//flutter/private:pub_repository.bzl", "pub_dev_repository")
load("//flutter/private:pubspec_lock.bzl", "lock_hosted_packages", "parse_pubspec_lock")
load("//flutter/private:version_select.bzl", "highest_version")
load("//flutter/private:versions.bzl", "LATEST_STABLE_VERSION", "TOOL_VERSIONS")
load(":repositories.bzl", "flutter_register_toolchains")

_DEFAULT_NAME = "flutter"

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one flutter toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "flutter_version": attr.string(
        doc = "Flutter version. Defaults to the newest integrity-verified stable release in the checked-in version table.",
        default = LATEST_STABLE_VERSION,
    ),
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

linux_toolchain = tag_class(attrs = {
    "name": attr.string(
        default = "linux",
        doc = "Base name for generated hermetic Linux package and toolchain repositories. The pinned Ubuntu Jammy closure supports Linux x86_64 and arm64 execution platforms and includes Clang, CMake, Ninja, pkg-config, GTK 3 development files, binutils, and the C/C++ runtime. Declare this tag in the root module, import <name>_toolchains with use_repo, and register @<name>_toolchains//:all.",
    ),
})

def _linux_package_input_data():
    return json.encode({
        "architectures": sorted(LINUX_ARCHITECTURES.keys()),
        "packages": LINUX_PACKAGES,
    })

def _create_linux_toolchain(name):
    """Instantiate the locked Ubuntu package closure and its Bazel toolchains."""
    source_repo = "{}_repository".format(name)
    index_repo = "{}_index".format(name)
    input_data = _linux_package_input_data()
    lockfile = Label("//flutter/private:linux_packages.lock.json")

    deb_repository.fetch(
        name = source_repo,
        architectures = sorted(LINUX_ARCHITECTURES.keys()),
        components = LINUX_PACKAGE_COMPONENTS,
        integrity = INTEGRITIES,
        suites = LINUX_PACKAGE_SUITES,
        uri = LINUX_PACKAGE_SNAPSHOT,
    )
    deb_download.index(
        name = index_repo,
        apparent_name = index_repo,
        architectures = sorted(LINUX_ARCHITECTURES.keys()),
        input_data = input_data,
        lockfile = lockfile,
        packages = LINUX_PACKAGES,
        resolve_transitive = True,
        sources = [source_repo],
    )

    # Include both multiarch layouts so a repository fetched while resolving
    # another platform is still described correctly. The installer silently
    # skips directories absent from the selected architecture's closure.
    patchelf_dirs = [
        "lib/aarch64-linux-gnu",
        "lib/x86_64-linux-gnu",
        "usr/bin",
        "usr/lib/aarch64-linux-gnu",
        "usr/lib/llvm-14/bin",
        "usr/lib/x86_64-linux-gnu",
    ]
    for architecture in sorted(LINUX_ARCHITECTURES.keys()):
        install_repo = "{}_{}".format(name, architecture)
        download_repo = "{}_download".format(install_repo)
        deb_download.download(
            name = download_repo,
            apparent_name = download_repo,
            architecture = architecture,
            index = index_repo,
            input_data = input_data,
            install_name = install_repo,
            lockfile = lockfile,
            sources = [source_repo],
        )
        deb_install(
            name = install_repo,
            add_files = {},
            apparent_name = install_repo,
            architecture = architecture,
            build_file = Label("@bazel_linux_packages//apt:install.BUILD.bazel.tmpl"),
            build_file_substitutions = {},
            fix_absolute_interpreter_with_patchelf = False,
            fix_relative_interpreter_with_patchelf = True,
            fix_rpath_with_patchelf = True,
            # systemd ships a literal backslash in an escaped unit filename;
            # Bazel labels forbid that character. These service units are not
            # compiler/sysroot inputs, so omit the directory from the filegroup.
            glob_excludes = [
                "lib/systemd/system/**",
                "usr/share/man/**",
            ],
            glob_pattern = ["**"],
            patchelf_dirs = patchelf_dirs,
            post_install_cmd = {},
            source = download_repo,
        )

    linux_toolchains_repository(
        name = "{}_toolchains".format(name),
        packages_repository = name,
    )

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
            # This repository uses the extension to test itself. When it is a
            # dependency, keep its apparent repository mappings available to
            # internal repository rules but do not let its self-test SDK pin
            # constrain the consuming root module's explicit selection.
            if mod.name == "rules_flutter" and not mod.is_root:
                continue
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

    linux_tags = []
    for mod in module_ctx.modules:
        if mod.tags.linux_toolchain:
            if not mod.is_root:
                fail("flutter.linux_toolchain(...) may only be declared by the root module")
            linux_tags.extend(mod.tags.linux_toolchain)
    linux_names = {}
    for linux in linux_tags:
        if linux.name in linux_names:
            fail("flutter.linux_toolchain name '{}' was declared more than once".format(linux.name))
        linux_names[linux.name] = True
        _create_linux_toolchain(linux.name)

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
        "linux_toolchain": linux_toolchain,
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

pub_lock = tag_class(attrs = {
    "name": attr.string(doc = """\
Name of the hub repository generated for this lock. Depend on
`@<name>//:all` to get the lock's entire package closure, or on
`@<name>//:<package>` for one package of it.
""", mandatory = True),
    "file": attr.label(doc = """\
Label of the `pubspec.lock` whose packages become repositories.

The label is read, never analyzed, so it needs no BUILD file of its own: a
lock in a directory that is not a Bazel package is spelled relative to the
nearest enclosing package, e.g. `//:sub_dir/pubspec.lock`.
""", mandatory = True, allow_single_file = True),
})

pub_no_locks = tag_class(attrs = {}, doc = """\
Explicit acknowledgement that this module declares no `pubspec.lock`.

The pub extension refuses to silently do nothing, so a module with no locks
says so rather than omitting every tag.
""")

def _sanitize(package):
    """Reduce a package name to characters legal in a repository name."""

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
    return "".join(sanitized)

def _register_repo(repo_map, repo_name, package, version, origin, from_root = True, tagged = False, sha256 = ""):
    """Merge pub.package registrations, ensuring consistency across modules.

    Root-module registrations take precedence: a conflicting non-root tag —
    e.g. a ruleset pinning a default tooling version — is silently ignored
    when the root already pinned the package. A repository registered through any pub.package tag is marked
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

_NO_LOCK_TAGS_ERROR = """\
The pub extension found no `lock` tag in the root module.

Every `pubspec.lock` must be declared explicitly, which is what lets Bazel
invalidate the extension when one is added, changed or removed.

Find your locks:

    find . -name pubspec.lock -not -path './bazel-*'

then declare one hub per lock in MODULE.bazel:

    pub = use_extension("@rules_flutter//flutter:extensions.bzl", "pub")
    pub.lock(name = "my_app_deps", file = "//my_app:pubspec.lock")
    use_repo(pub, "my_app_deps")

and depend on the closure from the library that owns the lock:

    flutter_library(
        name = "lib",
        pubspec = "pubspec.yaml",
        lock = "pubspec.lock",
        deps = ["@my_app_deps//:all"],
    )

A lock whose directory is not a Bazel package (no BUILD file) is spelled
relative to the nearest enclosing package, e.g. `//:my_app/pubspec.lock`.

If this module genuinely has no locks, acknowledge that explicitly with:

    pub.no_locks()
"""

def _pub_extension(module_ctx):
    """Extension implementation for pub.dev packages."""
    repos = {}
    hubs = {}
    dev_hubs = {}
    seen_locks = {}
    root_declared_lock_tag = False

    for mod in module_ctx.modules:
        if mod.is_root and (mod.tags.lock or mod.tags.no_locks):
            root_declared_lock_tag = True
        for tag in mod.tags.lock:
            if tag.name in hubs:
                fail("Two pub.lock tags both declare the hub repository '{}'.".format(tag.name))

            label_key = str(tag.file)
            if label_key in seen_locks:
                fail(
                    "pub.lock declares {} twice, as '{}' and '{}'. One lock is one hub.".format(
                        label_key,
                        seen_locks[label_key],
                        tag.name,
                    ),
                )
            seen_locks[label_key] = tag.name

            lock_path = module_ctx.path(tag.file)

            # module_ctx.path() happily returns a path for a source file that
            # does not exist; without this guard the read below fails with a
            # bare I/O error naming an execroot path.
            if not lock_path.exists:
                fail(
                    "pub.lock declares {}, but no such file exists (looked at {}).".format(
                        label_key,
                        str(lock_path),
                    ),
                )
            module_ctx.watch(lock_path)
            packages = lock_hosted_packages(
                parse_pubspec_lock(module_ctx.read(lock_path), origin = label_key),
            )

            spokes = {}
            for package, info in packages.items():
                # Leaf repositories are addressed only from the hub, which is
                # generated by this same extension, so their names never need
                # to be use_repo'd and are free to carry the hub prefix that
                # keeps two locks' versions of a package apart.
                spoke = "{}__{}".format(tag.name, _sanitize(package))
                spokes[package] = spoke
                repos[spoke] = {
                    "package": package,
                    "version": info.version,
                    "sha256": info.sha256,
                    "origins": [label_key],
                    "tagged": False,
                    "from_root": mod.is_root,
                }
            hubs[tag.name] = struct(origin = label_key, spokes = spokes)

            # A hub declared through a dev_dependency proxy does not exist in
            # a consumer's graph, so reporting it as a non-dev direct dep
            # would have `bazel mod tidy` write a use_repo that breaks every
            # consumer.
            if mod.is_root and module_ctx.is_dev_dependency(tag):
                dev_hubs[tag.name] = True

    if not root_declared_lock_tag:
        fail(_NO_LOCK_TAGS_ERROR)

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

    for repo_name in sorted(repos.keys()):
        meta = repos[repo_name]
        pub_dev_repository(
            name = repo_name,
            package = meta["package"],
            version = meta["version"],
            keep_vendored_cache = meta["tagged"],
            resolve_deps = meta["tagged"],
            sha256 = meta["sha256"],
        )

    for hub_name in sorted(hubs.keys()):
        hub = hubs[hub_name]
        pub_lock_hub(
            name = hub_name,
            origin = hub.origin,
            spokes = hub.spokes,
        )

    # `bazel mod tidy` maintains use_repo() from this. Leaf repositories are
    # reached only through their hub's aliases, so the direct deps are exactly
    # the hubs plus the pub.package repositories, which BUILD files reference
    # by name to execute them as tools.
    direct = [name for name, meta in repos.items() if meta["tagged"]] + [
        name
        for name in hubs.keys()
        if name not in dev_hubs
    ]
    return module_ctx.extension_metadata(
        root_module_direct_deps = sorted(direct),
        root_module_direct_dev_deps = sorted(dev_hubs.keys()),
        reproducible = True,
    )

pub = module_extension(
    implementation = _pub_extension,
    tag_classes = {
        "lock": pub_lock,
        "no_locks": pub_no_locks,
        "package": pub_package,
    },
)
