"""Shared validation and sanitization helpers for Flutter rules."""

def validate_bundle_id(bundle_id):
    """Validate that a bundle_id is a well-formed reverse-DNS identifier.

    Requires at least 2 dot-separated segments, no leading/trailing dots,
    no consecutive dots, and only alphanumeric, '.', and '-' characters.

    Args:
        bundle_id: The bundle identifier string to validate.
    """
    if not is_valid_bundle_id(bundle_id):
        fail(
            ("Invalid bundle_id %r: must have ≥2 dot-separated segments, " +
             "no leading/trailing/consecutive dots, and only alphanumeric, '.', '-' characters") % bundle_id,
        )

def is_valid_bundle_id(bundle_id):
    """Check if a bundle_id is a well-formed reverse-DNS identifier.

    Requires at least 2 dot-separated segments, no leading/trailing dots,
    no consecutive dots, and only alphanumeric, '.', and '-' characters.

    Args:
        bundle_id: The bundle identifier string to check.

    Returns:
        True if the bundle_id is valid, False otherwise.
    """
    if len(bundle_id) == 0:
        return False
    if bundle_id[0] == "." or bundle_id[-1] == ".":
        return False
    if ".." in bundle_id:
        return False
    if "." not in bundle_id:
        return False
    for c in bundle_id.elems():
        if not (c.isalpha() or c.isdigit() or c in ".-"):
            return False
    return True

# Swift keywords that cannot be used bare as a module name. `import <keyword>`
# and `<keyword>.SomeClass` both fail to parse, so a target so named would
# produce a runner that cannot be imported or referenced from an Info.plist.
_SWIFT_RESERVED_MODULE_NAMES = (
    "associatedtype",
    "class",
    "deinit",
    "enum",
    "extension",
    "fileprivate",
    "func",
    "import",
    "init",
    "inout",
    "internal",
    "let",
    "open",
    "operator",
    "private",
    "precedencegroup",
    "protocol",
    "public",
    "rethrows",
    "static",
    "struct",
    "subscript",
    "typealias",
    "var",
    "break",
    "case",
    "catch",
    "continue",
    "default",
    "defer",
    "do",
    "else",
    "fallthrough",
    "for",
    "guard",
    "if",
    "in",
    "repeat",
    "return",
    "throw",
    "switch",
    "where",
    "while",
    "as",
    "Any",
    "false",
    "is",
    "nil",
    "self",
    "Self",
    "super",
    "throws",
    "true",
    "try",
)

def validate_swift_module_name(module_name, what):
    """Validate that a string can be used verbatim as a Swift module name.

    Args:
        module_name: The candidate module name.
        what: Description of where the name came from, used in the failure
            message (e.g. "flutter_macos_app(name = ...)").
    """
    if not is_valid_swift_module_name(module_name):
        fail(
            ("%s: %r cannot be used as a Swift module name. Apple's NIB and " +
             "Info.plist class lookups spell classes as <module>.<Class>, so " +
             "the module name must be a bare Swift identifier: a letter or " +
             "'_' followed by letters, digits or '_', and not a Swift " +
             "keyword. Rename the target.") % (what, module_name),
        )

def is_valid_swift_module_name(module_name):
    """Check if a string is a bare Swift identifier usable as a module name.

    Args:
        module_name: The candidate module name.

    Returns:
        True if the name is a valid Swift module name, False otherwise.
    """
    if len(module_name) == 0:
        return False
    if module_name in _SWIFT_RESERVED_MODULE_NAMES:
        return False
    first = module_name[0]
    if not (first.isalpha() or first == "_"):
        return False
    for c in module_name.elems():
        if not (c.isalpha() or c.isdigit() or c == "_"):
            return False
    return True

_VALID_WEB_COMPILER_RENDERER = {
    "dart2wasm": ["skwasm", "canvaskit"],
    "dart2js": ["canvaskit"],
}

def validate_web_compiler_renderer(compiler, renderer):
    """Validate that a web compiler+renderer combination is supported.

    Args:
        compiler: Web compiler ("dart2wasm" or "dart2js").
        renderer: Web renderer ("skwasm" or "canvaskit").
    """
    if not is_valid_web_compiler_renderer(compiler, renderer):
        fail("Invalid web compiler+renderer combination: %s+%s. skwasm requires dart2wasm." % (compiler, renderer))

def is_valid_web_compiler_renderer(compiler, renderer):
    """Check if a web compiler+renderer combination is supported.

    Args:
        compiler: Web compiler ("dart2wasm" or "dart2js").
        renderer: Web renderer ("skwasm" or "canvaskit").

    Returns:
        True if the combination is valid, False otherwise.
    """
    allowed = _VALID_WEB_COMPILER_RENDERER.get(compiler)
    if allowed == None:
        return False
    return renderer in allowed

# Define keys the ruleset sets itself: the dart.vm.* mode keys come from the
# compilation mode (see flutter_compile_kernel and the web compile actions),
# and flutter.dart_plugin_registrant names the generated registrant library
# the engine invokes before main(). User-supplied values would silently
# corrupt mode semantics or break plugin registration, so they are rejected
# up front — matching flutter_tools' own --dart-define policy.
RESERVED_DART_DEFINE_KEYS = ("dart.vm.profile", "dart.vm.product", "flutter.dart_plugin_registrant")

def validate_dart_defines(defines, what):
    """Validate a list of Dart environment defines (KEY=VALUE strings).

    Args:
        defines: List of define strings to validate.
        what: Description of where the defines came from, used in the
            failure message (e.g. a target label or a flag name).
    """
    for define in defines:
        if not is_valid_dart_define(define):
            fail(
                ("Invalid Dart define %r in %s: defines must be non-empty " +
                 "and must not set the reserved keys %s (the build sets " +
                 "these from the compilation mode)") % (define, what, ", ".join(RESERVED_DART_DEFINE_KEYS)),
            )

def is_valid_dart_define(define):
    """Check if a Dart environment define is acceptable.

    Args:
        define: A define string, normally KEY=VALUE (a bare KEY is treated
            as a key with no value, matching frontend_server -D semantics).

    Returns:
        True if the define is valid, False otherwise.
    """
    if len(define) == 0:
        return False
    return define.split("=", 1)[0] not in RESERVED_DART_DEFINE_KEYS

def escape_html(text):
    """Escape HTML special characters in a string.

    Args:
        text: The text string to escape.

    Returns:
        The escaped string safe for use in HTML attributes and content.
    """
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
