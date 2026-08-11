"""Flutter command execution actions for Bazel rules."""

def shell_quote(arg):
    """Quote a string for safe interpolation into a bash script."""
    return "'" + arg.replace("'", "'\"'\"'") + "'"

def _sdk_files(flutter_toolchain, capability):
    """Return a capability closure, falling back for legacy custom toolchains."""
    return flutter_toolchain.flutterinfo.sdk_groups.get(
        capability,
        flutter_toolchain.flutterinfo.sdk_files,
    )

# Portable (macOS-safe, no flock) mkdir-locked helpers for the opt-in
# build_runner incremental-state cache. Inserted verbatim into the
# preparation script as pre-resolved bash (NOT .format()ed), so their
# $()/${} are literal; <<LABEL>> is the only substitution (shell-quoted).
#
# Safety: every step is best-effort. A missing hash tool, an unwritable
# cache dir, a lost lock, or a failed copy all degrade to a cold build_runner
# run — they never fail the action, and a failed copy removes its partial
# destination so a torn tree is never trusted.
_BUILD_RUNNER_CACHE_HELPERS = """
_br_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        return 1
    fi
}
_br_cache_key() {
    { printf '%s\\0' <<LABEL>>; cat "$FLUTTER_ROOT/version" 2>/dev/null || true; cat "$WORKSPACE_DIR_ABS/pubspec.lock"; } | _br_hash
}
_br_lock_acquire() {
    # $1 = lock dir. Returns 0 if acquired, 1 after a bounded wait; a miss
    # just means this build runs without the shared cache. Steals a lock left
    # by a crashed build (older than 10 minutes) so it never deadlocks.
    local i
    for i in $(seq 1 60); do
        if mkdir "$1" 2>/dev/null; then
            return 0
        fi
        if [ -n "$(find "$1" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
            rmdir "$1" 2>/dev/null || true
        fi
        sleep 1
    done
    return 1
}
_br_copy() {
    # $1 src dir, $2 dest dir. On any failure, removes the (possibly partial)
    # destination and returns non-zero so the caller starts cold.
    if command -v rsync >/dev/null 2>&1; then
        if rsync -a --delete "$1/" "$2/"; then return 0; fi
    else
        rm -rf "$2" && mkdir -p "$2" && cp -RL "$1/." "$2/" && return 0
    fi
    rm -rf "$2" 2>/dev/null || true
    return 1
}
_br_cache_ready() {
    # $1 = cache root. Returns 0 if it exists and is writable.
    mkdir -p "$1" 2>/dev/null || return 1
    if { : > "$1/.rules_flutter_wtest" && rm -f "$1/.rules_flutter_wtest"; } 2>/dev/null; then
        return 0
    fi
    return 1
}
"""

_BUILD_RUNNER_CACHE_RESTORE = """
if [ -n "${RULES_FLUTTER_BUILD_RUNNER_CACHE:-}" ]; then
""" + _BUILD_RUNNER_CACHE_HELPERS + """
    BR_CACHE_ROOT="$RULES_FLUTTER_BUILD_RUNNER_CACHE"
    if ! _br_cache_ready "$BR_CACHE_ROOT"; then
        echo "⚠ build_runner cache $BR_CACHE_ROOT is not writable (did you pass --sandbox_writable_path?); building cold" >&2
    else
        BR_KEY="$(_br_cache_key)" || BR_KEY=""
        if [ -n "$BR_KEY" ]; then
            BR_CACHE_DIR="$BR_CACHE_ROOT/$BR_KEY"
            BR_LOCK="$BR_CACHE_ROOT/$BR_KEY.lock"
            if _br_lock_acquire "$BR_LOCK"; then
                if [ -d "$BR_CACHE_DIR/build" ]; then
                    echo "Restoring build_runner cache from $BR_CACHE_DIR"
                    mkdir -p "$WORKSPACE_DIR_ABS/.dart_tool"
                    _br_copy "$BR_CACHE_DIR/build" "$WORKSPACE_DIR_ABS/.dart_tool/build" || true
                fi
                rmdir "$BR_LOCK" 2>/dev/null || true
            fi
        fi
    fi
fi
"""

_BUILD_RUNNER_CACHE_SAVE = """
if [ -n "${RULES_FLUTTER_BUILD_RUNNER_CACHE:-}" ] && [ -d "$WORKSPACE_DIR_ABS/.dart_tool/build" ]; then
    BR_CACHE_ROOT="$RULES_FLUTTER_BUILD_RUNNER_CACHE"
    if _br_cache_ready "$BR_CACHE_ROOT"; then
        BR_KEY="$(_br_cache_key)" || BR_KEY=""
        if [ -n "$BR_KEY" ]; then
            BR_CACHE_DIR="$BR_CACHE_ROOT/$BR_KEY"
            BR_LOCK="$BR_CACHE_ROOT/$BR_KEY.lock"
            if _br_lock_acquire "$BR_LOCK"; then
                echo "Saving build_runner cache to $BR_CACHE_DIR"
                mkdir -p "$BR_CACHE_DIR"
                _br_copy "$WORKSPACE_DIR_ABS/.dart_tool/build" "$BR_CACHE_DIR/build" || true
                rmdir "$BR_LOCK" 2>/dev/null || true
            fi
        fi
    fi
fi
"""

# Shared staging helpers, injected as a format *value* (so braces here are
# single). _stage_tree copies a staged input tree into a mutable destination.
# With fast staging ($3 = 1) it first tries an APFS clone (macOS `cp -c`,
# copy-on-write and therefore safe for in-place rewrites) and then a hardlink
# farm (GNU `cp -l -L`): directories are private and writable, files share
# inodes with the read-only inputs. Files a later step rewrites *in place*
# must be re-materialized with _unshare_file first — an in-place truncation
# of a hardlinked file would reach back into the action's inputs. New files
# and delete-then-recreate writes are safe with writable directories alone
# (_make_dirs_writable). With fast staging off ($3 = 0) this is byte-for-byte
# the historical rsync/cp copy.
STAGE_TREE_HELPERS = """
_reset_dest() {
    # $1 dest dir. Makes any existing tree writable (a previous _stage_tree
    # may have left read-only directories behind), removes it and recreates
    # it empty. Only ever called on destinations we own.
    if [ -d "$1" ]; then
        find "$1" -type d ! -perm -700 -exec chmod u+rwx {} + 2>/dev/null || true
    fi
    rm -rf "$1"
    mkdir -p "$1"
}
_stage_tree() {
    # $1 src dir, $2 dest dir (created), $3 fast staging (1/0).
    # Exclusive-destination contract: this function owns $2 and may wipe it
    # on retry. Use _merge_tree to overlay into a shared destination.
    mkdir -p "$2"
    if [ "$3" = "1" ]; then
        if cp -cRL "$1/." "$2/" 2>/dev/null; then
            return 0
        fi
        _reset_dest "$2"
        if cp -RLl "$1/." "$2/" 2>/dev/null; then
            return 0
        fi
        _reset_dest "$2"
    fi
    if command -v rsync >/dev/null 2>&1; then
        rsync -aL "$1/" "$2/"
    else
        cp -RL "$1/." "$2/"
    fi
}
_merge_tree() {
    # $1 src dir, $2 dest dir, $3 link-dest (1/0). Additive overlay: layers
    # $1 on top of whatever is already in $2 without ever removing it, so it
    # is safe for destinations built up from several read-only sources.
    # Symlinks are always dereferenced ($1 may be a staged input tree whose
    # links point outside the destination).
    mkdir -p "$2"
    if command -v rsync >/dev/null 2>&1; then
        if [ "$3" = "1" ]; then
            rsync -aL --chmod=Du+w --link-dest="$1" "$1/" "$2/" && return 0
        fi
        rsync -aL --chmod=Du+w "$1/" "$2/"
    else
        _make_dirs_writable "$2"
        cp -RLf "$1/." "$2/"
    fi
}
_unshare_file() {
    # Re-materialize $1 as a private, writable copy (breaks a hardlink).
    if [ -f "$1" ]; then
        cp -L "$1" "$1.rules_flutter_unshare" && mv -f "$1.rules_flutter_unshare" "$1"
        chmod u+rw "$1"
    fi
}
_make_dirs_writable() {
    # Directories in a staged tree are always private (hardlinks never share
    # them), so this cannot touch action inputs.
    find "$1" -type d ! -perm -700 -exec chmod u+rwx {} + 2>/dev/null || true
}
"""

