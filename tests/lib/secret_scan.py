#!/usr/bin/env python3
"""
Val Ark — offline secret / private-host leak scanner (issue #130).

The repo is PUBLIC (Prime Directive 1): no real host names, LAN/private IPs,
credentials, or host paths may ever land in git. This gate ratchets that:
motivated by a real host name that sat committed in a tests/ README example and
passed every CI run (scrubbed in #129 — deliberately NOT re-named here).

What it FAILS on (all offline, repo-internal):
  1. A tracked secret file — any `*.env` (but `.env.example`/`.sample`/…),
     private keys (`*.pem`/`*.key`/`id_rsa`/…), `.netrc`, credential stores.
  2. A concrete RFC1918 private IPv4 (full 4-octet 10./192.168./172.16-31.*).
  3. A URL host on a private TLD (`.local`/`.lan`/`.internal`/`.home`/`.corp`),
     or a private IPv6 ULA (fc00::/fd00::) in a URL host.
  4. A bare single-label URL host (e.g. `http://<lan-box>:3000`) that is not a
     known generic service name — the exact class that leaked. URL schemes
     covered include http(s), ssh, git, ftp, and the service schemes
     redis/postgres/mongodb/amqp/mysql/mqtt/ws(s) (DB/queue/socket strings).
  5. An inline private-key body (`-----BEGIN … PRIVATE KEY-----`) or an AWS
     access-key id (`AKIA…`/`ASIA…`) in any tracked text file.

What PASSES automatically: public dotted domains (github.com, huggingface.co…),
loopback (localhost/127.0.0.1/0.0.0.0/::1), and placeholders/templates
(anything with `$ { } < > *` — shell/JS interpolation, regex, `<ark-host>`).

Exceptions live in tests/lib/secrets-allowlist.txt (one reviewed token per line),
so a genuine false positive is a one-line fix; a real new leak still fails.

Usage:  secret_scan.py <repo_root>
Exit 0 = clean; exit 1 = leak(s) printed.
"""
import os
import re
import subprocess
import sys

# Files we never scan (generated / vendored / our own pattern definitions).
SKIP_DIR_PARTS = ("node_modules/", "tests/results/", ".git/")
SKIP_EXACT = (
    "tests/lib/secret_scan.py",
    "tests/test-secrets.sh",
    "tests/lib/secrets-allowlist.txt",
)
SKIP_EXT = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".svg", ".webp", ".pdf",
            ".woff", ".woff2", ".ttf", ".eot", ".gz", ".zip", ".tar", ".bundle",
            ".mp4", ".mp3", ".wav", ".bin", ".wasm")

# Tracked-file leaks (a real secret should never be committed at all). Matches
# any *.env (prefixed too: production.env), private keys, and credential stores.
SECRET_FILE_RE = re.compile(
    r"(^|/)([^/]*\.env(\.[^/]*)?|.*\.pem|.*\.key|.*\.p12|.*\.pfx|.*\.ppk|"
    r"id_rsa[^/]*|id_ed25519[^/]*|id_ecdsa[^/]*|\.netrc|\.npmrc|.*\.keystore|"
    r".*\.kdbx)$")
# Example/template env files are documentation, not secrets.
SECRET_FILE_OK = re.compile(r"\.env\.(example|sample|template|dist)$")

# A full 4-octet RFC1918 private IPv4 (version strings like 10.0.4 won't match).
PRIVATE_IP_RE = re.compile(
    r"\b(?:10(?:\.\d{1,3}){3}"
    r"|192\.168(?:\.\d{1,3}){2}"
    r"|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b")

# A private IPv6 ULA (fc00::/7), checked ONLY as a URL host so the ULA-detection
# code/comments elsewhere (e.g. server.js) aren't false-flagged.
ULA_IPV6_RE = re.compile(r"^f[cd][0-9a-f]{2}:[0-9a-f:]+$", re.IGNORECASE)

# URL host — http(s)/ssh/git/ftp plus DB/queue/socket schemes whose connection
# strings can carry a real host just as easily (redis://host, ws://host, …).
# Host capture allows [ ] so bracketed IPv6 literals ([fc00::1]:port) survive;
# classify_host unwraps them. Still stops at / whitespace quotes < > ) { }.
URL_HOST_RE = re.compile(
    r"(?:https?|ssh|rsync|git|ftp|rediss?|postgres(?:ql)?|mongodb(?:\+srv)?|"
    r"amqps?|mysql|mqtts?|wss?)://([^/\s\"'<>){}]+)", re.IGNORECASE)

# High-signal content secrets (zero false positives on this repo).
CONTENT_SECRET_RES = (
    (re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"),
     "inline private-key body"),
    (re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
     "AWS access-key id"),
)

PRIVATE_TLDS = (".local", ".lan", ".internal", ".home", ".corp", ".intranet",
                ".localdomain")
