"""Implementation of the flutter_library rule."""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_info", "derive_lib_root", "derive_package_name")
load("//flutter:providers.bzl", "FlutterInfo")

def asset_package_name(asset_namespace, package_name):
    """Returns the asset bundle namespace for a first-party library."""
    return package_name if asset_namespace == "package" else ""

def build_pub_contributions(package_name, fonts_json, font_files_dict, pkg_assets_dict, pkg_shaders_dict):
    """Build pub_fonts/pub_assets/pub_shaders contribution structs from rule attrs.

    Decodes the JSON-encoded font declarations and walks the file dicts,
    producing the contribution structs that `build_flutter_providers` accepts
    as `extra_pub_fonts` / `extra_pub_assets` / `extra_pub_shaders`.

    Args:
        package_name: str — empty string for non-package contributions
            (no `packages/<pkg>/` prefix at bundle time), else the pub package
            name (or first-party package name) used as the prefix.
        fonts_json: str — JSON-encoded list of
            `{family: str, fonts: [{asset: str, weight: int?, style: str?}]}`.
            Empty string when the rule declares no fonts.
        font_files_dict: dict[Target, str] — `ctx.attr.font_files`. Each
            target must resolve to exactly one File. The string value is the
            package-relative asset path matching an entry in fonts_json.
        pkg_assets_dict: dict[Target, str] — `ctx.attr.pkg_assets`. Same
            shape, for non-font assets.
        pkg_shaders_dict: dict[Target, str] — `ctx.attr.pkg_shaders`. Same
            shape, for shaders.

    Returns:
        Tuple of (extra_pub_fonts, extra_pub_assets, extra_pub_shaders) lists.
    """
    extra_pub_fonts = []
    if fonts_json:
        decoded = json.decode(fonts_json)
        path_to_file = {}
        for target, asset_path in font_files_dict.items():
            files = target.files.to_list()
            if len(files) != 1:
                fail("font_files entry %s must resolve to exactly one File; got %d" % (target.label, len(files)))
            path_to_file[asset_path] = files[0]

        # Tuples (not lists) inside the struct because depset elements must
        # be fully immutable — mutable fields propagate to the struct's
        # mutability check.
        for family_entry in decoded:
            family = family_entry.get("family", "")
            fonts_list = []
            file_list = []
            for font in family_entry.get("fonts", []):
                asset_path = font.get("asset", "")
                fonts_list.append(struct(
                    asset_path = asset_path,
                    weight = font.get("weight"),
                    style = font.get("style"),
                ))
                if asset_path in path_to_file:
                    file_list.append(path_to_file[asset_path])
            extra_pub_fonts.append(struct(
                package_name = package_name,
                family = family,
                fonts = tuple(fonts_list),
                files = tuple(file_list),
            ))

    extra_pub_assets = []
    for target, asset_path in pkg_assets_dict.items():
        files = target.files.to_list()
        if len(files) != 1:
            fail("pkg_assets entry %s must resolve to exactly one File; got %d" % (target.label, len(files)))
        extra_pub_assets.append(struct(
            package_name = package_name,
            asset_path = asset_path,
            file = files[0],
        ))

    extra_pub_shaders = []
    for target, shader_path in pkg_shaders_dict.items():
        files = target.files.to_list()
        if len(files) != 1:
            fail("pkg_shaders entry %s must resolve to exactly one File; got %d" % (target.label, len(files)))
        extra_pub_shaders.append(struct(
            package_name = package_name,
            shader_path = shader_path,
            file = files[0],
        ))

    return (extra_pub_fonts, extra_pub_assets, extra_pub_shaders)