def create_flutter_working_dir(ctx, pubspec_file, dart_files, other_files, data_files, extra_entries = [], allow_remote_exec = False, remote_cache_trees = False):
    """Create a working directory structure for Flutter commands.

    Args:
        ctx: The rule context
        pubspec_file: The pubspec.yaml file
        dart_files: List of .dart source files
        other_files: List of other source files declared in srcs
        data_files: List of additional data files that must be available in the workspace
        extra_entries: List of (rel_path, file) tuples mounted at explicit
            workspace-relative paths (e.g. generated proto sources). These take
            precedence over the derived layout for the same file.
        allow_remote_exec: Whether //flutter:allow_remote_execution is set.
        remote_cache_trees: Whether //flutter:remote_cache_trees is set; when
            False the ~100MB seed tree carries no-remote-cache.

    Returns:
        Tuple of (working_dir, input_files)
    """
    working_dir = ctx.actions.declare_directory(ctx.label.name + "_workspace_seed")

    # Build a manifest of files that should be available inside the workspace with
    # paths relative to the package root so code generation tools see the expected
    # project layout (e.g. lib/, test/, l10n/, web/).
    package = ctx.label.package
    package_prefix = package + "/" if package else ""
    workspace_name = ctx.workspace_name

    def source_relative_path(file):
        candidates = []
        for path in [file.short_path, file.path]:
            stripped = path
            if stripped.startswith("external/"):
                parts = stripped.split("/", 2)
                if len(parts) == 3:
                    stripped = parts[2]
            elif stripped.startswith("../"):
                parts = stripped.split("/", 2)
                if len(parts) == 3:
                    stripped = parts[2]
            if workspace_name:
                for repo_prefix in [
                    "external/{}/".format(workspace_name),
                    "../{}/".format(workspace_name),
                    "{}/".format(workspace_name),
                ]:
                    if stripped.startswith(repo_prefix):
                        stripped = stripped[len(repo_prefix):]
                        break
            candidates.append(stripped)

        for candidate in candidates:
            if package_prefix and candidate.startswith(package_prefix):
                return candidate[len(package_prefix):]
            if not package_prefix and not candidate.startswith("../") and not candidate.startswith("external/") and not candidate.startswith("bazel-out/"):
                return candidate

        return file.basename

    workspace_entries = {}
    seen = {}

    def add_entry(file, rel_path = None):
        if file == None:
            return
        if file.path in seen:
            return
        seen[file.path] = True

        if rel_path == None:
            rel_path = source_relative_path(file)

        workspace_entries[rel_path] = file

    add_entry(pubspec_file, "pubspec.yaml")

    for f in dart_files + other_files + data_files:
        add_entry(f)

    manifest = ctx.actions.declare_file(ctx.label.name + "_workspace_manifest.txt")
    manifest_content = []
    for rel_path in sorted(workspace_entries.keys()):
        file = workspace_entries[rel_path]
        manifest_content.append("{}|{}".format(rel_path, file.path))

    # Explicit mounts go last so they take precedence, and several directory
    # artifacts may merge into the same destination (the setup script merges
    # directory sources instead of replacing them).
    for rel_path, f in extra_entries:
        if f.path in seen:
            continue
        seen[f.path] = True
        manifest_content.append("{}|{}".format(rel_path, f.path))

    manifest_payload = "\n".join(manifest_content)
    if manifest_payload:
        manifest_payload += "\n"

    ctx.actions.write(
        output = manifest,
        content = manifest_payload,
    )

    workspace_script = ctx.actions.declare_file(ctx.label.name + "_setup_workspace.sh")
    ctx.actions.write(
        output = workspace_script,
        content = """#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="$1"
MANIFEST_FILE="$2"

rm -rf "$WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR"

while IFS='|' read -r RELATIVE_PATH SOURCE_PATH; do
    if [ -z "$RELATIVE_PATH" ]; then
        continue
    fi
    DEST_PATH="$WORKSPACE_DIR/$RELATIVE_PATH"
    if [ -d "$SOURCE_PATH" ]; then
        # Merge directory sources so several tree artifacts can share a
        # destination (e.g. per-proto_library outputs under lib/generated).
        # Overlapping trees ship the same transitive files, and earlier
        # copies land read-only from bazel inputs: later passes must be able
        # to write into those directories and replace the files (-f).
        mkdir -p "$DEST_PATH"
        find "$DEST_PATH" -type d ! -perm -200 -exec chmod u+w {} + 2>/dev/null || true
        cp -RLf "$SOURCE_PATH/." "$DEST_PATH/"
    else
        mkdir -p "$(dirname "$DEST_PATH")"
        cp -RLf "$SOURCE_PATH" "$DEST_PATH"
    fi
done < "$MANIFEST_FILE"
""",
        is_executable = True,
    )

    # Collect unique input files for the action
    input_files = []
    seen_inputs = {}
    for f in [pubspec_file] + [entry[1] for entry in extra_entries] + dart_files + other_files + data_files:
        if f == None:
            continue
        if f.path in seen_inputs:
            continue
        seen_inputs[f.path] = True
        input_files.append(f)

    # Run the workspace setup
    ctx.actions.run(
        inputs = input_files + [manifest],
        outputs = [working_dir],
        executable = workspace_script,
        arguments = [working_dir.path, manifest.path],
        mnemonic = "SetupFlutterWorkspace",
        progress_message = "Setting up Flutter workspace for %s" % ctx.label.name,
        execution_requirements = tree_output_execution_requirements(allow_remote_exec, remote_cache_trees),
    )

    return working_dir, input_files

def flutter_assemble_pub_cache_action(
        ctx,
        dependency_pub_caches = [],
        allow_remote_exec = False,
        remote_cache_trees = False):
    """Merge transitive dependency pub caches into a single assembled cache tree.

    This is the offline pub cache the library exposes. It is a pure function of
    the dependency cache trees — it takes no workspace sources and no Flutter
    SDK — so editing a Dart source file does not invalidate it, and the
    (multi-GB) merge of hundreds of overlapping dependency trees runs once and
    then hits the cache. flutter_pub_get_action consumes the result read-only.

    Args:
        ctx: The rule context.
        dependency_pub_caches: Files or depsets with pub cache directories from
            dependencies.
        allow_remote_exec: Whether //flutter:allow_remote_execution is set;
            when False the action carries no-remote-exec.
        remote_cache_trees: Whether //flutter:remote_cache_trees is set; when
            False the multi-GB assembled tree carries no-remote-cache (local
            disk cache stays eligible).

    Returns:
        The assembled pub cache tree artifact.
    """
    dep_pub_cache_files = []
    for item in dependency_pub_caches:
        if type(item) == "depset":
            dep_pub_cache_files.extend(item.to_list())
        else:
            dep_pub_cache_files.append(item)

    assembled_cache = ctx.actions.declare_directory(ctx.label.name + "_pub_cache")

    # The dependency cache paths arrive as action *arguments* rather than
    # interpolated into the command string. The previous version pasted them
    # into a shell array literal with hand-rolled quoting, which a path
    # containing a space or a quote would have broken; args.add_all cannot be
    # mis-quoted, and it keeps the command string independent of the
    # dependency list (so it no longer rekeys the action).
    args = ctx.actions.args()
    args.add(assembled_cache.path)
    args.add_all(dep_pub_cache_files, expand_directories = False)

    script_content = """#!/bin/bash
set -euo pipefail

ORIGINAL_PWD="$PWD"
{stage_tree_helpers}
PUB_CACHE_DIR_ABS="$ORIGINAL_PWD/$1"
shift
_reset_dest "$PUB_CACHE_DIR_ABS"

echo "=== Assembling pub cache from dependencies ==="
if [ "$#" -gt 0 ]; then
    for DEP_CACHE in "$@"; do
        if [[ "$DEP_CACHE" != /* ]]; then
            DEP_CACHE="$ORIGINAL_PWD/$DEP_CACHE"
        fi
        if [ -d "$DEP_CACHE" ] && [ -n "$(ls -A "$DEP_CACHE" 2>/dev/null)" ]; then
            # link_dest=1: hardlink the read-only dependency files instead of
            # copying bytes. The assembled cache is consumed read-only
            # downstream (flutter_pub_get_action points PUB_CACHE at it
            # read-only), so sharing inodes with the dependency inputs is safe,
            # and it turns a per-file copy of thousands of tiny pub files into
            # near-instant links. This is the only _merge_tree caller that
            # links.
            _merge_tree "$DEP_CACHE" "$PUB_CACHE_DIR_ABS" 1
        fi
    done
else
    echo "No dependency caches supplied"
fi

if [ -z "$(ls -A "$PUB_CACHE_DIR_ABS" 2>/dev/null)" ]; then
    echo '{{}}' > "$PUB_CACHE_DIR_ABS/.empty_cache.json"
fi
echo "=== Pub cache assembly complete ==="
""".format(
        stage_tree_helpers = STAGE_TREE_HELPERS,
    )

    ctx.actions.run_shell(
        inputs = dep_pub_cache_files,
        outputs = [assembled_cache],
        arguments = [args],
        command = script_content,
        mnemonic = "FlutterAssemblePubCache",
        progress_message = "Assembling pub cache for %s" % ctx.label.name,
        execution_requirements = tree_output_execution_requirements(allow_remote_exec, remote_cache_trees),
        resource_set = heavy_action_resource_set,
    )

    return assembled_cache

def flutter_stage_path_package_action(
        ctx,
        workspace,
        pubspec,
        allow_remote_exec = False,
        remote_cache_trees = False,
        fast_staging = False):
    """Stage a local flutter_library's workspace as a pub-cache `path/` entry.

    A pubspec `path:` dependency points outside the depending package's
    directory, so it cannot be staged inside that package's prepared workspace
    tree. Instead the depended-on library republishes its own workspace in
    pub-cache shape at `path/<package name>/`, which rides the existing
    transitive_pub_caches depset into every consumer's assembled cache. The
    package_config generator resolves `source == "path"` entries there.

    Args:
        ctx: The rule context (of the depended-on library).
        workspace: That library's prepared workspace tree artifact.
        pubspec: That library's pubspec.yaml, read for the package name.
        allow_remote_exec: Whether //flutter:allow_remote_execution is set.
        remote_cache_trees: Whether //flutter:remote_cache_trees is set.
        fast_staging: Whether //flutter:fast_staging is set.

    Returns:
        A pub-cache-shaped tree artifact containing `path/<name>/`.
    """
    staged = ctx.actions.declare_directory(ctx.label.name + "_path_pub_cache")

    script_content = """#!/bin/bash
set -euo pipefail

STAGED="{staged}"
WORKSPACE="{workspace}"
PUBSPEC="{pubspec}"

# The package name is the pubspec's first top-level `name:`. awk is POSIX;
# this action has no Flutter SDK input, so it must not need an interpreter.
NAME="$(awk -F: '/^name:[[:space:]]*/ {{ v = $2; gsub(/^[[:space:]]*["'"'"']?|["'"'"']?[[:space:]]*$/, "", v); print v; exit }}' "$PUBSPEC")"
if [ -z "$NAME" ]; then
    echo "✗ could not read package name from $PUBSPEC" >&2
    exit 1
fi

{stage_tree_helpers}
rm -rf "$STAGED"
mkdir -p "$STAGED/path"
# This tree is consumed read-only (merged into assembled pub caches), so
# sharing inodes with the workspace input is always safe here.
_stage_tree "$WORKSPACE" "$STAGED/path/$NAME" "{fast_staging}"
""".format(
        staged = staged.path,
        workspace = workspace.path,
        pubspec = pubspec.path,
        stage_tree_helpers = STAGE_TREE_HELPERS,
        fast_staging = "1" if fast_staging else "0",
    )

    ctx.actions.run_shell(
        inputs = [workspace, pubspec],
        outputs = [staged],
        command = script_content,
        mnemonic = "FlutterStagePathPackage",
        progress_message = "Staging path package %s" % ctx.label.name,
        execution_requirements = tree_output_execution_requirements(allow_remote_exec, remote_cache_trees),
    )

    return staged

