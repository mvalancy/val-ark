#!/usr/bin/env python3
"""
Val Ark — offline internal-Markdown link & anchor checker.

Validates that the .md hierarchy is actually interconnected: every internal link
`[text](target)` / image `![alt](target)` resolves to a real file (or directory),
and every `#anchor` resolves to a real heading (GitHub-slug) or an explicit
`<a name="...">` / `id="..."` in the target file.

Scope is deliberately repo-internal and OFFLINE — external http(s)/mailto/tel/
protocol-relative links are ignored (URL reachability is a different concern; see
test-urls.sh). Fenced code blocks and inline code spans are stripped before link
extraction so example snippets don't produce phantom links.

Usage:  md_link_check.py <repo_root> [file1.md file2.md ...]
        (no file args -> every *.md tracked by git, minus vendored/generated trees)

Exit 0 = all internal links resolve; exit 1 = one or more broken (printed).
"""
import os
import re
import subprocess
import sys

# --- markdown structure stripping -------------------------------------------
FENCE_RE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE_RE = re.compile(r"`[^`]*`")
# [text](target)  and  ![alt](target) ; target stops at whitespace or ) .
LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*(<[^>]+>|[^)\s]+)")
HEADING_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
HTML_ANCHOR_RE = re.compile(r'(?:name|id)\s*=\s*["\']([^"\']+)["\']')
TAG_RE = re.compile(r"<[^>]+>")
# Skip external / non-file schemes.
EXTERNAL_RE = re.compile(r"^(https?:|mailto:|tel:|ftp:|data:|//)", re.IGNORECASE)

VENDOR_PARTS = ("node_modules", "/results/", "tests/results")


def strip_code(text):
    """Remove fenced blocks and inline code so we don't scan example links."""
    out, in_fence = [], False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            out.append("")  # keep line count stable
            continue
        out.append("" if in_fence else INLINE_CODE_RE.sub("", line))
    return "\n".join(out)


def github_slug(text):
    """Approximate GitHub's heading-slug algorithm (github-slugger)."""
    text = TAG_RE.sub("", text)            # drop inline HTML (e.g. <a name>)
    text = text.replace("`", "")           # code-span markers in headings
    text = re.sub(r"[*_~]", "", text)      # emphasis markers
    text = text.strip().lower()
    slug = []
    for ch in text:
        if ch in (" ", "\t"):
            slug.append("-")
        elif ch == "-" or ch == "_":
            slug.append(ch)
        elif ch.isalnum():                 # unicode letters/digits; drops U+2011 etc.
            slug.append(ch)
        # everything else (punctuation, `&`, `.`, `(`, `)`) is dropped
    return "".join(slug)


def anchors_for(path, cache):
    """Return the set of valid anchors in a .md file (heading slugs + name/id)."""
    if path in cache:
        return cache[path]
    anchors, seen = set(), {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError:
        cache[path] = anchors
        return anchors
    in_fence = False
    for line in raw.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = HEADING_RE.match(line)
        if m:
            base = github_slug(m.group(2))
            if base:
                n = seen.get(base, 0)
                anchors.add(base if n == 0 else "%s-%d" % (base, n))
                seen[base] = n + 1
        for a in HTML_ANCHOR_RE.findall(line):  # explicit <a name> / id=
            anchors.add(a.lower())
    cache[path] = anchors
    return anchors


def tracked_md(root):
    try:
        out = subprocess.check_output(
            ["git", "-C", root, "ls-files", "*.md", "**/*.md"],
            text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    files = set()
    for rel in out.splitlines():
        if not rel or any(p in ("/" + rel + "/") for p in VENDOR_PARTS):
            continue
        if "node_modules" in rel or "/results/" in rel:
            continue
        files.add(os.path.join(root, rel))
    return sorted(files)


def check(root, files):
    cache = {}
    broken = []
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                content = strip_code(fh.read())
        except OSError as exc:
            broken.append((path, 0, "(unreadable)", str(exc)))
            continue
        base_dir = os.path.dirname(path)
        for lineno, line in enumerate(content.splitlines(), 1):
            for target in LINK_RE.findall(line):
                target = target.strip().lstrip("<").rstrip(">")
                if not target or EXTERNAL_RE.match(target):
                    continue
                frag = ""
                if "#" in target:
                    tpath, frag = target.split("#", 1)
                else:
                    tpath = target
                # Resolve the path component.
                if tpath == "":
                    resolved = path  # same-file anchor
                elif tpath.startswith("/"):
                    resolved = os.path.join(root, tpath.lstrip("/"))
                else:
                    resolved = os.path.normpath(os.path.join(base_dir, tpath))
                if tpath != "" and not os.path.exists(resolved):
                    broken.append((path, lineno, target, "path not found"))
                    continue
                # Anchor check only for markdown targets.
                if frag and resolved.endswith(".md") and os.path.isfile(resolved):
                    if github_slug_fragment(frag) not in anchors_for(resolved, cache):
                        broken.append((path, lineno, target,
                                       "anchor #%s not found in %s"
                                       % (frag, os.path.relpath(resolved, root))))
    return broken


def github_slug_fragment(frag):
    """A link fragment is already slug-shaped; normalize case + stray chars."""
    return github_slug(frag)


def main(argv):
    root = os.path.abspath(argv[1]) if len(argv) > 1 else os.getcwd()
    files = [os.path.abspath(f) for f in argv[2:]] or tracked_md(root)
    if not files:
        print("md_link_check: no .md files found (git ls-files empty?)")
        return 0
    broken = check(root, files)
    if not broken:
        print("md_link_check: OK — %d .md files, all internal links + anchors resolve"
              % len(files))
        return 0
    print("md_link_check: %d BROKEN internal link(s):" % len(broken))
    for path, lineno, target, why in broken:
        print("  %s:%d  ->  %s   (%s)" % (os.path.relpath(path, root), lineno, target, why))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