def aggregate_pub_contributions(deps):
    """Walk transitive `FlutterInfo.pub_fonts` / `pub_assets` from deps.

    Each contribution carries `package_name` — the empty string sentinel
    means "non-package contribution, bundle at bare path"; any other value
    triggers a `packages/<package_name>/` prefix on the family name and
    every asset path. This matches Flutter's CLI behavior and the const
    finder's tree-shaking key shape (`packages/<pkg>/<family>` only when
    the IconData has a non-null `fontPackage`).

    Args:
        deps: List of Targets — typically `ctx.attr.deps`.

    Returns:
        Tuple of:
          - fonts: list of FontManifest entries (dicts) with prefixed family
            + per-font asset paths and optional weight/style.
          - extra_asset_copies: dict[str, File] mapping bundle dest path to
            File for both fonts and non-font pub-package assets.
    """
    pub_fonts = []
    pub_assets = []
    for dep in deps:
        if FlutterInfo not in dep:
            continue
        info = dep[FlutterInfo]
        if hasattr(info, "pub_fonts") and info.pub_fonts != None:
            pub_fonts.extend(info.pub_fonts.to_list())
        if hasattr(info, "pub_assets") and info.pub_assets != None:
            pub_assets.extend(info.pub_assets.to_list())

    fonts = []
    extra_asset_copies = {}

    for entry in pub_fonts:
        prefix = "packages/{}/".format(entry.package_name) if entry.package_name else ""
        family_str = prefix + entry.family
        fonts_descriptors = []
        for i, font in enumerate(entry.fonts):
            descriptor = {"asset": prefix + font.asset_path}
            if font.weight != None:
                descriptor["weight"] = font.weight
            if font.style != None:
                descriptor["style"] = font.style
            fonts_descriptors.append(descriptor)
            if i < len(entry.files):
                extra_asset_copies[prefix + font.asset_path] = entry.files[i]
        fonts.append({"family": family_str, "fonts": fonts_descriptors})

    for entry in pub_assets:
        prefix = "packages/{}/".format(entry.package_name) if entry.package_name else ""
        extra_asset_copies[prefix + entry.asset_path] = entry.file

    return (fonts, extra_asset_copies)

def dedup_plugins(all_plugins):
    """Deduplicate plugins by name (first occurrence wins).

    Args:
        all_plugins: List of plugin structs.

    Returns:
        List of unique plugin structs.
    """
    seen = {}
    unique = []
    for p in all_plugins:
        if p.name not in seen:
            seen[p.name] = True
            unique.append(p)
    return unique