def flutter_stage_pub_package_action(ctx, payload_files, allow_remote_exec = False):
    """Stage a hosted pub package's own payload into a single pub cache tree.

    Hosted pub-package targets neither run codegen nor merge dependency caches;
    their only job is to make their own files available at
    `hosted/pub.dev/<name>-<version>/` in the offline cache. This one cheap
    action does exactly that — no Flutter SDK, no workspace seed, no prepared
    workspace, no dart_tool — collapsing the three near-identical per-package
    trees of the full prepare path down to one.

    Args:
        ctx: The rule context.
        payload_files: The package's own files (the `_package_payload`
            filegroup: sources + pubspec, minus BUILD/metadata files).
        allow_remote_exec: Whether //flutter:allow_remote_execution is set.

    Returns:
        The staged pub cache tree artifact.
    """

    # Anchor the repo root on the top-level pubspec.yaml so the staged layout
    # is independent of the external-repo exec path (avoids hardcoding the
    # bzlmod canonical repo-name mangling).
    root_prefix = None
    pubspec_path = None
    for f in payload_files:
        p = f.path
        if p == "pubspec.yaml" or p.endswith("/pubspec.yaml"):
            candidate = p[:-len("pubspec.yaml")]
            if root_prefix == None or len(candidate) < len(root_prefix):
                root_prefix = candidate
                pubspec_path = p
    if root_prefix == None:
        fail("flutter_stage_pub_package_action: no pubspec.yaml in payload for {}".format(ctx.label))

    staged = ctx.actions.declare_directory(ctx.label.name + "_pub_cache")
    manifest = ctx.actions.declare_file(ctx.label.name + "_pub_payload_manifest.txt")
    ctx.actions.write(
        manifest,
        "".join([f.path + "\t" + f.path[len(root_prefix):] + "\n" for f in payload_files]),
    )

    script_content = """#!/bin/bash
set -euo pipefail

STAGED="{staged}"
MANIFEST="{manifest}"
PUBSPEC="{pubspec_path}"

# Top-level name:/version:, read with POSIX awk — this action has no Flutter
# SDK input, so it must not need an interpreter.
read_key() {{
    awk -v key="$1" -F: '$0 ~ "^" key ":" {{ v = $2; gsub(/^[[:space:]]*["'"'"']?|["'"'"']?[[:space:]]*$/, "", v); print v; exit }} /^environment:/ {{ exit }}' "$PUBSPEC"
}}
NAME="$(read_key name)"
VERSION="$(read_key version)"
if [ -z "$NAME" ] || [ -z "$VERSION" ]; then
    echo "✗ FATAL ERROR: could not read name/version from $PUBSPEC" >&2
    exit 1
fi

DEST="$STAGED/hosted/pub.dev/${{NAME}}-${{VERSION}}"
rm -rf "$STAGED"
mkdir -p "$DEST"
while IFS=$'\t' read -r SRC REL; do
    [ -z "$SRC" ] && continue
    REL_DIR="$(dirname "$REL")"
    if [ "$REL_DIR" != "." ]; then
        mkdir -p "$DEST/$REL_DIR"
    fi
    cp -L "$SRC" "$DEST/$REL"
done < "$MANIFEST"
""".format(
        staged = staged.path,
        manifest = manifest.path,
        pubspec_path = pubspec_path,
    )

    ctx.actions.run_shell(
        inputs = payload_files + [manifest],
        outputs = [staged],
        command = script_content,
        mnemonic = "FlutterStagePubPackage",
        progress_message = "Staging pub package %s" % ctx.label.name,
        execution_requirements = heavy_action_execution_requirements(allow_remote_exec),
    )

    return staged

def flutter_pub_get_action(
        ctx,
        flutter_toolchain,
        working_dir,
        pubspec_file,
        lock_file,
        dependency_pub_caches = [],
        generator_commands = [],
        build_runner_common_args = [],
        build_runner_build_args = [],
        run_build_runner_build = False,
        is_pub_package = False,
        allow_remote_exec = False,
        remote_cache_trees = False,
        preassembled_cache = None,
        build_runner_cache = "",
        fast_staging = False,
        pub_tool_file = None):
    """Prepare Flutter/Dart dependencies from declared pubspec.lock metadata.

    Args:
        ctx: The rule context.
        flutter_toolchain: The resolved Flutter toolchain.
        working_dir: Directory containing the staged package sources.
        pubspec_file: The pubspec.yaml file for the library.
        lock_file: Checked-in or repository-generated pubspec.lock.
        dependency_pub_caches: Files or depsets with pub cache directories from dependencies.
        generator_commands: Optional list of one-shot code generation commands
            (package:script).
        build_runner_common_args: Optional list of CLI args shared by all
            build_runner modes.
        build_runner_build_args: Optional list of CLI args passed to
            `build_runner build`.
        run_build_runner_build: Whether to run `dart run build_runner build`
            in this action.
        is_pub_package: Whether the target represents a hosted pub.dev package.
        allow_remote_exec: Whether //flutter:allow_remote_execution is set;
            when False the action carries no-remote-exec.
        remote_cache_trees: Whether //flutter:remote_cache_trees is set; when
            False the prepared workspace / dart_tool trees carry
            no-remote-cache (local disk cache stays eligible).
        preassembled_cache: An assembled pub cache tree (from
            flutter_assemble_pub_cache_action) to use read-only instead of
            merging dependency_pub_caches here. When set, this action produces
            no pub_cache tree of its own and returns the preassembled one — so
            a Dart edit re-runs codegen without re-merging the dependency
            caches. Mutually exclusive with a non-empty dependency_pub_caches
            and with is_pub_package (which republishes into its own cache).
        fast_staging: Whether //flutter:fast_staging is set; staged-tree copies
            use clones/hardlinks instead of byte copies (see STAGE_TREE_HELPERS).
        build_runner_cache: Absolute directory (from //flutter:build_runner_cache)
            for persisting build_runner's incremental .dart_tool/build state
            across builds. Empty (default) keeps the action fully hermetic and
            byte-identical; when set, the action inherits the client shell
            environment and restores/saves the cache under a lock.
        pub_tool_file: Optional declared pub_tool executable used by the
            generated dependency-preparation action.

    Returns:
        Tuple of (prepared_workspace, pub_get_output, pub_cache_dir, lock, dart_tool_dir).
    """

    # Only meaningful when this action actually runs build_runner.
    use_build_runner_cache = bool(build_runner_cache) and run_build_runner_build

    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin_file = flutter_toolchain.flutterinfo.tool_files[0]
    flutter_bin = flutter_bin_file.path

    dep_pub_cache_files = []
    for item in dependency_pub_caches:
        if type(item) == "depset":
            dep_pub_cache_files.extend(item.to_list())
        else:
            dep_pub_cache_files.append(item)

    if preassembled_cache != None and (dep_pub_cache_files or is_pub_package):
        fail("flutter_pub_get_action: preassembled_cache is mutually exclusive " +
             "with dependency_pub_caches and is_pub_package.")

    pub_get_output = ctx.actions.declare_file(ctx.label.name + "_pub_prepare.log")
    if preassembled_cache != None:
        pub_cache_dir = preassembled_cache
    else:
        pub_cache_dir = ctx.actions.declare_directory(ctx.label.name + "_pub_cache")
    lock = ctx.actions.declare_file(ctx.label.name + "_pubspec.lock")
    dart_tool_dir = ctx.actions.declare_directory(ctx.label.name + "_dart_tool")
    prepared_workspace = ctx.actions.declare_directory(ctx.label.name + "_prepared_flutter_workspace")

    dep_pub_cache_args = []
    for dep_cache in dep_pub_cache_files:
        dep_pub_cache_args.append(dep_cache.path)

    generator_args = [shell_quote(cmd) for cmd in generator_commands]
    build_runner_common_args_quoted = [shell_quote(arg) for arg in build_runner_common_args]
    build_runner_build_args_quoted = [shell_quote(arg) for arg in build_runner_build_args]

    # Opt-in build_runner incremental-state cache (//flutter:build_runner_cache).
    # Restores/saves .dart_tool/build under a portable mkdir-lock, keyed by
    # target + Flutter version + lock digest. Copies are best-effort (a
    # miss or torn cache just forces a full rebuild), so no lock leaks on
    # failure and correctness never depends on the cache. Values are plain
    # bash (sentinel-substituted, not .format()ed) so their $()/${} survive.
    build_runner_cache_restore = ""
    build_runner_cache_save = ""
    if use_build_runner_cache:
        build_runner_cache_restore = _BUILD_RUNNER_CACHE_RESTORE.replace("<<LABEL>>", shell_quote(str(ctx.label)))
        build_runner_cache_save = _BUILD_RUNNER_CACHE_SAVE

    # PUB_CACHE handling differs by mode. With a preassembled cache the merge
    # (and its dependency-cache inputs) has already happened in a separate
    # action; PUB_CACHE points at it read-only and this action produces no
    # cache tree. Otherwise the dependency caches (and any package-local
    # .pub_cache) are merged into this action's own pub_cache output.
    if preassembled_cache != None:
        pub_cache_assembly = """echo "=== Using preassembled pub cache (read-only) ==="
export PUB_CACHE="$PUB_CACHE_DIR_ABS\""""
        pub_cache_finalize = ""
    else:
        pub_cache_assembly = """export PUB_CACHE="$PUB_CACHE_DIR_ABS"
mkdir -p "$PUB_CACHE_DIR_ABS"

echo "=== Preparing pub cache from dependencies ==="
DEP_CACHES=({dep_caches})
if [ ${{#DEP_CACHES[@]}} -gt 0 ]; then
    for DEP_CACHE in "${{DEP_CACHES[@]}}"; do
        if [[ "$DEP_CACHE" != /* ]]; then
            DEP_CACHE="$ORIGINAL_PWD/$DEP_CACHE"
        fi
        if [ -d "$DEP_CACHE" ] && [ -n "$(ls -A "$DEP_CACHE" 2>/dev/null)" ]; then
            # The caches overlap (shared transitive packages). Unlike the
            # separate assemble action, `pub get` runs against this cache in the
            # same action, so link_dest is deliberately 0: files must be
            # byte-copied to stay independent of the read-only dependency
            # inputs.
            _merge_tree "$DEP_CACHE" "$PUB_CACHE_DIR_ABS" 0
        fi
    done
else
    echo "No dependency caches supplied"
fi

if [ -d "$WORKSPACE_DIR_ABS/.pub_cache" ]; then
    # Also deliberately unlinked: `pub get` writes into this cache below.
    echo "Merging package-local .pub_cache"
    _merge_tree "$WORKSPACE_DIR_ABS/.pub_cache" "$PUB_CACHE_DIR_ABS" 0
fi""".format(
            dep_caches = " ".join(['"{}"'.format(path) for path in dep_pub_cache_args]),
        )
        pub_cache_finalize = """mkdir -p "{pub_cache_dir}"
if [ -n "$(ls -A "$PUB_CACHE_DIR_ABS" 2>/dev/null)" ]; then
    echo "✓ Populated pub_cache directory" >> "$LOG_FILE"
else
    echo '{{}}' > "{pub_cache_dir}/.empty_cache.json"
    echo "⚠ Dependency cache was empty" >> "$LOG_FILE"
fi
""".format(pub_cache_dir = pub_cache_dir.path)

    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_SRC="{workspace_src}"
