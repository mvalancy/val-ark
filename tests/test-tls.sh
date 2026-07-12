#!/bin/bash
# Val Ark - TLS local-CA validator. Exercises scripts/lib/tls.sh in an isolated
# temp dir (never touches the real ~/.config/val-ark/tls) and asserts: a CA +
# leaf are generated, the leaf chains to the CA, SANs cover loopback + an IP,
# private keys are 0600, and re-running is idempotent (no churn, no error).
set -o pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export VALARK_TLS_DIR="$TMP/tls"

# shellcheck source=../scripts/lib/tls.sh
. "${PROJECT_ROOT}/scripts/lib/tls.sh"

ensure_valark_tls || fail "ensure_valark_tls returned non-zero"

[ -s "$TMP/tls/ca.crt" ]     || fail "CA cert not created"
[ -s "$TMP/tls/ca.key" ]     || fail "CA key not created"
[ -s "$TMP/tls/server.crt" ] || fail "server cert not created"
[ -s "$TMP/tls/server.key" ] || fail "server key not created"

# Leaf must chain to our CA.
openssl verify -CAfile "$TMP/tls/ca.crt" "$TMP/tls/server.crt" >/dev/null 2>&1 \
    || fail "leaf cert does not verify against the CA"

# SANs must cover loopback name + loopback IP at minimum.
sans="$(openssl x509 -in "$TMP/tls/server.crt" -noout -ext subjectAltName 2>/dev/null)"
echo "$sans" | grep -q "DNS:localhost"      || fail "SAN missing DNS:localhost"
echo "$sans" | grep -q "127.0.0.1"          || fail "SAN missing IP 127.0.0.1"
echo "$sans" | grep -q "DNS:valark.lan"     || fail "SAN missing DNS:valark.lan"

# Private keys must be 0600 (the whole point of keeping TLS off the FUSE disk).
perm_ca="$(stat -c '%a' "$TMP/tls/ca.key" 2>/dev/null)"
perm_sv="$(stat -c '%a' "$TMP/tls/server.key" 2>/dev/null)"
[ "$perm_ca" = "600" ] || fail "ca.key perms are $perm_ca, expected 600"
[ "$perm_sv" = "600" ] || fail "server.key perms are $perm_sv, expected 600"

# Idempotent: a second ensure must succeed and must NOT reissue (same SAN hash =>
# same leaf serial/fingerprint).
fp1="$(openssl x509 -in "$TMP/tls/server.crt" -noout -fingerprint -sha256 2>/dev/null)"
ensure_valark_tls || fail "second ensure_valark_tls failed"
fp2="$(openssl x509 -in "$TMP/tls/server.crt" -noout -fingerprint -sha256 2>/dev/null)"
[ "$fp1" = "$fp2" ] || fail "leaf was needlessly reissued on idempotent re-run"

# The exported paths must point at real files.
[ -f "$VALARK_TLS_CERT" ] && [ -f "$VALARK_TLS_KEY" ] && [ -f "$VALARK_TLS_CA" ] \
    || fail "exported VALARK_TLS_* paths are not all valid files"

echo "PASS: TLS local-CA (CA+leaf, chain, SANs, 0600 keys, idempotent)"
exit 0
