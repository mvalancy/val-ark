#!/bin/bash
# Val Ark - local TLS certificate authority + leaf cert (offline, zero-config).
#
# Why this exists: Val Ark is an offline LAN appliance, so there is no public CA
# and no internet to reach Let's Encrypt. To get HTTPS for the web shell, STARTTLS
# for mail (maddy) and TLS for IRC (ngIRCd), we run our OWN tiny certificate
# authority: a long-lived CA cert + a short-lived server leaf covering every name
# and IP a client might reach the Ark by (localhost, the LAN IPs, the Tailscale
# IP, and the stable `valark.lan` hostname). Devices install the CA once (the web
# UI offers it as a one-click download) and then every Ark service is trusted.
#
# SECURITY: the CA *private key* is the master key for the whole LAN — anyone who
# has it can impersonate the Ark. The data disk is a world-readable FUSE/NTFS
# mount (chmod is ignored there), so we deliberately keep TLS material OFF the
# data tree, under a path on a real filesystem that honours 0600 (default
# $HOME/.config/val-ark/tls). Override with VALARK_TLS_DIR.
#
# This file is both sourceable (services call ensure_valark_tls) and runnable
# (`tls.sh ensure|info|print-ca|dir|sans`). It installs nothing system-wide.

# --- resolution -------------------------------------------------------------
# Keep keys off the FUSE/NTFS data disk (which ignores chmod). Default to the
# XDG config dir on the local (permission-respecting) filesystem.
valark_tls_dir() {
    if [ -n "${VALARK_TLS_DIR:-}" ]; then echo "$VALARK_TLS_DIR"; return; fi
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/val-ark/tls"
}

VALARK_TLS_DOMAIN="${VALARK_TLS_DOMAIN:-valark.lan}"
_TLS_CA_DAYS="${VALARK_TLS_CA_DAYS:-3650}"     # CA validity (10y)
_TLS_LEAF_DAYS="${VALARK_TLS_LEAF_DAYS:-825}"  # leaf validity (<=825, browser cap)

_tls_log() { printf '[tls] %s\n' "$*" >&2; }

# Collect every Subject Alternative Name a client could reach the Ark by.
# Stable + per-host: localhost/loopback, the configured domain (+ wildcard), and
# every IP the box currently answers on (LAN, Tailscale, bridges — extra is
# harmless). Printed one per line as "DNS:x" / "IP:x".
valark_tls_sans() {
    local d="$VALARK_TLS_DOMAIN"
    printf 'DNS:%s\n' "localhost" "$d" "*.$d"
    local hn; hn="$(hostname -s 2>/dev/null)"; [ -n "$hn" ] && printf 'DNS:%s\n' "$hn"
    printf 'IP:%s\n' "127.0.0.1" "::1"
    # IPv4/IPv6 addresses this host currently has.
    local ip
    for ip in $(hostname -I 2>/dev/null); do
        printf 'IP:%s\n' "$ip"
    done
}

# Stable fingerprint of the SAN set, so we regenerate the leaf when the host's
# addresses change (new LAN, Tailscale up, etc.).
_tls_sans_hash() { valark_tls_sans | LC_ALL=C sort | openssl dgst -sha256 | awk '{print $NF}'; }

# --- CA ---------------------------------------------------------------------
ensure_valark_ca() {
    local dir; dir="$(valark_tls_dir)"
    mkdir -p "$dir" 2>/dev/null || true
    chmod 700 "$dir" 2>/dev/null || true
    local ca_key="$dir/ca.key" ca_crt="$dir/ca.crt"
    if [ -s "$ca_key" ] && [ -s "$ca_crt" ]; then return 0; fi
    _tls_log "generating Val Ark local CA -> $ca_crt"
    openssl genrsa -out "$ca_key" 4096 >/dev/null 2>&1 || { _tls_log "FAILED: openssl genrsa (CA)"; return 1; }
    openssl req -x509 -new -nodes -key "$ca_key" -sha256 -days "$_TLS_CA_DAYS" \
        -subj "/O=Val Ark/CN=Val Ark Local CA" -out "$ca_crt" >/dev/null 2>&1 \
        || { _tls_log "FAILED: openssl req (CA)"; return 1; }
    chmod 600 "$ca_key" 2>/dev/null || true
    chmod 644 "$ca_crt" 2>/dev/null || true
}

