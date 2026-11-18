#!/usr/bin/env python3
"""Port / server-cleanup lint for tests/test-*.sh (driven by tests/test-port-hygiene.sh).

Usage: port_hygiene.py FILE...   -> prints one "<file>:<line>: <CODE> <message>" per problem,
                                    exit 1 if any (0 when clean).

Only files that launch scripts/server.js in the background are checked. Codes:

  LITERAL  a port variable gets a literal port (NAME=3700).
  OFFSET   a port is derived by arithmetic from another port ($((PORT+1)), $(($SP + 1)),
           $((1 + PORT)), $((port + 9000))). A "port variable" is any name containing
           PORT/port, plus any variable assigned from free_port / the socket-bind snippet.
  NOPID    a server launch whose pid variable can't be determined (fails closed).
  TRAP     the effective EXIT trap (bash keeps only the LAST one) does not stop_pids the
           variable holding a server's pid. A trap naming a function (quoted or not) uses
           that function's body, plus the bodies of functions it calls (one level).
  NOCLEAR  a mid-test `stop_pids $X` / `stop_pids "$X"` that does not clear X on the same
           line, so the trap could later signal a dead (possibly reused) pid. Calls inside
           the trap's own functions are exempt.

Deliberately simple: a line-based reading of bash, not a parser. When unsure it reports
(fails closed) rather than passing.
"""
import re
import sys

NAME = r"[A-Za-z_][A-Za-z0-9_]*"
BG_AMP = re.compile(r"(?<![>&|])&(?![&>])")          # a background `&`, not && / 2>&1 / &>
LAUNCH = re.compile(r"scripts/server\.js")


def logical_lines(src):
    """Join backslash-continued lines -> [(first_lineno, text)]; drop full-line comments."""
    out, buf, start = [], [], None
    for n, raw in enumerate(src.split("\n"), 1):
        if start is None:
            start = n
        if raw.rstrip().endswith("\\"):
            buf.append(raw.rstrip()[:-1])
            continue
        buf.append(raw)
        text = " ".join(buf)
        buf, s = [], start
        start = None
        if text.lstrip().startswith("#"):
            continue
        out.append((s, text))
    return out


def functions(lines):
    """name -> (first_line, last_line, body_text). One-line `f() { ...; }` is tried first,
    so its body never runs on to the next column-0 `}`."""
    fns = {}
    i = 0
    while i < len(lines):
        n, text = lines[i]
        m = re.match(r"^\s*(?:function\s+)?(%s)\s*\(\)\s*\{(.*)$" % NAME, text)
        if not m:
            i += 1
            continue
        name, rest = m.group(1), m.group(2)
        one = re.match(r"^(.*)\}\s*(?:#.*)?$", rest)
        if one and rest.count("{") < rest.count("}"):
            fns[name] = (n, n, one.group(1))
            i += 1
            continue
        body, j = [rest], i + 1
        while j < len(lines) and not re.match(r"^\}\s*(?:#.*)?$", lines[j][1]):
            body.append(lines[j][1])
            j += 1
        last = lines[j][0] if j < len(lines) else lines[-1][0]
        fns[name] = (n, last, "\n".join(body))
        i = j + 1
    return fns


def fn_of_line(fns, lineno):
    for name, (a, b, _) in fns.items():
        if a <= lineno <= b:
            return name
    return None


def pid_vars(lines, fns, src):
    """[(lineno, var-or-None)] for every background server.js launch."""
    found = []
    for idx, (n, text) in enumerate(lines):
        if not (LAUNCH.search(text) and BG_AMP.search(text.split("server.js", 1)[1])):
            continue
        win = " ; ".join(t for _, t in lines[idx:idx + 3])
        var = None
        m = re.search(r"\b(%s)=\$!" % NAME, win)                       # X=$!  /  local x=$!
        arr = re.search(r"\b(%s)\+=\(\s*\$!\s*\)" % NAME, win)          # PIDS+=($!)
        echo = re.search(r"echo \$! *> *\"?([^ \";)]+)", win)           # echo $! > file
        if m:
            var = m.group(1)
            acc = re.search(r"\b(%s)=\"\$\{?\1\}? \$\{?%s\}?\"" % (NAME, re.escape(var)), src)
            if acc:
                var = acc.group(1)                                      # ALL_PIDS="$ALL_PIDS $pid"
        elif arr:
            var = arr.group(1)
        elif echo:
            c = re.search(r"\b(%s)=\"?\$\(cat \"?%s" % (NAME, re.escape(echo.group(1))), src)
            var = c.group(1) if c else None
        elif re.search(r"\becho \"?\$!\"?", win):                       # f() { ...& echo $!; } ; X=$(f)
            fn = fn_of_line(fns, n)
            c = fn and re.search(r"\b(%s)=\"?\$\(\s*%s\b" % (NAME, re.escape(fn)), src)
            var = c.group(1) if c else None
        found.append((n, var))
    return found


