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
Exits non-zero (after emitting nothing) if the network fetch fails, so callers
can fall back to a cached copy.
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
    ok = False
    for lang in langs:
        try:
            parse(fetch(lang), rows)
            ok = True
        except Exception as ex:  # noqa
            sys.stderr.write("kiwix_catalog: fetch failed for lang=%s: %s\n" % (lang, ex))
    # De-duplicate identical (url) rows that can appear across language queries.
    seen = set()
    for r in rows:
        if r[7] in seen:
            continue
        seen.add(r[7])
        sys.stdout.write("\t".join(r) + "\n")
    if not ok and not rows:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