# --- leaf (server) cert -----------------------------------------------------
ensure_valark_cert() {
    local dir; dir="$(valark_tls_dir)"
    ensure_valark_ca || return 1
    local ca_key="$dir/ca.key" ca_crt="$dir/ca.crt"
    local key="$dir/server.key" crt="$dir/server.crt" hashf="$dir/.sans.sha256"
    local want; want="$(_tls_sans_hash)"

    # Reuse the existing leaf only if it exists, isn't expiring within 30 days,
    # and still covers the current set of names/IPs.
    if [ -s "$key" ] && [ -s "$crt" ] && [ -f "$hashf" ] && [ "$(cat "$hashf" 2>/dev/null)" = "$want" ]; then
        if openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null 2>&1; then
            return 0
        fi
    fi

    _tls_log "issuing Val Ark server certificate -> $crt"
    local ext csr; ext="$(mktemp)"; csr="$(mktemp)"
    {
        echo "basicConstraints=CA:FALSE"
        echo "keyUsage=digitalSignature,keyEncipherment"
        echo "extendedKeyUsage=serverAuth"
        printf 'subjectAltName=%s\n' "$(valark_tls_sans | paste -sd, -)"
    } > "$ext"

    openssl genrsa -out "$key" 2048 >/dev/null 2>&1 || { _tls_log "FAILED: openssl genrsa (leaf)"; rm -f "$ext" "$csr"; return 1; }
    openssl req -new -key "$key" -subj "/O=Val Ark/CN=${VALARK_TLS_DOMAIN}" -out "$csr" >/dev/null 2>&1 \
        || { _tls_log "FAILED: openssl req (leaf CSR)"; rm -f "$ext" "$csr"; return 1; }
    openssl x509 -req -in "$csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial \
        -days "$_TLS_LEAF_DAYS" -sha256 -extfile "$ext" -out "$crt" >/dev/null 2>&1 \
        || { _tls_log "FAILED: openssl x509 (leaf sign)"; rm -f "$ext" "$csr"; return 1; }
    rm -f "$ext" "$csr"
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$crt" 2>/dev/null || true
    echo "$want" > "$hashf"
}

# Idempotent one-shot: ensure CA + leaf exist & are current, then export paths.
ensure_valark_tls() {
    command -v openssl >/dev/null 2>&1 || { _tls_log "openssl not found — cannot set up TLS"; return 1; }
    ensure_valark_cert || return 1
    local dir; dir="$(valark_tls_dir)"
    export VALARK_TLS_CA="$dir/ca.crt"
    export VALARK_TLS_CERT="$dir/server.crt"
    export VALARK_TLS_KEY="$dir/server.key"
    return 0
}

# --- CLI --------------------------------------------------------------------
_tls_info() {
    local dir; dir="$(valark_tls_dir)"
    echo "TLS dir : $dir"
    if [ -s "$dir/ca.crt" ]; then
        echo "CA      : $dir/ca.crt"
        openssl x509 -in "$dir/ca.crt" -noout -subject -enddate 2>/dev/null | sed 's/^/          /'
    else
        echo "CA      : (not generated yet)"
    fi
    if [ -s "$dir/server.crt" ]; then
        echo "Leaf    : $dir/server.crt"
        openssl x509 -in "$dir/server.crt" -noout -subject -enddate 2>/dev/null | sed 's/^/          /'
        echo "SANs    :"; openssl x509 -in "$dir/server.crt" -noout -ext subjectAltName 2>/dev/null | grep -v subjectAltName | sed 's/^ */          /'
    else
        echo "Leaf    : (not generated yet)"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-ensure}" in
        ensure)    ensure_valark_tls && { echo "OK: $(valark_tls_dir)"; _tls_info; } ;;
        info)      _tls_info ;;
        print-ca)  cat "$(valark_tls_dir)/ca.crt" ;;
        dir)       valark_tls_dir ;;
        sans)      valark_tls_sans ;;
        *)         echo "usage: tls.sh [ensure|info|print-ca|dir|sans]" >&2; exit 2 ;;
    esac
fi