def exit_trap_body(lines, fns):
    """Body of the LAST `trap ... EXIT`, with named functions (and functions they call, one
    level) expanded. Returns (body, exempt_function_names)."""
    last = None
    for n, text in lines:
        for m in re.finditer(r"\btrap\s+('([^']*)'|\"([^\"]*)\"|(%s))\s+(?:[A-Z0-9 ]*\s)?EXIT\b" % NAME, text):
            last = m.group(2) if m.group(2) is not None else m.group(3) if m.group(3) is not None else m.group(4)
    if last is None:
        return "", set()
    body, used = last, set()

    def expand(text, depth):
        nonlocal body
        for w in re.findall(NAME, text):
            if w in fns and w not in used:
                used.add(w)
                body += "\n" + fns[w][2]
                if depth < 1:
                    expand(fns[w][2], depth + 1)

    expand(last, 0)
    return body, used


def stop_args(text):
    """Variables passed to stop_pids on this text: $X, "$X", ${X}, "${X[@]}"."""
    out = []
    for call in re.findall(r"\bstop_pids\b([^;&|\n]*)", text):
        out += re.findall(r"\$\{?(%s)" % NAME, call)
    return out


def port_vars(src):
    pv = set(re.findall(r"\b(%s)=\"?\$\{?[A-Z_]*:?-?\$\(free_port\)" % NAME, src))
    pv |= set(re.findall(r"\b(%s)=\"?\$\(free_port\)" % NAME, src))
    pv |= set(re.findall(r"\b(%s)=\$\(python3 -c '[^']*bind\(\(\"127\.0\.0\.1\", ?0\)\)" % NAME, src))
    return pv


def check(path):
    src = open(path).read()
    lines = logical_lines(src)
    fns = functions(lines)
    launches = pid_vars(lines, fns, src)
    if not launches:
        return []
    probs = []
    rel = path.rsplit("/", 1)[-1]

    # LITERAL / OFFSET
    pv = port_vars(src)
    pvre = r"(?:%s)" % "|".join([r"[A-Za-z_0-9]*(?:PORT|port)[A-Za-z_0-9]*"] + [re.escape(v) for v in sorted(pv)])
    for n, text in lines:
        if re.search(r"(?:^|[;\s])([A-Z_0-9]*P[A-Z_0-9]*)=[0-9]{4,5}\b", text):
            probs.append((n, "LITERAL", "literal port: use free_port"))
        for expr in re.findall(r"\$\(\((.*?)\)\)", text):
            e = expr.replace(" ", "")
            if re.search(r"(?:^|[^A-Za-z0-9_])\$?\{?%s\}?[-+][0-9]+" % pvre, e) or \
               re.search(r"[0-9]+\+\$?\{?%s\b" % pvre, e):
                probs.append((n, "OFFSET", "port derived by arithmetic $((%s)): take another free_port" % expr.strip()))

    # NOPID / TRAP
    body, exempt = exit_trap_body(lines, fns)
    stopped = set(stop_args(body))
    for n, var in launches:
        if var is None:
            probs.append((n, "NOPID", "server launch whose pid variable can't be found"))
        elif var not in stopped:
            probs.append((n, "TRAP", "the last EXIT trap does not stop_pids $%s" % var))

    # NOCLEAR
    for n, text in lines:
        if re.search(r"\btrap\b", text) or fn_of_line(fns, n) in exempt:
            continue
        for var in stop_args(text):
            if re.search(r"\$\{?%s\[@\]" % re.escape(var), text):
                continue                                   # arrays are not single pids
            if not re.search(r"\b%s=(\"\"|''|\s|;|$)" % re.escape(var), text):
                probs.append((n, "NOCLEAR", "mid-test stop_pids $%s without clearing %s" % (var, var)))
    return ["%s:%d: %s %s" % (rel, n, code, msg) for n, code, msg in sorted(set(probs))]


def main(argv):
    out = []
    for p in argv[1:]:
        out += check(p)
    for line in out:
        print(line)
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