def build_flutter_providers(ctx, package_name, lib_root, extra_plugins = [], extra_native_libs = [], extra_apple_plugin_libraries = [], extra_linux_plugin_libraries = [], extra_windows_plugin_libraries = [], extra_android_plugin_libraries = [], extra_apple_privacy_manifests = [], extra_native_assets = [], extra_data_assets = [], extra_pub_fonts = [], extra_pub_assets = [], extra_pub_shaders = [], language_version = ""):
    """Build DartInfo + FlutterInfo from the common flutter library/plugin pattern.

    Collects transitive sources, packages, assets, plugins, and native libs
    from ctx.attr.deps.

    Args:
        ctx: Rule context (must have srcs, deps, assets attrs).
        package_name: The Dart package name.
        lib_root: The library root path.
        extra_plugins: Additional plugin structs to prepend (e.g. this plugin's own struct).
        extra_native_libs: Additional native lib depsets to merge (e.g. from native_deps).
        extra_apple_plugin_libraries: Additional Apple plugin library
            structs (each with `platform`, `label`, `cc_info`,
            `swift_info`, `package`) emitted by the current target —
            typically populated by flutter_plugin from its
            `apple_libs` attr. Merged transitively through
            `FlutterInfo.apple_plugin_libraries`.
        extra_linux_plugin_libraries: Additional Linux plugin source
            bundles (each with `label`, `srcs`, `hdrs`, `include_dirs`,
            `package`) — typically populated by flutter_plugin from
            `linux_libs`. Merged transitively through
            `FlutterInfo.linux_plugin_libraries`.
        extra_windows_plugin_libraries: Additional Windows plugin
            source bundles, same shape as the Linux ones. Merged
            transitively through `FlutterInfo.windows_plugin_libraries`.
        extra_android_plugin_libraries: Additional Android plugin
            library structs (each with `label`, `package`) emitted by
            the current target — typically populated by flutter_plugin
            from `android_libs`. Merged transitively through
            `FlutterInfo.android_plugin_libraries`.
        extra_apple_privacy_manifests: Additional Apple
            `PrivacyInfo.xcprivacy` files contributed directly by the
            current target — typically populated by `flutter_plugin`
            from its `apple_privacy_files` attr. Merged transitively
            through `FlutterInfo.apple_privacy_manifests` and
            ultimately bundled by the platform application rule.
        extra_native_assets: Additional `FlutterNativeAssetInfo`
            providers contributed directly by the current target —
            typically populated by `flutter_plugin` from its
            `native_assets` attr. Merged transitively through
            `FlutterInfo.native_assets`.
        extra_data_assets: Additional `FlutterDataAssetInfo` providers
            contributed directly by the current target — typically
            populated by `flutter_plugin` from its `data_assets` attr.
            Merged transitively through `FlutterInfo.data_assets`.
        extra_pub_fonts: Additional pub-package font contribution
            structs (`package_name`, `family`, `fonts`, `files`)
            emitted by the current target — populated by
            `flutter_pub_library` from its parsed `flutter.fonts`
            block. Merged transitively through `FlutterInfo.pub_fonts`.
        extra_pub_assets: Additional pub-package asset contribution
            structs (`package_name`, `asset_path`, `file`) emitted by
            the current target — populated by `flutter_pub_library`
            from its parsed `flutter.assets` block. Merged transitively
            through `FlutterInfo.pub_assets`.
        extra_pub_shaders: Additional pub-package shader contribution
            structs (same shape as `extra_pub_assets`) emitted by the
            current target. Merged transitively through
            `FlutterInfo.pub_shaders`.
        language_version: Dart language version (`<major>.<minor>`) for this
            package, propagated through DartPackageInfo so the generated
            `package_config.json` entry carries `languageVersion`. Empty
            string means "let the toolchain default apply" — same semantics
            as `dart_library`'s attribute.

    Returns:
        Tuple of (DartInfo, FlutterInfo).
    """

    # Code assets ride on the package record, which is what makes them
    # propagate the way pub does: depending on a package that owns one is
    # enough, and no consumer has to name it. rules_dart owns the declaration
    # (`DartCodeAssetInfo`); everything Flutter adds — bundle filename, the
    # per-platform bundle slot — is applied later by the application rule.
    own_code_assets = [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets]

    transitive_asset_dirs = depset(
        direct = ctx.files.assets,
        transitive = [
            dep[FlutterInfo].asset_dirs
            for dep in ctx.attr.deps
            if FlutterInfo in dep
        ],
    )

    # Collect shader sources from this target and transitively from deps.
    direct_shaders = ctx.files.shaders if hasattr(ctx.attr, "shaders") else []
    transitive_shader_srcs = depset(
        direct = direct_shaders,
        transitive = [
            dep[FlutterInfo].shader_srcs
            for dep in ctx.attr.deps
            if FlutterInfo in dep
        ],
    )

    # Merge plugins transitively from deps, dedup by name.
    dep_plugins = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            dep_plugins.extend(dep[FlutterInfo].plugins)
    all_plugins = dedup_plugins(extra_plugins + dep_plugins)

    # Merge transitive native libs.
    transitive_native_libs = depset(
        transitive = extra_native_libs + [
            dep[FlutterInfo].transitive_native_libs
            for dep in ctx.attr.deps
            if FlutterInfo in dep
        ],
    )

    # Merge transitive apple plugin libraries.
    apple_plugin_libraries = depset(
        direct = extra_apple_plugin_libraries,
        transitive = [
            dep[FlutterInfo].apple_plugin_libraries
            for dep in ctx.attr.deps
            if FlutterInfo in dep
        ],
    )

    # Merge transitive linux + windows plugin libraries (source bundles).
    linux_plugin_libraries = depset(
        direct = extra_linux_plugin_libraries,
        transitive = [
            dep[FlutterInfo].linux_plugin_libraries
            for dep in ctx.attr.deps
            if FlutterInfo in dep
        ],
    )
    windows_plugin_libraries = depset(
        direct = extra_windows_plugin_libraries,
        transitive = [
            dep[FlutterInfo].windows_plugin_libraries
            for dep in ctx.attr.deps
            if FlutterInfo in dep
        ],
    )

    # Merge transitive android plugin libraries.
    android_plugin_libraries = depset(
        direct = extra_android_plugin_libraries,
        transitive = [
            dep[FlutterInfo].android_plugin_libraries
            for dep in ctx.attr.deps
            if FlutterInfo in dep
        ],
    )

    # Merge transitive Apple privacy manifests (PrivacyInfo.xcprivacy
    # files). Apple's App Store submission walks the bundle for these
    # files; we collect them here and bundle via the platform application
    # rules' `additional_contents`.
    apple_privacy_manifests = depset(
        direct = extra_apple_privacy_manifests,
        transitive = [
            dep[FlutterInfo].apple_privacy_manifests
            for dep in ctx.attr.deps
            if FlutterInfo in dep and hasattr(dep[FlutterInfo], "apple_privacy_manifests") and dep[FlutterInfo].apple_privacy_manifests != None
        ],
    )

    # Merge transitive Native Assets code + data declarations.
    native_assets = depset(
        direct = extra_native_assets,
        transitive = [
            dep[FlutterInfo].native_assets
            for dep in ctx.attr.deps
            if FlutterInfo in dep and hasattr(dep[FlutterInfo], "native_assets") and dep[FlutterInfo].native_assets != None
        ],
    )
    data_assets = depset(
        direct = extra_data_assets,
        transitive = [
            dep[FlutterInfo].data_assets
            for dep in ctx.attr.deps
            if FlutterInfo in dep and hasattr(dep[FlutterInfo], "data_assets") and dep[FlutterInfo].data_assets != None
        ],
    )

    # Merge transitive pub-package contributions (fonts/assets/shaders from
    # flutter:-block parsing). Each entry carries package_name as the empty
    # string for non-package contributions (e.g. the toolchain MaterialIcons
    # target), or the real pub package name otherwise.
    pub_fonts = depset(
        direct = extra_pub_fonts,
        transitive = [
            dep[FlutterInfo].pub_fonts
            for dep in ctx.attr.deps
            if FlutterInfo in dep and hasattr(dep[FlutterInfo], "pub_fonts") and dep[FlutterInfo].pub_fonts != None
        ],
    )
    pub_assets = depset(
        direct = extra_pub_assets,
        transitive = [
            dep[FlutterInfo].pub_assets
            for dep in ctx.attr.deps
            if FlutterInfo in dep and hasattr(dep[FlutterInfo], "pub_assets") and dep[FlutterInfo].pub_assets != None
        ],
    )
    pub_shaders = depset(
        direct = extra_pub_shaders,
        transitive = [
            dep[FlutterInfo].pub_shaders
            for dep in ctx.attr.deps
            if FlutterInfo in dep and hasattr(dep[FlutterInfo], "pub_shaders") and dep[FlutterInfo].pub_shaders != None
        ],
    )

    dart_info_provider = dart_info(
        label = ctx.label,
        package_name = package_name,
        lib_root = lib_root,
        deps = ctx.attr.deps,
        srcs = ctx.files.srcs,
        code_assets = own_code_assets,
        language_version = language_version,
        has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
    )
    flutter_info = FlutterInfo(
        asset_dirs = transitive_asset_dirs,
        shader_srcs = transitive_shader_srcs,
        plugins = all_plugins,
        transitive_native_libs = transitive_native_libs,
        apple_plugin_libraries = apple_plugin_libraries,
        linux_plugin_libraries = linux_plugin_libraries,
        windows_plugin_libraries = windows_plugin_libraries,
        android_plugin_libraries = android_plugin_libraries,
        apple_privacy_manifests = apple_privacy_manifests,
        native_assets = native_assets,
        data_assets = data_assets,
        pub_fonts = pub_fonts,
        pub_assets = pub_assets,
        pub_shaders = pub_shaders,
    )
    return (dart_info_provider, flutter_info)