WORKSPACE_DIR="{workspace_dir}"
PUB_CACHE_DIR="{pub_cache_dir}"
LOCK_INPUT="{lock_input}"
DART_TOOL_DIR="{dart_tool_dir}"
FLUTTER_BIN="{flutter_bin}"
IS_PUB_PACKAGE="{is_pub_package}"
ORIGINAL_PWD="$PWD"

WORKSPACE_SRC_ABS="$ORIGINAL_PWD/$WORKSPACE_SRC"
WORKSPACE_DIR_ABS="$ORIGINAL_PWD/$WORKSPACE_DIR"
PUB_CACHE_DIR_ABS="$ORIGINAL_PWD/$PUB_CACHE_DIR"
DART_TOOL_DIR_ABS="$ORIGINAL_PWD/$DART_TOOL_DIR"
if [[ "$LOCK_INPUT" == /* ]]; then
    LOCK_INPUT_ABS="$LOCK_INPUT"
else
    LOCK_INPUT_ABS="$ORIGINAL_PWD/$LOCK_INPUT"
fi

# Copy staged workspace into prepared output directory
{stage_tree_helpers}
FAST_STAGING="{fast_staging}"
rm -rf "$WORKSPACE_DIR_ABS"
_stage_tree "$WORKSPACE_SRC_ABS" "$WORKSPACE_DIR_ABS" "$FAST_STAGING"
if [ "$FAST_STAGING" = "1" ]; then
    # Only the files rewritten in place below need private copies; everything
    # the tool writes later is either a new file or delete-then-recreate.
    _make_dirs_writable "$WORKSPACE_DIR_ABS"
    _unshare_file "$WORKSPACE_DIR_ABS/pubspec.yaml"
    _unshare_file "$WORKSPACE_DIR_ABS/pubspec.lock"
else
    chmod -R u+rwX "$WORKSPACE_DIR_ABS"
fi

# The SDK's own dart runs the action helper (//flutter/private:pub_tool);
# nothing here depends on a host interpreter.
FLUTTER_BIN_ABS="$ORIGINAL_PWD/$FLUTTER_BIN"
if [ ! -x "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not found at $FLUTTER_BIN_ABS" >&2
    exit 1
fi
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN_ABS")/.." && pwd -P)"
export FLUTTER_ROOT
DART_BIN_LOCAL="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
if [ ! -x "$DART_BIN_LOCAL" ]; then
    echo "✗ FATAL ERROR: Dart binary not found at $DART_BIN_LOCAL" >&2
    exit 1
fi
PUB_TOOL="$ORIGINAL_PWD/{pub_tool}"
pub_tool() {{
    "$DART_BIN_LOCAL" "$PUB_TOOL" "$@"
}}

if [ -f "$WORKSPACE_DIR_ABS/pubspec.yaml" ]; then
    # Published pub packages get their dev_dependencies/dependency_overrides
    # stripped (irrelevant to consumers, sometimes unresolvable). The root
    # package KEEPS its dependency_overrides: offline re-resolution (used to
    # regenerate flutter's plugin tooling for mobile builds) must honor them.
    PUBSPEC_SECTIONS=""
    if [ "$IS_PUB_PACKAGE" = "1" ]; then
        PUBSPEC_SECTIONS="dependency_overrides dev_dependencies"
    fi
    PUBSPEC_PATH="$WORKSPACE_DIR_ABS/pubspec.yaml" PUBSPEC_SECTIONS="$PUBSPEC_SECTIONS" pub_tool strip-pubspec
fi

{pub_cache_assembly}
echo ""

export PUBSPEC_PATH="$WORKSPACE_DIR_ABS/pubspec.yaml"
PACKAGE_INFO="$(pub_tool pubspec-info)"

PACKAGE_NAME="${{PACKAGE_INFO%%|*}}"
PACKAGE_VERSION="${{PACKAGE_INFO#*|}}"
PACKAGE_VERSION="${{PACKAGE_VERSION%%|*}}"
LANGUAGE_SPEC="${{PACKAGE_INFO##*|}}"
if [ -z "$LANGUAGE_SPEC" ]; then
    LANGUAGE_SPEC=">=3.0.0 <4.0.0"
fi

if [ "$IS_PUB_PACKAGE" = "1" ] && [ -n "$PACKAGE_NAME" ] && [ -n "$PACKAGE_VERSION" ]; then
    DEST="$PUB_CACHE_DIR_ABS/hosted/pub.dev/${{PACKAGE_NAME}}-${{PACKAGE_VERSION}}"
    rm -rf "$DEST"
    _stage_tree "$WORKSPACE_DIR_ABS" "$DEST" "$FAST_STAGING"
fi

export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel"
export ANDROID_HOME=""
export ANDROID_SDK_ROOT=""
# FLUTTER_BIN_ABS / FLUTTER_ROOT / DART_BIN_LOCAL were resolved at the top of
# the script, before the first pub_tool call.
export PATH="$FLUTTER_ROOT/bin:$PATH"

cd "$WORKSPACE_DIR_ABS"

echo "=== Using declared pubspec.lock ==="
if [ ! -s "$LOCK_INPUT_ABS" ]; then
    echo "✗ FATAL ERROR: pubspec.lock input is missing or empty: $LOCK_INPUT_ABS" >&2
    echo "Run the generated .update target or provide a checked-in pubspec.lock." >&2
    exit 1
fi
# rm first: the staged workspace may already carry a (possibly hardlinked)
# pubspec.lock, and overwriting it in place would truncate a shared inode.
rm -f pubspec.lock
cp "$LOCK_INPUT_ABS" pubspec.lock
chmod u+rw pubspec.lock

export PUBSPEC_LOCK_PATH="$WORKSPACE_DIR_ABS/pubspec.lock"

# Only a library that assembles the full dependency closure can be held to it.
# Generated pub-package and SDK-package targets resolve out of FLUTTER_ROOT or
# stage only their own payload, so their cache is partial by design.
export REQUIRE_COMPLETE_PUB_CACHE="{require_complete_cache}"

export PUB_CACHE_ABS="$PUB_CACHE_DIR_ABS"
export WORKSPACE_ABS="$WORKSPACE_DIR_ABS"
export PACKAGE_CONFIG_PATH="$WORKSPACE_DIR_ABS/.dart_tool/package_config.json"
export ROOT_PACKAGE_NAME="$PACKAGE_NAME"
export ROOT_LANGUAGE_SPEC="$LANGUAGE_SPEC"
mkdir -p "$(dirname "$PACKAGE_CONFIG_PATH")"
pub_tool package-config

GENERATOR_COMMANDS=({generator_commands})
if [ ${{#GENERATOR_COMMANDS[@]}} -gt 0 ]; then
    for CODEGEN_CMD in "${{GENERATOR_COMMANDS[@]}}"; do
        if [ -n "$CODEGEN_CMD" ]; then
            echo "Running code generation: $CODEGEN_CMD"
            CODEGEN_ENTRYPOINT="$(
                CODEGEN_CMD="$CODEGEN_CMD" PACKAGE_CONFIG_PATH="$PACKAGE_CONFIG_PATH" pub_tool resolve-entrypoint
            )"
            if ! "$DART_BIN_LOCAL" --packages="$PACKAGE_CONFIG_PATH" "$CODEGEN_ENTRYPOINT"; then
                echo "✗ FATAL ERROR: Generator command '$CODEGEN_CMD' failed" >&2
                exit 1
            fi
        fi
    done
    rm -f .dart_tool/version 2>/dev/null || true
    rm -f .dart_tool/package_config_subset 2>/dev/null || true
fi

BUILD_RUNNER_COMMON_ARGS=({build_runner_common_args})
BUILD_RUNNER_BUILD_ARGS=({build_runner_build_args})
if [ "{run_build_runner_build}" = "1" ]; then
    if ! pub_tool has-package "$WORKSPACE_ABS/pubspec.lock" build_runner
    then
        echo "✗ FATAL ERROR: build_runner requested but not present in pubspec.lock" >&2
        exit 1
    fi

    # Resolve build_runner's entrypoint from package_config.json and invoke it
    # with an explicit --packages flag. `dart run` would first check that the
    # package resolution is up to date and attempt an implicit (networked)
    # `pub get`, which must never happen inside a build action.
    BUILD_RUNNER_ENTRYPOINT="$(
        CODEGEN_CMD="build_runner:build_runner" PACKAGE_CONFIG_PATH="$PACKAGE_CONFIG_PATH" pub_tool resolve-entrypoint
    )"
    if [ -z "$BUILD_RUNNER_ENTRYPOINT" ]; then
        echo "✗ FATAL ERROR: unable to resolve build_runner entrypoint from package_config.json" >&2
        exit 1
    fi

    CMD=("$DART_BIN_LOCAL" "--packages=$PACKAGE_CONFIG_PATH" "$BUILD_RUNNER_ENTRYPOINT" "build")
    if [ ${{#BUILD_RUNNER_COMMON_ARGS[@]}} -gt 0 ]; then
        CMD+=("${{BUILD_RUNNER_COMMON_ARGS[@]}}")
    fi
    if [ ${{#BUILD_RUNNER_BUILD_ARGS[@]}} -gt 0 ]; then
        CMD+=("${{BUILD_RUNNER_BUILD_ARGS[@]}}")
    fi
    DELETE_CONFLICTING_PRESENT=0
    for ARG in "${{CMD[@]}}"; do
        if [ "$ARG" = "--delete-conflicting-outputs" ]; then
            DELETE_CONFLICTING_PRESENT=1
        fi
    done
    if [ "$DELETE_CONFLICTING_PRESENT" = "0" ]; then
        CMD+=("--delete-conflicting-outputs")
    fi
{build_runner_cache_restore}
    echo "Running build_runner build: ${{CMD[*]}}"
    if ! "${{CMD[@]}}"; then
        echo "✗ FATAL ERROR: build_runner build failed" >&2
        exit 1
    fi
{build_runner_cache_save}
fi

# build_runner's incremental state includes absolute scratch paths and timing-
# dependent bookkeeping. The optional persistent cache has already been saved;
# generated sources and package metadata live outside these two directories.
rm -rf "$WORKSPACE_DIR_ABS/.dart_tool/build" \
       "$WORKSPACE_DIR_ABS/.dart_tool/build_resolvers"

echo ""
echo "=== Dependency preparation complete ==="
""".format(
        workspace_src = working_dir.path,
        workspace_dir = prepared_workspace.path,
        pub_cache_dir = pub_cache_dir.path,
        pub_cache_assembly = pub_cache_assembly,
        stage_tree_helpers = STAGE_TREE_HELPERS,
        fast_staging = "1" if fast_staging else "0",
        lock = lock.path,
        lock_input = lock_file.path,
        require_complete_cache = "1" if ctx.attr.assemble_dep_caches and not ctx.attr.pub_package else "",
        dart_tool_dir = dart_tool_dir.path,
        flutter_bin = flutter_bin,
        generator_commands = " ".join(generator_args),
        build_runner_common_args = " ".join(build_runner_common_args_quoted),
        build_runner_build_args = " ".join(build_runner_build_args_quoted),
        run_build_runner_build = "1" if run_build_runner_build else "0",
        is_pub_package = "1" if is_pub_package else "0",
        pub_tool = pub_tool_file.path,
        build_runner_cache_restore = build_runner_cache_restore,
        build_runner_cache_save = build_runner_cache_save,
    )

    prepare_direct_inputs = [working_dir, pubspec_file, lock_file, pub_tool_file] + dep_pub_cache_files + flutter_toolchain.flutterinfo.tool_files
    prepare_outputs = [pub_get_output, lock, dart_tool_dir, prepared_workspace]
    if preassembled_cache != None:
        # Consumed read-only; produced by flutter_assemble_pub_cache_action.
        prepare_direct_inputs.append(preassembled_cache)
    else:
        prepare_outputs = prepare_outputs + [pub_cache_dir]
    prepare_inputs = depset(
        direct = prepare_direct_inputs,
        transitive = [_sdk_files(flutter_toolchain, "framework")],
    )

    ctx.actions.run_shell(
        inputs = prepare_inputs,
        outputs = prepare_outputs,
        command = script_content + """

cd "$ORIGINAL_PWD"

mkdir -p "$(dirname "{pub_get_output}")"
mkdir -p "$(dirname "{lock}")"
mkdir -p "{dart_tool_dir}"

LOG_FILE="{pub_get_output}"
echo "=== Flutter Dependency Preparation ===" > "$LOG_FILE"
echo "Flutter binary: {flutter_bin}" >> "$LOG_FILE"
echo "Workspace output: {workspace_dir}" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

if [ -f "$WORKSPACE_DIR_ABS/pubspec.lock" ]; then
    cp "$WORKSPACE_DIR_ABS/pubspec.lock" "{lock}"
    echo "✓ Copied declared pubspec.lock" >> "$LOG_FILE"
else
    echo "✗ pubspec.lock missing after preparation" >> "$LOG_FILE"
    exit 1
fi

_reset_dest "{dart_tool_dir}"
if [ -d "$WORKSPACE_DIR_ABS/.dart_tool" ]; then
    # Never fast-stage: this is a declared output tree, so it must own its
    # inodes and must not contain symlinks (absolute links into the
    # torn-down sandbox would be dangling on a remote-cache hit).
    _stage_tree "$WORKSPACE_DIR_ABS/.dart_tool" "{dart_tool_dir}" 0
    echo "✓ Created .dart_tool/package_config.json" >> "$LOG_FILE"
else
    echo "{{}}" > "{dart_tool_dir}/package_config.json"
    echo "⚠ .dart_tool missing, wrote minimal package_config.json" >> "$LOG_FILE"
fi

{pub_cache_finalize}
echo "Status: Prepared dependencies from declared metadata" >> "$LOG_FILE"
""".format(
            pub_get_output = pub_get_output.path,
            lock = lock.path,
            pub_cache_finalize = pub_cache_finalize,
            dart_tool_dir = dart_tool_dir.path,
            flutter_bin = flutter_bin,
            workspace_dir = prepared_workspace.path,
        ),
        mnemonic = "FlutterPrepareDeps",
        progress_message = "Preparing Flutter dependencies for %s" % ctx.label.name,
        execution_requirements = tree_output_execution_requirements(
            allow_remote_exec,
            remote_cache_trees,
            host_bound = use_build_runner_cache,
        ),
        resource_set = heavy_action_resource_set,
        # The cache opt-in needs the persistent directory reachable from the
        # action. It is an out-of-sandbox path (the consumer also passes
        # --sandbox_writable_path), so the action inherits the client shell
        # env and receives the path explicitly. Off (default) leaves the
        # action's env untouched and byte-identical.
        use_default_shell_env = use_build_runner_cache,
        env = {"RULES_FLUTTER_BUILD_RUNNER_CACHE": build_runner_cache} if use_build_runner_cache else None,
    )

    return prepared_workspace, pub_get_output, pub_cache_dir, lock, dart_tool_dir

ANDROID_TARGETS = ["apk", "appbundle"]

def heavy_action_execution_requirements(allow_remote_exec):
    """Execution requirements for the CPU-heavy hermetic flutter actions.

    Returns no restriction when allow_remote_exec is true (the default), or a
    local-execution restriction when a consumer explicitly opts out.
    """
    if allow_remote_exec:
        return None
    return {"no-remote-exec": "1"}

def _android_offline_gradle_env(android):
    """Return shell setup for the mandatory offline Gradle build."""
    return """
mkdir -p "$GRADLE_USER_HOME/init.d"
cp "$ORIGINAL_PWD/{init_script}" "$GRADLE_USER_HOME/init.d/rules_flutter.init.gradle.kts"
export RULES_FLUTTER_MAVEN_MIRROR="$ORIGINAL_PWD/{maven_repo}"
RULES_FLUTTER_GRADLE="$ORIGINAL_PWD/{gradle_home}/bin/gradle"
RULES_FLUTTER_WRAPPER_PROPERTIES="android/gradle/wrapper/gradle-wrapper.properties"
if [ -f "$RULES_FLUTTER_WRAPPER_PROPERTIES" ] && ! grep -q 'gradle-{gradle_version}-\\(bin\\|all\\)\\.zip' "$RULES_FLUTTER_WRAPPER_PROPERTIES"; then
    echo "✗ FATAL ERROR: Gradle wrapper does not match declared Gradle {gradle_version}." >&2
    exit 1
fi
printf '#!/bin/sh\nexec "%s" "$@"\n' "$RULES_FLUTTER_GRADLE" > android/gradlew
chmod +x android/gradlew
printf '@echo off\r\n"%s" %%*\r\n' "$RULES_FLUTTER_GRADLE" > android/gradlew.bat
""".format(
        init_script = android.init_script_path,
        maven_repo = android.maven_repo_path,
        gradle_home = android.gradle_home,
        gradle_version = android.gradle_version,
    )

def host_bound_action_execution_requirements(extra = {}, dependencies_declared = False):
    """Execution requirements for actions whose result depends on host state.

    The android and ios builds shell out to the host Gradle/Xcode toolchains
    through unsandboxed symlink trees and fetch their own dependencies over
    the network. None of that is an action input, so the action key does not
    describe the result: two machines with different Xcode versions, different
    Gradle user homes, or a different view of Maven Central produce different
    outputs under the *same* key. Uploading those to a cache shared with other
    machines serves one host's build to another, which is why these carry
    no-remote-cache on top of the usual no-remote-exec.

    Two independent things are wrong here, and only one of them is fixable
    today:

    * The action fetches its own dependencies. Declaring the Maven closure and
      the Gradle distribution as inputs and resolving offline fixes this, and
      `dependencies_declared` drops requires-network when it holds.
    * The action reads a host toolchain that is not an input at all. The
      Android SDK arrives as a *path* resolved through rules_android's symlink
      wrapper to a host installation; Xcode is simply assumed. Nothing about
      vendoring Maven changes that, so no-sandbox and no-remote-cache stay
      regardless — lifting them needs a declared, symlink-free SDK.

    no-remote-exec is unconditional: these actions are host-bound by
    construction, so neither //flutter:allow_remote_execution nor
    //flutter:remote_cache_trees lifts it.

    Args:
        extra: Additional requirements to merge in (e.g. requires-darwin).
        dependencies_declared: Whether everything the action would otherwise
            fetch is a declared input and it has been told to resolve offline.

    Returns:
        An execution_requirements dict.
    """
    reqs = {
        "no-remote-cache": "1",
        "no-remote-exec": "1",
        "no-sandbox": "1",
    }
    if not dependencies_declared:
        reqs["requires-network"] = "1"
    reqs.update(extra)
    return reqs

def tree_output_execution_requirements(allow_remote_exec, remote_cache_trees, host_bound = False):
    """Execution requirements for actions producing large tree artifacts.

    The assembled pub cache (multi-GB) and the prepared/overlay workspace
    trees (~100MB each) change with every source edit; uploading them via
    --remote_upload_local_results has been observed draining a CI invocation
    for hundreds of seconds after the last real action finished. The default
    posture therefore adds no-remote-cache — Bazel still caches these actions
    in the local disk cache, and rebuilding them locally is cheap — alongside
    the usual no-remote-exec. //flutter:remote_cache_trees opts the trees back
    into the remote cache (e.g. on an RBE fleet where executors share it), and
    //flutter:allow_remote_execution lifts the execution restriction.

    Args:
        allow_remote_exec: Whether //flutter:allow_remote_execution is set;
            when False the action carries no-remote-exec.
        remote_cache_trees: Whether //flutter:remote_cache_trees is set; when
            False (and execution is local) the action carries no-remote-cache.
            Ignored under allow_remote_exec: remotely executed actions must
            store their outputs in the remote CAS, so suppressing the cache
            there would only force constant re-execution.
        host_bound: Whether this instance of the action reads host state that
            is not among its inputs — currently only the
            //flutter:build_runner_cache opt-in, which hands the action an
            absolute directory outside the sandbox and lets it inherit the
            client shell env. That makes the result unshareable no matter what
            the two flags above say, so it forces both restrictions on.

    Returns:
        An execution_requirements dict, or None when nothing is restricted.
    """
    if host_bound:
        return {"no-remote-cache": "1", "no-remote-exec": "1"}
    reqs = {}
    if not allow_remote_exec:
        reqs["no-remote-exec"] = "1"
        if not remote_cache_trees:
            reqs["no-remote-cache"] = "1"
    return reqs or None

def heavy_action_resource_set(os, inputs_size):
    """Resource estimate so the local scheduler doesn't oversubscribe.

    The prepare/codegen and flutter build actions run multi-process Dart
    tooling; the Bazel default of one CPU per action badly oversubscribes a
    machine running several of them. Memory scales with the input count (a
    proxy for how much workspace/pub-cache tree the action copies and how
    large the Dart compile is), clamped so small targets don't reserve 4GB
    and huge ones don't starve.
    """

    # buildifier: disable=unused-variable
    _ignore = os
    return {"cpu": 4, "memory": max(2048, min(8192, inputs_size // 2))}

def flutter_build_action(
        ctx,
        flutter_toolchain,
        working_dir,
        target,
        pub_cache_dir,
        dart_tool_dir,
        mode = "release",
        dart_defines = {},
        build_args = [],
        env = {},
        android = None,
        android_test = False,
        allow_remote_exec = False,
        fast_staging = False,
        pub_tool_file = None,
        web_normalizer_file = None):
    """Execute flutter build command for the specified target.

    Args:
        ctx: The rule context
        flutter_toolchain: The Flutter toolchain
        working_dir: Flutter project working directory
        target: Build target (web, apk, appbundle, ios, etc.)
        pub_cache_dir: Assembled pub cache directory used for offline resolution
        dart_tool_dir: Prepared .dart_tool directory containing package_config metadata
        mode: Flutter build mode (release, profile, or debug)
        dart_defines: Dict of compile-time --dart-define key/value pairs
        build_args: Extra args appended verbatim to the flutter build command
        env: Extra environment variables exported before invoking flutter
        android: Hermetic SDK/optional NDK/Gradle/Maven/JDK environment for
            apk/appbundle targets. Every component is a declared action input.
        android_test: For apk targets, additionally run Gradle's
            app:assembleAndroidTest after the Flutter build and copy the
            instrumentation APK into androidTest/ under the build artifacts
            (the Firebase Test Lab instrumentation flow)
        allow_remote_exec: Whether //flutter:allow_remote_execution is set;
            when False, web/desktop builds carry no-remote-exec (remote
            caching stays enabled; Android/iOS have stricter requirements)
        fast_staging: Whether //flutter:fast_staging is set; staged-tree copies
            use clones/hardlinks instead of byte copies (see STAGE_TREE_HELPERS)
        pub_tool_file: Optional declared pub_tool executable used by the
            generated Flutter build action.
        web_normalizer_file: Private Dart helper used only by web build actions
            to replace Flutter's random service-worker cache-busting value.

    Returns:
        Tuple of (build_output, build_artifacts_dir)
    """

    # Get the actual Flutter binary file object (first tool file)
    if not flutter_toolchain.flutterinfo.tool_files:
        fail("No tool files found in Flutter toolchain")
    flutter_bin_file = flutter_toolchain.flutterinfo.tool_files[0]
    flutter_bin = flutter_bin_file.path

    # Create output files
    build_output = ctx.actions.declare_file(ctx.label.name + "_build.log")
    build_artifacts = ctx.actions.declare_directory(ctx.label.name + "_build_artifacts")

    # Map targets to Flutter build args and output paths. {mode}/{Mode} are
    # substituted with the requested build mode.
    target_configs = {
        "web": {
            "args": ["build", "web", "--no-pub"],
            "output_dir": "build/web",
        },
        "apk": {
            "args": ["build", "apk", "--no-pub"],
            "output_dir": "build/app/outputs/flutter-apk",
        },
        "appbundle": {
            "args": ["build", "appbundle", "--no-pub"],
            "output_dir": "build/app/outputs/bundle/{mode}",
        },
        "ios": {
            "args": ["build", "ios", "--no-codesign", "--no-pub"],
            "output_dir": "build/ios/iphoneos",
        },
        "macos": {
            "args": ["build", "macos", "--no-pub"],
            "output_dir": "build/macos/Build/Products/{Mode}",
        },
        "linux": {
            "args": ["build", "linux", "--no-pub"],
            "output_dir": "build/linux/x64/{mode}/bundle",
        },
        "windows": {
            "args": ["build", "windows", "--no-pub"],
            "output_dir": "build/windows/x64/runner/{Mode}",
        },
    }

    config = target_configs.get(target, target_configs["web"])

    if android_test and target != "apk":
        fail("flutter_app '{}': android_test is only supported on apk targets (got '{}').".format(ctx.label, target))

    command_args = list(config["args"])
    command_args.append("--" + mode)
    for key in sorted(dart_defines.keys()):
        command_args.append("--dart-define={}={}".format(key, dart_defines[key]))
    command_args.extend(build_args)
    build_command = " ".join([shell_quote(arg) for arg in command_args])

    output_dir = config["output_dir"].replace("{mode}", mode).replace("{Mode}", mode.capitalize())

    env_exports = "\n".join([
        "export {}={}".format(key, shell_quote(env[key]))
        for key in sorted(env.keys())
    ])

    web_normalize_step = ""
    if target == "web":
        if web_normalizer_file == None:
            fail("flutter_build_action: web target requires web_normalizer_file")
        web_normalize_step = """
    echo "Normalizing Flutter web output..."
    WEB_NORMALIZER_ABS="$ORIGINAL_PWD/{web_normalizer}"
    if ! "$DART_BIN_LOCAL" "$WEB_NORMALIZER_ABS" "$BUILD_OUTPUT_DIR" "$PWD/web"; then
        echo "✗ FATAL ERROR: deterministic web normalization failed" >&2
        exit 1
    fi
""".format(web_normalizer = web_normalizer_file.path)

    # flutter's plugin tooling (.flutter-plugins-dependencies and the platform
    # plugin registrants) is only regenerated by `pub get`; `flutter build
    # --no-pub` assumes it already exists. Mobile targets therefore run an
    # offline pub get against the prepared cache (dependency_overrides are
    # preserved in the root pubspec so the offline solve reproduces the pins).
    mobile_pub_get = ""
    if target in ANDROID_TARGETS or target == "ios":
        mobile_pub_get = """
# pub writes bookkeeping (active_roots) into PUB_CACHE, so give it a mutable
# copy of the assembled cache before regenerating plugin tooling.
RW_PUB_CACHE="$BUILD_WORKSPACE_TMP/.pub_cache_rw"
_stage_tree "$PUB_CACHE_DIR_ABS" "$RW_PUB_CACHE" "$FAST_STAGING"
if [ "$FAST_STAGING" = "1" ]; then
    # pub only *adds* bookkeeping files (active_roots); writable directories
    # suffice, and chmod'ing hardlinked files would reach the inputs.
    _make_dirs_writable "$RW_PUB_CACHE"
else
    chmod -R u+w "$RW_PUB_CACHE"
fi
export PUB_CACHE="$RW_PUB_CACHE"
export PUB_CACHE_DIR_ABS="$RW_PUB_CACHE"
export PUB_CACHE_ABS="$RW_PUB_CACHE"

# Path dependencies are staged in cache/path/<package>. Point the mutable
# build pubspec at those declared inputs so pub's offline plugin-tooling pass
# does not try to traverse the original source-relative path outside this
# package's prepared workspace.
"$DART_BIN_LOCAL" "$PUB_TOOL_ABS" rewrite-path-deps

echo "Running flutter pub get --offline to regenerate plugin tooling..."
if ! "$FLUTTER_BIN_ABS" --suppress-analytics --no-version-check pub get --offline; then
    echo "✗ FATAL ERROR: flutter pub get --offline failed" >&2
    exit 1
fi
"""

    ios_env = ""
    if target == "ios":
        # Host Xcode and CocoaPods are declared prerequisites (standard Bazel
        # practice for Apple builds); flutter drives `pod install` itself.
        ios_env = """
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "✗ FATAL ERROR: xcodebuild not found; iOS builds require a host Xcode installation." >&2
    exit 1
fi
# --incompatible_strict_action_env gives actions a minimal PATH; probe the
# common CocoaPods install locations before giving up.
if ! command -v pod >/dev/null 2>&1; then
    for CANDIDATE in /opt/homebrew/bin /usr/local/bin "${HOME:-/var/empty}/.gem/bin" /usr/local/lib/ruby/gems/*/bin; do
        if [ -x "$CANDIDATE/pod" ]; then
            export PATH="$CANDIDATE:$PATH"
            break
        fi
    done
fi
if ! command -v pod >/dev/null 2>&1; then
    echo "✗ FATAL ERROR: CocoaPods (pod) not found on PATH; install the version pinned in Podfile.lock." >&2
    exit 1
fi
export LANG="${LANG:-en_US.UTF-8}"
if [ -n "${RULES_FLUTTER_CP_HOME:-}" ]; then
    export CP_HOME_DIR="$RULES_FLUTTER_CP_HOME"
    mkdir -p "$CP_HOME_DIR"
fi
"""

    android_test_step = ""
    if android_test:
        # Runs in the mutable workspace after a successful flutter build, so
        # local.properties, the Gradle env, and plugin tooling already exist.
        android_test_step = """
    echo "Building androidTest instrumentation APK..."
    chmod +x android/gradlew 2>/dev/null || true
    if ! (cd android && ./gradlew app:assembleAndroidTest); then
        echo "✗ FATAL ERROR: gradlew app:assembleAndroidTest failed" >&2
        exit 1
    fi
    if [ ! -d build/app/outputs/apk/androidTest ]; then
        echo "✗ FATAL ERROR: androidTest outputs not found at build/app/outputs/apk/androidTest" >&2
        exit 1
    fi
    mkdir -p "$BUILD_ARTIFACTS_ABS/androidTest"
    cp -r build/app/outputs/apk/androidTest/. "$BUILD_ARTIFACTS_ABS/androidTest/"
    echo "✓ androidTest instrumentation APK copied"
"""

    # (see _android_offline_gradle_env above for the offline Gradle setup)

    # iOS keeps the caller's HOME (when the build passes it through, e.g.
    # --action_env=HOME) so CocoaPods spec/pod caches persist across builds;
    # under --incompatible_strict_action_env HOME is absent, so fall back to a
    # scratch dir rather than aborting. Everything else always gets a scratch
    # HOME to keep config/analytics writes out of shared state.
    # The scratch HOME goes under $TMPDIR (which Bazel points into the
    # execroot) rather than a bare `mktemp -d` rooted at /tmp, matching every
    # other scratch directory in this ruleset: outside the execroot it escapes
    # the sandbox and survives the action.
    scratch_home = 'export HOME="$(mktemp -d "${TMPDIR:-/tmp}/rules_flutter_home.XXXXXX")"'
    if target == "ios":
        home_export = 'export HOME="${HOME:-}"\nif [ -z "$HOME" ]; then\n    ' + scratch_home + "\nfi"
    else:
        home_export = scratch_home

    android_gradle_env = ""
    if target in ANDROID_TARGETS:
        if android == None:
            fail("flutter_app '{}' target '{}' requires an Android toolchain.".format(ctx.label, target))
        java_home_export = (
            "export JAVA_HOME=\"{}\"".format(android.java_home) if android.java_home.startswith("/") else "export JAVA_HOME=\"$ORIGINAL_PWD/{}\"".format(android.java_home)
        )
        android_env_exports = "\n".join([
            "export ANDROID_HOME=\"$ORIGINAL_PWD/{}\"".format(android.sdk_path),
            "export ANDROID_SDK_ROOT=\"$ANDROID_HOME\"",
            java_home_export,
        ])

        android_gradle_env = 'export GRADLE_USER_HOME="$BUILD_WORKSPACE_TMP/.gradle_home"' + """
mkdir -p "$GRADLE_USER_HOME"
export GRADLE_OPTS="-Dorg.gradle.daemon=false ${{GRADLE_OPTS:-}}"
# flutter build upgrades Android project files in place. Fast staging
# hardlinks ordinary workspace files to read-only inputs, so detach this small
# mutable subtree before Flutter touches it.
if [ "$FAST_STAGING" = "1" ] && [ -d android ]; then
    cp -R android .rules_flutter_android_mutable
    chmod -R u+rwX .rules_flutter_android_mutable
    rm -rf android
    mv .rules_flutter_android_mutable android
fi

# Some Flutter plugins leave buildToolsVersion unset and still request the
# historical 34.0.0 default. Expose that compatibility name through a
# writable overlay while keeping every SDK byte backed by the declared,
# checksummed toolchain input.
SDK_INPUT="$ANDROID_HOME"
SDK_OVERLAY="$BUILD_WORKSPACE_TMP/.android_sdk"
mkdir -p "$SDK_OVERLAY/build-tools"
for SDK_ENTRY in "$SDK_INPUT"/*; do
    if [ "$(basename "$SDK_ENTRY")" != "build-tools" ]; then
        ln -s "$SDK_ENTRY" "$SDK_OVERLAY/$(basename "$SDK_ENTRY")"
    fi
done
for BUILD_TOOLS_ENTRY in "$SDK_INPUT/build-tools"/*; do
    ln -s "$BUILD_TOOLS_ENTRY" "$SDK_OVERLAY/build-tools/$(basename "$BUILD_TOOLS_ENTRY")"
done
if [ ! -e "$SDK_OVERLAY/build-tools/34.0.0" ]; then
    ln -s "$SDK_INPUT/build-tools/{build_tools_version}" "$SDK_OVERLAY/build-tools/34.0.0"
fi
export ANDROID_HOME="$SDK_OVERLAY"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
mkdir -p android
printf 'sdk.dir=%s\\nflutter.sdk=%s\\n' "$ANDROID_HOME" "$FLUTTER_ROOT" > android/local.properties
""".format(build_tools_version = android.build_tools_version)

        # Keep aapt2 and lint out of the real ~/.android: it holds a per-machine
        # debug keystore and an analytics/AVD cache, none of it an input.
        android_gradle_env += """
export ANDROID_USER_HOME="$GRADLE_USER_HOME/.android"
mkdir -p "$ANDROID_USER_HOME"
"""

        if android.ndk_path:
            android_gradle_env += 'export ANDROID_NDK_ROOT="$ORIGINAL_PWD/{}"\n'.format(android.ndk_path)

        android_gradle_env += _android_offline_gradle_env(android)
    else:
        android_env_exports = "export ANDROID_HOME=\"\"\nexport ANDROID_SDK_ROOT=\"\""

    script_content = """#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="{workspace_dir}"
PUB_CACHE_DIR="{pub_cache_dir}"
DART_TOOL_DIR="{dart_tool_dir}"
FLUTTER_BIN="{flutter_bin}"
OUTPUT_LOG="{output_log}"
BUILD_ARTIFACTS="{build_artifacts}"
BUILD_OUTPUT_DIR="{build_output_dir}"
ORIGINAL_PWD="$PWD"

# Convert relative paths to absolute before changing directories
OUTPUT_LOG_ABS="$ORIGINAL_PWD/$OUTPUT_LOG"
BUILD_ARTIFACTS_ABS="$ORIGINAL_PWD/$BUILD_ARTIFACTS"
DART_TOOL_DIR_ABS="$ORIGINAL_PWD/$DART_TOOL_DIR"
PUB_CACHE_DIR_ABS="$ORIGINAL_PWD/$PUB_CACHE_DIR"

mkdir -p "$(dirname "$OUTPUT_LOG_ABS")"
: > "$OUTPUT_LOG_ABS"

# Set up environment
export PUB_CACHE="$PUB_CACHE_DIR_ABS"

# Set absolute path to Flutter binary from execroot
FLUTTER_BIN_ABS="$ORIGINAL_PWD/$FLUTTER_BIN"

# Validate Flutter binary exists and is executable
if [ ! -f "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not found at: $FLUTTER_BIN_ABS"
    echo "Expected Flutter SDK to be available via toolchain"
    exit 1
fi

if [ ! -x "$FLUTTER_BIN_ABS" ]; then
    echo "✗ FATAL ERROR: Flutter binary not executable at: $FLUTTER_BIN_ABS"
    echo "Check Flutter SDK permissions and installation"
    exit 1
fi

echo "Flutter binary verified at: $FLUTTER_BIN_ABS"

FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN_ABS")/.." && pwd -P)"

# Configure Flutter for sandbox environment. The SDK repository is sealed
# read-only at fetch time; FLUTTER_ALREADY_LOCKED skips the bin/cache lockfile
# and the scratch HOME keeps config/analytics writes out of the repository.
export FLUTTER_SUPPRESS_ANALYTICS=true
export FLUTTER_ALREADY_LOCKED=true
export CI=true
export PUB_ENVIRONMENT="flutter_tool:bazel"
{home_export}
{android_env_exports}
export FLUTTER_ROOT
export PATH="$FLUTTER_ROOT/bin:$PATH"
{env_exports}

# Copy the prepared workspace input into a mutable directory for Flutter. Bazel
# may present input tree artifacts as read-only in the sandbox.
SOURCE_WORKSPACE_ABS="$ORIGINAL_PWD/$WORKSPACE_DIR"
BUILD_TMP_PARENT="$ORIGINAL_PWD/$(dirname "$BUILD_ARTIFACTS")"
mkdir -p "$BUILD_TMP_PARENT"
BUILD_WORKSPACE_TMP="$(mktemp -d "$BUILD_TMP_PARENT/rules_flutter_build.XXXXXX")"
# bash 3.2 (macOS /bin/bash) runs the EXIT trap with $?=0 after a `set -u`
# expansion error, which would let a failed build report success to Bazel.
# The sentinel forces any abort before the final line to exit nonzero.
SCRIPT_COMPLETED=0
cleanup() {{
    rc=$?
    rm -rf "$BUILD_WORKSPACE_TMP" || true
    if [ "$SCRIPT_COMPLETED" != 1 ] && [ "$rc" = 0 ]; then
        rc=1
    fi
    exit "$rc"
}}
trap cleanup EXIT

{stage_tree_helpers}
FAST_STAGING="{fast_staging}"
_stage_tree "$SOURCE_WORKSPACE_ABS" "$BUILD_WORKSPACE_TMP" "$FAST_STAGING"
if [ "$FAST_STAGING" = "1" ]; then
    _make_dirs_writable "$BUILD_WORKSPACE_TMP"
    _unshare_file "$BUILD_WORKSPACE_TMP/pubspec.yaml"
    _unshare_file "$BUILD_WORKSPACE_TMP/pubspec.lock"
else
    chmod -R u+rwX "$BUILD_WORKSPACE_TMP"
fi

# Change to the mutable workspace directory
cd "$BUILD_WORKSPACE_TMP"

# Copy .dart_tool tree to workspace. Dereference symlinks (-L): sandboxed
# inputs are symlinks to read-only files, and the regeneration step below
# must be able to rewrite these copies in place.
if [ -d "$DART_TOOL_DIR_ABS" ]; then
    _stage_tree "$DART_TOOL_DIR_ABS" "$PWD/.dart_tool" "$FAST_STAGING"
    if [ "$FAST_STAGING" = "1" ]; then
        # package_config.json / package_graph.json are removed and rewritten
        # below (never truncated in place), so writable directories suffice.
        _make_dirs_writable "$PWD/.dart_tool"
    else
        chmod -R u+rwX .dart_tool
    fi
fi
{android_gradle_env}
{ios_env}

# Run flutter build
echo "=== Flutter Build {target} ==="
echo "Working directory: $(pwd)"
echo "Flutter binary: $FLUTTER_BIN"
echo "Target: {target}"
echo ""

# Regenerate package_config.json with correct paths for this sandbox from the
# declared dependency metadata. Do not invoke pub here; the build action must
# use the prepared cache and metadata.
echo ""
echo "Regenerating package_config.json from declared metadata..."
DART_BIN_LOCAL="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
if [ ! -x "$DART_BIN_LOCAL" ]; then
    echo "✗ FATAL ERROR: Dart binary not found at $DART_BIN_LOCAL" >&2
    exit 1
fi
PUB_TOOL_ABS="$ORIGINAL_PWD/{pub_tool}"
if [ ! -s pubspec.lock ]; then
    echo "✗ FATAL ERROR: pubspec.lock missing from prepared workspace" >&2
    exit 1
fi

export PUBSPEC_LOCK_PATH="$PWD/pubspec.lock"
export PUB_CACHE_ABS="$PUB_CACHE_DIR_ABS"
export WORKSPACE_ABS="$PWD"
export PACKAGE_CONFIG_PATH="$PWD/.dart_tool/package_config.json"
mkdir -p "$(dirname "$PACKAGE_CONFIG_PATH")"
rm -f "$PACKAGE_CONFIG_PATH" "$PWD/.dart_tool/package_graph.json"
"$DART_BIN_LOCAL" "$PUB_TOOL_ABS" package-config
echo "✓ Package config regenerated from declared metadata"
echo ""
{mobile_pub_get}
echo "Running: $FLUTTER_BIN_ABS {build_command}"

if "$FLUTTER_BIN_ABS" --suppress-analytics --no-version-check {build_command}; then
    echo "✓ flutter {build_command} completed successfully"
{web_normalize_step}

    # Copy build artifacts to absolute path
    mkdir -p "$BUILD_ARTIFACTS_ABS"
    if [ -d "$BUILD_OUTPUT_DIR" ]; then
        echo "Copying from $BUILD_OUTPUT_DIR to $BUILD_ARTIFACTS_ABS"
        if ! cp -r "$BUILD_OUTPUT_DIR"/. "$BUILD_ARTIFACTS_ABS/"; then
            echo "✗ FATAL ERROR: copying build artifacts from $BUILD_OUTPUT_DIR failed" >&2
            exit 1
        fi
        echo "Build artifacts copied from $BUILD_OUTPUT_DIR"
        echo "Artifacts directory contents:"
        ls -la "$BUILD_ARTIFACTS_ABS" | head -10
    else
        echo "✗ FATAL ERROR: Expected build output directory $BUILD_OUTPUT_DIR not found"
        echo "Flutter build completed but did not create expected output directory"
        echo "This indicates a serious issue with Flutter build execution"
        exit 1
    fi
{android_test_step}
    echo "✓ Flutter build completed successfully"
else
    echo "✗ FATAL ERROR: flutter {build_command} failed"
    echo "Check your Flutter project configuration and dependencies"
    echo "Ensure the offline pub cache contains all required dependencies"
    exit 1
fi
printf 'Target: %s\nMode: %s\nCommand: flutter %s\nStatus: Success\n' \
    "{target}" "{mode}" "{build_command}" > "$OUTPUT_LOG_ABS"
SCRIPT_COMPLETED=1
""".format(
        workspace_dir = working_dir.path,
        pub_cache_dir = pub_cache_dir.path,
        dart_tool_dir = dart_tool_dir.path,
        flutter_bin = flutter_bin,
        output_log = build_output.path,
        build_artifacts = build_artifacts.path,
        build_command = build_command,
        build_output_dir = output_dir,
        target = target,
        mode = mode,
        env_exports = env_exports,
        android_env_exports = android_env_exports,
        android_gradle_env = android_gradle_env,
        home_export = home_export,
        ios_env = ios_env,
        mobile_pub_get = mobile_pub_get,
        android_test_step = android_test_step,
        web_normalize_step = web_normalize_step,
        pub_tool = pub_tool_file.path,
        stage_tree_helpers = STAGE_TREE_HELPERS,
        fast_staging = "1" if fast_staging else "0",
    )

    inputs = depset(
        direct = [working_dir, pub_cache_dir, dart_tool_dir, pub_tool_file] +
                 ([web_normalizer_file] if target == "web" else []) +
                 flutter_toolchain.flutterinfo.tool_files,
        transitive = [_sdk_files(flutter_toolchain, target)] +
                     ([android.files] if android else []),
    )

    # Web/desktop builds are hermetic but CPU-heavy; keep them off
    # default-size remote executors (results still remote-cache) unless the
    # consumer opts in. Android/iOS below are stricter (host-state-bound).
    execution_requirements = heavy_action_execution_requirements(allow_remote_exec)
    use_default_shell_env = False
    mnemonic = "FlutterBuild"
    if target in ANDROID_TARGETS:
        execution_requirements = heavy_action_execution_requirements(allow_remote_exec)
        use_default_shell_env = False
        mnemonic = "FlutterBuildAndroid"
    elif target == "ios":
        # Host Xcode + CocoaPods; pod install fetches specs and binary pods
        # over the network.
        execution_requirements = host_bound_action_execution_requirements({
            "requires-darwin": "1",
        })
        use_default_shell_env = True
        mnemonic = "FlutterBuildIos"

    # Execute build
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [build_output, build_artifacts],
        command = script_content,
        mnemonic = mnemonic,
        progress_message = "Running flutter build %s for %s" % (target, ctx.label.name),
        execution_requirements = execution_requirements,
        use_default_shell_env = use_default_shell_env,
        resource_set = heavy_action_resource_set,
    )

    return build_output, build_artifacts
