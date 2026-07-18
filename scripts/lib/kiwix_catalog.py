#!/usr/bin/env python3
"""Val Ark - Kiwix OPDS catalog -> TSV.

Fetches the live Kiwix OPDS acquisition feed and emits one row per ZIM:

    name <TAB> flavour <TAB> category <TAB> lang <TAB> bytes <TAB> articleCount <TAB> mediaCount <TAB> url

- `name` is the content identity WITHOUT flavour/date (e.g. wikipedia_en_all),
  so maxi/nopic/mini variants of the same content share a name -> the planner
  dedupes diversity by name.
- `url` is the DIRECT, resumable .zim URL (the catalog gives a *.zim.meta4 on a
  mirror host; we strip .meta4 and use the canonical download.kiwix.org host).
- `category` falls back to the /zim/<cat>/ path segment when the OPDS
  <category> element is empty (it often is), exposing devdocs/zimit/etc.

This is the always-current source of truth, which is why stale hard-coded ZIM
dates are never an issue. Pure stdlib; no third-party deps.

Usage:
    kiwix_catalog.py [lang ...]      # default: eng
    kiwix_catalog.py eng spa fra ara hin   # multiple languages

Exit code is a COMPLETENESS signal, not just liveness: it is 0 only when EVERY
requested language fetched successfully AND yielded at least one entry. If ANY
language's feed fails (timeout, 429, non-200, truncated/unparseable body) OR comes
back as a well-formed but ENTRY-LESS HTTP-200 feed (0 rows for a requested
language, #95) it exits non-zero, so a caller can refuse to overwrite a
more-complete cache with a partial subset. Whatever rows did fetch are still
written to stdout, so a first-boot caller with no cache can still bootstrap from a
partial result. See catalog.sh:catalog_refresh_zim.
"""
import sys
import urllib.request
import xml.etree.ElementTree as ET

BASE = "https://library.kiwix.org/catalog/v2/entries"
ATOM = "{http://www.w3.org/2005/Atom}"
COUNT = 2000  # catalog is ~1099 entries/lang; one page is plenty
TIMEOUT = 90
UA = "val-ark-librarian/1.0 (+offline mirror)"


def fetch(lang):
    url = "%s?lang=%s&count=%d" % (BASE, lang, COUNT)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read()


def category_from_url(url, declared):
    if declared:
        return declared
    # https://download.kiwix.org/zim/<cat>/<file>.zim
    try:
        after = url.split("/zim/", 1)[1]
        return after.split("/", 1)[0] or "other"
    except Exception:
        return "other"


def derive_direct_url(href):
    if not href:
        return ""
    u = href
    if u.endswith(".meta4"):
        u = u[: -len(".meta4")]
    # The catalog points at a mirror (lb./lbo./master./...); the canonical host
    # serves the same path and redirects to a live mirror. Rewrite any
    # *.download.kiwix.org (and plain http) to the canonical https host.
    for host in ("https://lb.download.kiwix.org", "https://lbo.download.kiwix.org",
                 "https://master.download.kiwix.org", "http://download.kiwix.org"):
        if u.startswith(host):
            u = "https://download.kiwix.org" + u[len(host):]
            break
    return u


def parse(xml_bytes, rows):
    root = ET.fromstring(xml_bytes)
    for e in root.iter(ATOM + "entry"):
        def t(tag, default=""):
            el = e.find(ATOM + tag)
            return (el.text or default).strip() if el is not None and el.text else default
        name = t("name")
        flavour = t("flavour")
        lang = t("language", "eng")
        ac = t("articleCount", "0")
        mc = t("mediaCount", "0")
        declared_cat = t("category")
        url = ""
        length = "0"
        for link in e.findall(ATOM + "link"):
            rel = link.get("rel", "")
            if rel.endswith("acquisition/open-access") or link.get("type") == "application/x-zim":
                url = derive_direct_url(link.get("href", ""))
                length = link.get("length", "0") or "0"
                break
        if not (name and url):
            continue
        cat = category_from_url(url, declared_cat)
        # Normalise lang to first token (some are "eng,jpn")
        lang = lang.split(",")[0].strip() or "eng"
        rows.append((name, flavour, cat, lang, length, ac, mc, url))


def main():
    langs = sys.argv[1:] or ["eng"]
    rows = []
    failed = []
    empty = []
    for lang in langs:
        try:
            before = len(rows)
            parse(fetch(lang), rows)
            if len(rows) == before:
                # HTTP 200 with a well-formed but ENTRY-LESS feed for a requested
                # language yields 0 rows. Unlike an exception, this looks "successful",
                # but accepting it would let an empty feed atomically replace a fuller
                # cache and silently DROP that language (#95). Treat 0 rows for a
                # requested language as INCOMPLETE so the completeness gate keeps the
                # fuller cache — the exception path already self-preserves; this closes
                # the remaining 200/empty tail without changing the bootstrap behaviour
                # (stdout still carries whatever rows we got).
                empty.append(lang)
                sys.stderr.write("kiwix_catalog: EMPTY feed (HTTP 200, 0 entries) for lang=%s\n" % lang)
        except Exception as ex:  # noqa
            failed.append(lang)
            sys.stderr.write("kiwix_catalog: fetch failed for lang=%s: %s\n" % (lang, ex))
    # De-duplicate identical (url) rows that can appear across language queries.
    seen = set()
    for r in rows:
        if r[7] in seen:
            continue
        seen.add(r[7])
        sys.stdout.write("\t".join(r) + "\n")
    # Fail closed: a partial fetch (any requested language missing) must NOT be
    # mistaken for a complete one, or catalog_refresh_zim would atomically replace
    # the full multi-language cache with this subset. Exit non-zero unless every
    # requested language fetched. stdout already carries whatever we got, so a
    # cache-less first boot can still bootstrap from a partial result.
    incomplete = failed + empty
    if incomplete:
        sys.stderr.write("kiwix_catalog: INCOMPLETE — %d/%d languages unusable (failed: %s; empty: %s)\n"
                         % (len(incomplete), len(langs), " ".join(failed) or "-", " ".join(empty) or "-"))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
