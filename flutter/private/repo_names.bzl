"""Canonical repository naming shared by the extension-generated repos."""

def sibling_canonical_repo(current_repo_name, sibling_apparent_name):
    """Canonical name of a sibling repo created by the same module extension.

    Repos an extension generates are not in any module's repo mapping, so a
    sibling cannot be named with a `Label` — an extension-generated repo can
    only be addressed by its canonical name. Bazel builds that name as
    `<extension prefix><separator><apparent name>`, so the prefix is recovered
    from this repo's own canonical name.

    That separator is Bazel's, not ours: it was `~` before Bazel 7.1 and is
    `+` now, and this code was broken once by that change. It lives here, in
    one place, with one explicit error, so a future change is a one-line fix
    rather than a hunt through the repo rules.

    Args:
        current_repo_name: `repository_ctx.name`, the canonical name of the
            repository currently being fetched.
        sibling_apparent_name: the sibling's name as passed to its repo rule.

    Returns:
        The sibling's canonical repository name.
    """
    if "+" not in current_repo_name:
        fail(
            ("rules_flutter: cannot derive sibling repository '{}' from " +
             "canonical repo name '{}' (no '+' separator). This usually means " +
             "Bazel changed its canonical repository name format; update " +
             "sibling_canonical_repo in //flutter/private:repo_names.bzl.").format(
                sibling_apparent_name,
                current_repo_name,
            ),
        )
    prefix, _, _ = current_repo_name.rpartition("+")
    return "{}+{}".format(prefix, sibling_apparent_name)