def _flutter_library_impl(ctx):
    package_name = derive_package_name(
        ctx.attr.package_name,
        ctx.label.package,
        ctx.label.name,
    )
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Dart package identity and asset identity are independent. Applications
    # still need an explicit Dart package name for package: imports, while
    # their own assets use the root namespace that `flutter build` gives the
    # root pubspec. Pub packages retain packages/<name>/ by default.
    asset_pkg = asset_package_name(ctx.attr.asset_namespace, package_name)
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = build_pub_contributions(
        asset_pkg,
        ctx.attr.fonts_json,
        ctx.attr.font_files,
        ctx.attr.pkg_assets,
        ctx.attr.pkg_shaders,
    )

    dart_info, flutter_info = build_flutter_providers(
        ctx,
        package_name,
        lib_root,
        extra_pub_fonts = extra_pub_fonts,
        extra_pub_assets = extra_pub_assets,
        extra_pub_shaders = extra_pub_shaders,
        language_version = ctx.attr.language_version,
    )

    return [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = ctx.runfiles(files = ctx.files.srcs + ctx.files.assets),
        ),
        dart_info,
        flutter_info,
    ]

flutter_library = rule(
    implementation = _flutter_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart source files for this library.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other `dart_library` or `flutter_library` targets this library depends on.",
            providers = [DartInfo],
        ),
        "assets": attr.label_list(
            doc = "Flutter asset files (images, fonts, etc.) declared in pubspec.yaml.",
            allow_files = True,
        ),
        "shaders": attr.label_list(
            doc = "Shader source files (.frag/.glsl) to compile per-platform and include in the asset bundle.",
            allow_files = [".frag", ".glsl"],
        ),
        "package_name": attr.string(
            doc = "The Dart package name. If omitted, defaults to the last component of the Bazel package path.",
        ),
        "asset_namespace": attr.string(
            doc = "Asset bundle namespace. `package` (default) emits packages/<package_name>/ paths; `root` emits bare application paths.",
            default = "package",
            values = ["package", "root"],
        ),
        "code_assets": attr.label_list(
            doc = "`dart_code_asset` targets standing in for this package's " +
                  "`hook/build.dart` output. Declared on the owning package " +
                  "rather than on the consuming application so they propagate " +
                  "the way pub's own do — depending on the package is enough.",
            providers = [DartCodeAssetInfo],
        ),
        "has_unreplaced_hook": attr.string(
            doc = "Path of a build hook this package ships that nothing " +
                  "replaces, or empty. Recorded at repo generation; the " +
                  "application that depends on the package fails on it.",
        ),
        "language_version": attr.string(
            doc = "Dart language version (`<major>.<minor>`) for this package's `package_config.json` entry. Mirrors `dart_library`'s attribute. Empty string means defer to the toolchain default.",
        ),
        "fonts_json": attr.string(
            doc = "JSON-encoded list of font-family declarations (mirrors `flutter.fonts` in pubspec.yaml). Each entry: `{family: str, fonts: [{asset: str, weight: int?, style: str?}]}`. The `asset` paths are package-relative and must each match a key in `font_files`. The asset bundle aggregator prefixes family + asset paths with `packages/<package_name>/` when asset_namespace is `package`; `root` emits bare paths.",
            default = "",
        ),
        "font_files": attr.label_keyed_string_dict(
            doc = "Map of font File label -> package-relative asset path. The string value must match an `asset` field in `fonts_json`. The file is bundled according to asset_namespace.",
            allow_files = True,
        ),
        "pkg_assets": attr.label_keyed_string_dict(
            doc = "Map of asset File label -> package-relative path (mirrors `flutter.assets` in pubspec.yaml). Bundled according to asset_namespace and included in AssetManifest.",
            allow_files = True,
        ),
        "pkg_shaders": attr.label_keyed_string_dict(
            doc = "Map of shader File label -> package-relative path (mirrors `flutter.shaders` in pubspec.yaml). Routed through impellerc and bundled according to asset_namespace.",
            allow_files = True,
        ),
    },
    doc = "Collects Flutter sources and assets, propagates DartInfo and FlutterInfo. Does not compile.",
)
