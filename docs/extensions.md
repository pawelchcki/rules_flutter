<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Extensions for bzlmod.

Installs a flutter toolchain.
Every module can define a toolchain version under the default name, "flutter".
The latest of those versions will be selected (the rest discarded),
and will always be registered by ruleslab_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.

<a id="flutter"></a>

## flutter

<pre>
flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.android_toolchain(<a href="#flutter.android_toolchain-name">name</a>, <a href="#flutter.android_toolchain-build_tools_version">build_tools_version</a>, <a href="#flutter.android_toolchain-gradle_distribution_integrity">gradle_distribution_integrity</a>,
                          <a href="#flutter.android_toolchain-gradle_distribution_url">gradle_distribution_url</a>, <a href="#flutter.android_toolchain-ndk_version">ndk_version</a>, <a href="#flutter.android_toolchain-sdk_version">sdk_version</a>)
flutter.linux_toolchain(<a href="#flutter.linux_toolchain-name">name</a>)
flutter.toolchain(<a href="#flutter.toolchain-name">name</a>, <a href="#flutter.toolchain-flutter_version">flutter_version</a>, <a href="#flutter.toolchain-integrity">integrity</a>, <a href="#flutter.toolchain-precache">precache</a>, <a href="#flutter.toolchain-warm_first_run_stamps">warm_first_run_stamps</a>)
</pre>


**TAG CLASSES**

<a id="flutter.android_toolchain"></a>

### android_toolchain

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="flutter.android_toolchain-name"></a>name |  Base name for generated Android repositories.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | optional |  `"android"`  |
| <a id="flutter.android_toolchain-build_tools_version"></a>build_tools_version |  -   | String | required |  |
| <a id="flutter.android_toolchain-gradle_distribution_integrity"></a>gradle_distribution_integrity |  -   | String | required |  |
| <a id="flutter.android_toolchain-gradle_distribution_url"></a>gradle_distribution_url |  -   | String | required |  |
| <a id="flutter.android_toolchain-ndk_version"></a>ndk_version |  -   | String | optional |  `""`  |
| <a id="flutter.android_toolchain-sdk_version"></a>sdk_version |  -   | String | required |  |

<a id="flutter.linux_toolchain"></a>

### linux_toolchain

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="flutter.linux_toolchain-name"></a>name |  Base name for generated hermetic Linux package and toolchain repositories. The pinned Ubuntu Jammy closure supports Linux x86_64 and arm64 execution platforms and includes Clang, CMake, Ninja, pkg-config, GTK 3 development files, binutils, and the C/C++ runtime. Declare this tag in the root module, import <name>_toolchains with use_repo, and register @<name>_toolchains//:all.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | optional |  `"linux"`  |

<a id="flutter.toolchain"></a>

### toolchain

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="flutter.toolchain-name"></a>name |  Base name for generated repositories, allowing more than one flutter toolchain to be registered. Overriding the default is only permitted in the root module.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | optional |  `"flutter"`  |
| <a id="flutter.toolchain-flutter_version"></a>flutter_version |  Explicit version of flutter.   | String | required |  |
| <a id="flutter.toolchain-integrity"></a>integrity |  Escape hatch for Flutter versions not in the built-in version table: a map from platform (macos, macos_arm64, linux, linux_arm64, windows) to the SRI integrity of that platform's stable release archive, e.g. {"macos": "sha256-...", "linux": "sha256-..."}. linux_arm64 has no archive of its own — it re-architects the linux one and so takes the linux entry, while macos_arm64 is a real separate download and needs its own. Only the platforms you actually build on need an entry (the per-platform SDK repositories are fetched lazily). When flutter_version is in the built-in table this may be omitted. Merged across registrations of the same name.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="flutter.toolchain-precache"></a>precache |  Artifact groups (web, android, ios, macos, linux, windows) that must be present in the SDK cache after fetch. Stable archives already ship these; when one is missing, `flutter precache` runs at repository fetch time. Unioned across registrations of the same toolchain name.   | List of strings | optional |  `[]`  |
| <a id="flutter.toolchain-warm_first_run_stamps"></a>warm_first_run_stamps |  Run one `flutter precache` at fetch time so the tool's first-run artifact stamps exist before the SDK cache is sealed (~70s of fetch work). Required by anything that runs `flutter test`, `analyze` or `build`; pure-Dart consumers can set this False to skip it. False only takes effect when every registration of this toolchain name asks for it.   | Boolean | optional |  `True`  |


<a id="pub"></a>

## pub

<pre>
pub = use_extension("@rules_flutter//flutter:extensions.bzl", "pub")
pub.lock(<a href="#pub.lock-name">name</a>, <a href="#pub.lock-file">file</a>)
pub.no_locks()
pub.package(<a href="#pub.package-name">name</a>, <a href="#pub.package-package">package</a>, <a href="#pub.package-sha256">sha256</a>, <a href="#pub.package-version">version</a>)
</pre>


**TAG CLASSES**

<a id="pub.lock"></a>

### lock

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="pub.lock-name"></a>name |  Name of the hub repository generated for this lock. Depend on `@<name>//:all` to get the lock's entire package closure, or on `@<name>//:<package>` for one package of it.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="pub.lock-file"></a>file |  Label of the `pubspec.lock` whose packages become repositories.<br><br>The label is read, never analyzed, so it needs no BUILD file of its own: a lock in a directory that is not a Bazel package is spelled relative to the nearest enclosing package, e.g. `//:sub_dir/pubspec.lock`.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |

<a id="pub.no_locks"></a>

### no_locks

Explicit acknowledgement that this module declares no `pubspec.lock`.

The pub extension refuses to silently do nothing, so a module with no locks
says so rather than omitting every tag.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |

<a id="pub.package"></a>

### package

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="pub.package-name"></a>name |  Repository name for the package   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="pub.package-package"></a>package |  Package name on pub.dev   | String | required |  |
| <a id="pub.package-sha256"></a>sha256 |  Expected SHA-256 of the package archive (optional; pins the download)   | String | optional |  `""`  |
| <a id="pub.package-version"></a>version |  Package version (optional, defaults to latest)   | String | optional |  `""`  |


