"""#171 (PY-18), the hygiene test: every scripts/*.sh and scripts/shipfloor is a wrapper and every scripts/lib/*.sh a shim.
usage: wrapper-check.py <root> [hashes]: one "<file>: <why>" line per line of logic (nothing when none); hashes: the pinned blocks' hashes."""
import glob, hashlib, os, re, sys

root, mode = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "check")
S = os.path.join(root, "scripts")
out = []
def bad(f, why): out.append("%s: %s" % (f, why))

def code(path):
    """The code lines: no shebang, no comment line, no blank line; a trailing `  # ...` comment dropped."""
    lines = []
    with open(path, encoding="utf-8", newline="") as fh:
        for i, l in enumerate(fh.read().replace("\r\n", "\n").split("\n")):
            if i == 0 and l.startswith("#!"):
                continue
            s = re.sub(r"\s+#\s.*$", "", l.rstrip())
            if s.strip() and not s.lstrip().startswith("#"):
                lines.append(s)
    return lines

def sha(lines):
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()[:16]

# ---- wrappers: scripts/*.sh and scripts/shipfloor
WRAP = [re.compile(x) for x in (
    r'HERE="\$\{0%\[/\\\\\]\*\}"; \[ "\$HERE" != "\$0" \] \|\| HERE=\.',
    r'set -- [a-z][a-z-]* "\$@"',
    r'export [A-Z_]+="\$\{?[A-Z_]+(:-)?\}?"',
    r'source "\$HERE/lib/py\.sh"')]
# the named fast paths, each pinned to its exact code: a prefix the wrapper lines follow, or the whole file
FAST_PREFIX = {"shipfloor-config.sh": [
    'if [ "${1:-}" = step ]; then',
    '  if [ -d "${SHIPFLOOR_RUN_LOCK:-}" ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then printf \'%s\\t%s\\n\' "$2" "$(date +%s)" > "$SHIPFLOOR_RUN_LOCK/step"; fi',
    '  exit 0',
    'fi']}
FAST_WHOLE = {
    "inbox-hook.sh": [
        '[ -s "${SHIPFLOOR_RUN_LOCK:-}/inbox" ] || exit 0',
        'source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"',
        'shipfloor_python "$(shipfloor_native "$SHIPFLOOR_LIB/../inbox_hook.py")"'],
    "run-dispatcher.sh": [
        'H="${SHIPFLOOR_HOME:-$HOME/.shipfloor}"',
        'mkdir -p "$H/logs"',
        'exec >>"$H/logs/dispatcher.log" 2>&1',
        '[ -e "$H/PAUSE" ] && exit 0',
        '[ -s "$H/dispatcher.path" ] && PATH="$(head -n1 "$H/dispatcher.path"):$PATH"',
        'exec bash "$(dirname "$0")/shipfloor-dispatch.sh"']}

wrappers = sorted(os.path.basename(p) for p in glob.glob(os.path.join(S, "*.sh"))) + ["shipfloor"]
for w in wrappers:
    lines = code(os.path.join(S, w))
    if w in FAST_WHOLE:
        if lines != FAST_WHOLE[w]:
            bad(w, "a named fast path, pinned to its exact code: it changed")
        continue
    pre = FAST_PREFIX.get(w, [])
    if lines[:len(pre)] != pre:
        bad(w, "its fast path changed (pinned to its exact code)")
        continue
    rest = lines[len(pre):]
    for l in rest:
        if not any(r.fullmatch(l) for r in WRAP):
            bad(w, "not a wrapper line: %s" % l.strip())
    if not rest or rest[-1] != 'source "$HERE/lib/py.sh"':
        bad(w, "does not end by sourcing lib/py.sh")
    if sum(l.startswith("set -- ") for l in rest) != 1:
        bad(w, "names no sf.py command (set -- <command> \"$@\")")

# ---- shims: scripts/lib/*.sh
# plumbing (the Python lookup, the signal forwarding, the reading of results back), pinned by a hash of its exact code
PINNED_FILES = {"py.sh": "6803c5cf68a4ca8c"}
PINNED_BLOCKS = {
    "project.sh:shipfloor_py": "7d22b20cab93b266",   # the Python lookup for sourced code (SHIPFLOOR_PY first)
    "stack.sh:_stack_prep": "d785c79738dd1b2a",      # this shell's stack settings, handed to sf.py
    "stack.sh:_stack_exec": "91d71f9198d9fc1e",
    "stack.sh:_stack_bg": "0f673bd9e910506a",        # INT/TERM forwarded to the waiting sf.py, exit 3
    "stack.sh:stack_settings": "13aba6380870e3b8",   # sf.py's values read back into the shell
    "stack.sh:slot_env": "cff66feb1dfad349",
    "stack.sh:stack_lease": "8fb090bee0192425",
    "stack.sh:stack_up": "7e19bb906c89ad12"}
PINNED_LINES = {
    "project.sh": ('SHIPFLOOR_LIB="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"',
                   'if command -v cygpath >/dev/null 2>&1; then _SHIPFLOOR_SF="$(cygpath -m "$_SHIPFLOOR_SF")"; fi'),
    "stack.sh": ('if command -v cygpath >/dev/null 2>&1; then _STACK_SF="$(cygpath -m "$_STACK_SF")"; fi',)}
FN1 = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\(\) \{ (.*); \}")
FNOPEN = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\(\) \{")
ASSIGN = re.compile(r'[A-Za-z_][A-Za-z0-9_]*="(?:[^"$`\\]|\$\{[A-Za-z_][A-Za-z0-9_]*(?::-[^}]*)?\}|\$[A-Za-z_][A-Za-z0-9_]*)*"')
SOURCE = re.compile(r'source "[^"`;&|]*"')
FLOW = re.compile(r"(^|[\s;({])(if|then|else|elif|fi|case|esac|for|while|until|do|done|select)(?=[\s;)]|$)")
blocks_seen = {}
for p in sorted(glob.glob(os.path.join(S, "lib", "*.sh"))):
    f = os.path.basename(p)
    lines = code(p)
    if f in PINNED_FILES:
        h = sha(lines)
        blocks_seen[f] = h
        if h != PINNED_FILES[f]:
            bad("lib/" + f, "the launcher is pinned by hash (plumbing): it changed (%s)" % h)
        continue
    i = 0
    while i < len(lines):
        l = lines[i]
        m1, mo = FN1.fullmatch(l), FNOPEN.fullmatch(l)
        if m1:
            if FLOW.search(m1.group(2)):
                bad("lib/" + f, "control flow in %s(): %s" % (m1.group(1), l.strip()))
            i += 1
        elif mo:
            j = i + 1
            while j < len(lines) and lines[j] != "}":
                j += 1
            h = sha(lines[i:j + 1])
            blocks_seen["%s:%s" % (f, mo.group(1))] = h
            if PINNED_BLOCKS.get("%s:%s" % (f, mo.group(1))) != h:
                bad("lib/" + f, "%s() is a multi-line block that is not pinned plumbing (%s)" % (mo.group(1), h))
            i = j + 1
        else:
            if not (SOURCE.fullmatch(l) or ASSIGN.fullmatch(l) or l in PINNED_LINES.get(f, ())):
                bad("lib/" + f, "not a shim line: %s" % l.strip())
            i += 1
if mode == "hashes":
    for k, v in sorted(blocks_seen.items()):
        print(k, v)
else:
    print("\n".join(out))