LOOPBACK = {"localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"}
# Generic service / role names that legitimately appear as bare URL hosts
# (docker/compose/proxy targets, platform roles) — not real machine identities.
GENERIC_HOSTS = {
    "localhost", "host", "server", "web", "app", "api", "node", "unix",
    "redis", "forum", "chat", "mail", "paste", "seaweedfs", "kiwix", "alps",
    "nodebb", "maddy", "thelounge", "ngircd", "microbin", "db", "database",
    "postgres", "postgresql", "pg", "grafana", "influxdb", "telegraf", "milvus",
    "ollama", "n8n", "minio", "valark", "ark", "jetson", "thor", "gb10",
    "example", "placeholder",
}
# A token that cannot be a real hostname (contains interpolation/regex/markup).
NON_HOST_CHARS = re.compile(r"[${}<>*|\\`()\[\]!?%^,;&\s]")
# Obvious placeholder wording inside an otherwise hostname-shaped token.
PLACEHOLDER_WORDS = re.compile(
    r"your|example|placeholder|changeme|sample|dummy|this-?ip|-ip\b|my-|xxx",
    re.IGNORECASE)


def load_allowlist(root):
    allow = set()
    path = os.path.join(root, "tests", "lib", "secrets-allowlist.txt")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                tok = line.split("#", 1)[0].strip()
                if tok:
                    allow.add(tok.lower())
    except OSError:
        pass
    return allow


def tracked_files(root):
    try:
        out = subprocess.check_output(["git", "-C", root, "ls-files"],
                                      text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return [r for r in out.splitlines() if r]


def is_binary(path):
    try:
        with open(path, "rb") as fh:
            return b"\0" in fh.read(4096)
    except OSError:
        return True


def classify_host(host, allow):
    """Return a reason string if the host is a leak, else None."""
    h = host.strip().lower()
    if "@" in h:                        # user:pass@host -> host
        h = h.split("@", 1)[1]
    m = re.match(r"^\[([^\]]+)\](?::\d+)?$", h)  # [ipv6] or [ipv6]:port
    if m:
        h = m.group(1)
    else:
        h = re.sub(r":\d+$", "", h)     # strip trailing :port
    if not h or h in allow or h in LOOPBACK or h in GENERIC_HOSTS:
        return None
    # IPv6 literal: only a private ULA (fc00::/7) is a leak; public IPv6 is fine.
    if "::" in h or h.count(":") >= 2:
        return ("private IPv6 ULA in URL host"
                if ULA_IPV6_RE.match(h) else None)
    if NON_HOST_CHARS.search(host):     # template / regex / markup token
        return None
    if PLACEHOLDER_WORDS.search(h):     # your-server-ip, <this-ip>, example…
        return None
    if len(h) <= 1:                     # single-char test dummy (http://x)
        return None
    if PRIVATE_IP_RE.search(h):
        return "private IPv4 in URL host"
    for tld in PRIVATE_TLDS:
        if h.endswith(tld):
            return "private-TLD host (%s)" % tld
    if "." in h:                        # dotted public domain -> allowed
        return None
    # Bare single-label host, not loopback/generic/allowlisted -> the leak class.
    return "bare single-label URL host (possible real machine name)"


def scan(root):
    allow = load_allowlist(root)
    findings = []
    for rel in tracked_files(root):
        if rel in SKIP_EXACT or any(p in ("/" + rel) for p in SKIP_DIR_PARTS):
            continue
        low = rel.lower()
        # (1) tracked secret files
        if SECRET_FILE_RE.search(rel) and not SECRET_FILE_OK.search(rel):
            findings.append((rel, 0, rel, "tracked secret/credential file"))
            continue
        if any(low.endswith(e) for e in SKIP_EXT):
            continue
        path = os.path.join(root, rel)
        if not os.path.isfile(path) or is_binary(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            # (2) concrete private IPs
            for m in PRIVATE_IP_RE.finditer(line):
                tok = m.group(0)
                if tok.lower() not in allow:
                    findings.append((rel, n, tok, "concrete RFC1918 private IP"))
            # (3)/(4) URL hosts (incl. DB/queue/socket schemes + IPv6 ULA)
            for host in URL_HOST_RE.findall(line):
                why = classify_host(host, allow)
                if why:
                    findings.append((rel, n, host, why))
            # (5) high-signal content secrets
            for rx, label in CONTENT_SECRET_RES:
                m = rx.search(line)
                if m and m.group(0).lower() not in allow:
                    findings.append((rel, n, m.group(0)[:24], label))
    return findings


def main(argv):
    root = os.path.abspath(argv[1]) if len(argv) > 1 else os.getcwd()
    findings = scan(root)
    if not findings:
        print("secret_scan: OK — no private IPs, private-TLD/bare hosts, or "
              "tracked secret files")
        return 0
    # De-dup identical (file,line,token).
    seen, uniq = set(), []
    for f in findings:
        k = (f[0], f[1], f[2], f[3])
        if k not in seen:
            seen.add(k)
            uniq.append(f)
    print("secret_scan: %d potential leak(s) "
          "(allowlist real exceptions in tests/lib/secrets-allowlist.txt):"
          % len(uniq))
    for rel, n, tok, why in uniq:
        loc = "%s:%d" % (rel, n) if n else rel
        print("  %s  ->  %s   (%s)" % (loc, tok, why))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
