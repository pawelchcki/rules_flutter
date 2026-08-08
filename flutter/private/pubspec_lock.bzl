"""Parser for `pubspec.lock`, pub's own checked-in resolution manifest.

`pubspec.lock` is the single source of truth for pub dependencies in this
ruleset: the module extension reads it to declare repositories, and the
generated build actions stage it into the prepared workspace verbatim.

pub writes the lock with fixed two-space indentation and a stable key order,
so a line-based scanner keyed on that indentation is both sufficient and — in
Starlark, which has neither regex nor `while` — the only option. The Dart
counterpart in `flutter/private/tools/pub_tool.dart` (`readLock`) is kept
structurally parallel to this file; change them together.

    packages:
      collection:
        dependency: transitive
        description:
          name: collection
          sha256: "a1ace0a..."
          url: "https://pub.dev"
        source: hosted
        version: "1.19.0"
      flutter:
        dependency: "direct main"
        description: flutter
        source: sdk
        version: "0.0.0"
    sdks:
      dart: ">=3.9.0-0 <4.0.0"
"""

def _unquote(value):
    """Strip surrounding whitespace and one matching pair of quotes."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ["\"", "'"]:
        return value[1:-1]
    return value

def _package_struct(name, entry):
    description = entry["description"]
    return struct(
        name = name,
        dependency = entry["dependency"],
        source = entry["source"],
        version = entry["version"],
        description = description,
        # `description: dart` — a bare scalar rather than a nested map. Hoisted
        # to its own field so callers never branch on the description's type.
        description_scalar = entry["description_scalar"],
        url = description.get("url", ""),
        sha256 = description.get("sha256", ""),
        path = description.get("path", ""),
    )

def parse_pubspec_lock(content, origin = "pubspec.lock"):
    """Parse a `pubspec.lock`'s package entries.

    Args:
      content: the file's text.
      origin: label or path used in error messages.

    Returns:
      A dict mapping package name to a struct with `name`, `dependency`,
      `source`, `version`, `description` (always a dict), `description_scalar`,
      and the `url` / `sha256` / `path` conveniences lifted out of the
      description.
    """
    packages = {}
    section = None
    current = None
    in_description = False
    saw_packages = False

    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))

        if indent == 0:
            key = stripped.partition(":")[0]
            section = key
            if key == "packages":
                saw_packages = True
            current = None
            in_description = False
            continue

        if section != "packages" or not stripped:
            continue

        if indent == 2:
            in_description = False
            if not stripped.endswith(":"):
                # `packages: {}` renders nothing at this depth; anything else
                # here is not a package header and is ignored deliberately.
                current = None
                continue
            current = stripped[:-1]
            packages[current] = {
                "dependency": "",
                "source": "",
                "version": "",
                "description": {},
                "description_scalar": "",
            }
            continue

        if current == None:
            continue

        if indent == 4:
            key, _, value = stripped.partition(":")
            value = _unquote(value)
            if key == "description":
                # Either `description:` opening a nested map, or the bare
                # scalar form used by sdk sources (`description: flutter`).
                in_description = value == ""
                packages[current]["description_scalar"] = value
            else:
                in_description = False
                if key in packages[current]:
                    packages[current][key] = value
            continue

        if indent >= 6 and in_description:
            key, _, value = stripped.partition(":")
            packages[current]["description"][key] = _unquote(value)

    if not saw_packages:
        fail("{}: not a pubspec.lock (no top-level `packages:` key)".format(origin))

    return {name: _package_struct(name, entry) for name, entry in packages.items()}

def parse_lock_sdk_constraints(content):
    """Parse the trailing `sdks:` block of a `pubspec.lock`.

    Args:
      content: the file's text.

    Returns:
      A dict of SDK name to version constraint, e.g. `{"dart": ">=3.9.0 <4.0.0"}`.
    """
    sdks = {}
    in_sdks = False
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            in_sdks = stripped.partition(":")[0] == "sdks"
            continue
        if in_sdks and indent == 2:
            key, _, value = stripped.partition(":")
            sdks[key] = _unquote(value)
    return sdks

def lock_hosted_packages(packages):
    """Filter parsed lock entries down to resolvable hosted packages.

    Args:
      packages: the dict returned by `parse_pubspec_lock`.

    Returns:
      A dict in the same shape, keeping only `source: hosted` entries that
      carry a version.
    """
    return {
        name: pkg
        for name, pkg in packages.items()
        if pkg.source == "hosted" and pkg.version
    }

def lock_direct_packages(packages):
    """Filter parsed lock entries down to the root package's direct deps.

    Args:
      packages: the dict returned by `parse_pubspec_lock`.

    Returns:
      A dict in the same shape, keeping entries whose `dependency` field starts
      with `direct` (`direct main`, `direct dev`, `direct overridden`).
    """
    return {
        name: pkg
        for name, pkg in packages.items()
        if pkg.dependency.startswith("direct")
    }
