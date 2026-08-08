"""Repository rule for downloading Dart packages from pub.dev.

Features:
- If `version` is omitted, resolves the latest stable version from pub.dev API.
- Generates BUILD targets for the package by analysing pubspec metadata.
"""

load("//flutter/private:package_generation.bzl", "generate_package_build")

_DOC = """Download and setup a Dart package from pub.dev"""

_ATTRS = {
    "package": attr.string(
        mandatory = True,
        doc = "Name of the package on pub.dev",
    ),
    # Version is optional; when omitted we resolve the latest stable version
    "version": attr.string(
        doc = "Version of the package. If omitted, the latest stable is used.",
    ),
    "sha256": attr.string(
        doc = """Expected SHA-256 of the package archive. When set, the download
is verified against it (and becomes eligible for the repository cache). When
unset, the downloaded archive's hash is printed so it can be pinned.""",
    ),
    "integrity": attr.string(
        doc = """Expected SRI checksum (e.g. sha256-...) of the package archive.
Alternative to sha256; at most one of the two may be set.""",
    ),
    "pub_dev_url": attr.string(
        default = "https://pub.dev",
        doc = "Base URL for pub.dev API",
    ),
    "sdk_repo": attr.string(
        default = "@flutter_sdk",
        doc = "Repository label providing Flutter SDK packages (e.g. @flutter_sdk)",
    ),
    # Fetch-time pub resolution must not depend on a host Flutter/Dart install:
    # these point the repository rule at the toolchain SDK's launchers, keeping
    # the resolved dependency closure (and the vendored .pub_cache the
    # protoc-gen-dart wrapper executes from) identical on every machine.
    "sdk_flutter": attr.label(
        default = "@flutter_sdk//:bin/flutter",
        doc = "Flutter launcher from the toolchain SDK used for fetch-time pub resolution.",
    ),
    "sdk_dart": attr.label(
        default = "@flutter_sdk//:bin/dart",
        doc = "Dart launcher from the toolchain SDK, used when the Flutter launcher is unavailable.",
    ),
    "hosted_deps": attr.string_list(
        default = [],
        doc = """Hosted package names to emit as target deps. Provided by the pub
module extension with dependency cycles already broken; only honored when
hosted_deps_explicit is set.""",
    ),
    "hosted_deps_explicit": attr.bool(
        default = False,
        doc = "Whether hosted_deps was computed by the extension (vs self-derived).",
    ),
    "keep_vendored_cache": attr.bool(
        default = True,
        doc = """Whether to keep the fetch-time vendored .pub_cache closure in the
repository after dependency resolution. The pub extension keeps it only for
pub.package-registered repositories, which may be executed directly from the
repository (e.g. protoc_plugin); for scan-discovered dependency repositories
the closure is deleted after pub_deps.json is generated.""",
    ),
    "resolve_deps": attr.bool(
        default = True,
        doc = """Whether to run a real `pub deps --json` resolution at fetch time.
The pub extension passes False for scan-discovered dependency repositories —
their hosted deps and version pins already come from the extension, so the
networked solve (which downloads the package's whole transitive closure) is
skipped in favor of pubspec-parsed fallback metadata. Tool repositories
registered via pub.package tags keep True because they execute from their
vendored closure.""",
    ),
}

def _pub_dev_repository_impl(repository_ctx):
    """Implementation of pub_dev_repository rule."""
    package_name = repository_ctx.attr.package
    requested_version = repository_ctx.attr.version
    pub_dev_url = repository_ctx.attr.pub_dev_url

    if repository_ctx.attr.sha256 and repository_ctx.attr.integrity:
        fail("pub_dev_repository '{}': set at most one of sha256 and integrity.".format(package_name))

    # Determine the version to fetch. Only when no version is pinned does the
    # pub.dev metadata API need to be consulted (for the latest stable);
    # pinned versions go straight to the archive download.
    version = requested_version
    if not version or version.strip() == "":
        api_url = "{}/api/packages/{}".format(pub_dev_url, package_name)
        result = repository_ctx.download(
            url = api_url,
            output = "package_info.json",
        )
        if not result.success:
            fail("Failed to download package information for {}: {}".format(package_name, result))

        metadata = json.decode(repository_ctx.read("package_info.json"))
        version = metadata.get("latest", {}).get("version", "")
        repository_ctx.delete("package_info.json")
        if not version:
            fail("Could not determine latest version for {} from pub.dev metadata".format(package_name))

    # Construct the archive URL
    # pub.dev uses the format: https://pub.dev/packages/{package}/versions/{version}.tar.gz
    archive_url = "{}/packages/{}/versions/{}.tar.gz".format(pub_dev_url, package_name, version)

    # Download the package archive, verified against the pinned hash when one
    # was provided. Extraction prefers the system tar because some pub.dev
    # archives carry trailing bytes after the gzip stream (e.g. hashcodes
    # 2.0.0), which Bazel's strict extractor rejects; when no tar is on PATH
    # (hermetic containers), Bazel's own extractor is used instead.
    archive_name = "_pub_package.tar.gz"
    download_result = repository_ctx.download(
        url = archive_url,
        output = archive_name,
        sha256 = repository_ctx.attr.sha256,
        integrity = repository_ctx.attr.integrity,
    )
    if not repository_ctx.attr.sha256 and not repository_ctx.attr.integrity:
        # buildifier: disable=print
        print("rules_flutter: pub package {}@{} downloaded without a pinned hash; pin it with sha256 = \"{}\"".format(
            package_name,
            version,
            download_result.sha256,
        ))

    tar_bin = repository_ctx.which("tar")
    if tar_bin:
        extract_result = repository_ctx.execute([tar_bin, "-xzf", archive_name])
        if extract_result.return_code != 0 and not repository_ctx.path("pubspec.yaml").exists:
            fail("Failed to extract {} for package '{}' (code {}):\n{}".format(
                archive_url,
                package_name,
                extract_result.return_code,
                extract_result.stderr,
            ))
    else:
        repository_ctx.extract(archive_name)
    repository_ctx.delete(archive_name)

    generate_package_build(
        repository_ctx,
        package_name,
        sdk_repo = repository_ctx.attr.sdk_repo,
        hosted_deps = repository_ctx.attr.hosted_deps if repository_ctx.attr.hosted_deps_explicit else None,
        resolve_deps = repository_ctx.attr.resolve_deps,
    )

    # The vendored .pub_cache exists to serve the fetch-time `pub deps`
    # resolution above. Repositories registered through pub.package tags keep
    # it — tools like protoc_plugin execute from the repository with a runtime
    # package config resolved against this closure — but for ordinary
    # dependency repositories it is pure residue (~4GB across a large app's
    # dependency set), so drop it. The resolution's .dart_tool goes with it:
    # its package_config.json roots would dangle into the deleted closure.
    if not repository_ctx.attr.keep_vendored_cache:
        if repository_ctx.path(".pub_cache").exists:
            repository_ctx.delete(".pub_cache")
        if repository_ctx.path(".dart_tool").exists:
            repository_ctx.delete(".dart_tool")

    # Create a simple marker file for debugging
    repository_ctx.file(
        "PUB_PACKAGE_INFO",
        "Package: {}\nVersion: {}\nDownloaded from: {}\n".format(package_name, version, archive_url),
    )

pub_dev_repository = repository_rule(
    implementation = _pub_dev_repository_impl,
    attrs = _ATTRS,
    doc = _DOC,
    # The fetch is driven entirely by declared attrs and the toolchain SDK; no
    # host environment variable may influence the result.
    environ = [],
)
