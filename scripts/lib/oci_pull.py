#!/usr/bin/env python3
"""Pull one platform of a container image into a `docker load`-able archive.

Val Ark - zero-dependency (stdlib only) image mirror for tools whose upstream
ships as a container (e.g. OpenFOAM, which cad-agent runs in Docker). No Docker,
skopeo or registry login is needed on the mirror host.

    oci_pull.py opencfd/openfoam-default:2512 --platform linux/arm64 --out x.tar

The archive holds both layouts `docker save` writes: a Docker `manifest.json`
(with RepoTags, so `docker load -i x.tar` restores the original name:tag) and an
OCI image layout (`oci-layout`, `index.json`, `blobs/sha256/...`), so podman and
`skopeo copy oci-archive:` read it too.

Every blob is downloaded to `<out>.blobs/` (resumable with HTTP Range across
runs), checked against its sha256 digest, and only then packed. The tar is
written to `<out>.part` and renamed into place, with the manifest digest in
`<out>.digest`; a re-run whose digest matches is a no-op. Exit status: 0 done or
already current, 1 failure. One JSON summary line is printed on success.
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

INDEX_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)
MANIFEST_TYPES = (
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
)
CHUNK = 1 << 20
# A digest becomes a file name, so only the exact sha256 form is accepted
# (a registry-supplied "sha256:../../x" must never reach os.path.join).
DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")


def check_digest(d):
    if not isinstance(d, str) or not DIGEST_RE.fullmatch(d):
        raise RuntimeError("refusing malformed digest %r" % (d,))
    return d


class _NoAuthAcrossHosts(urllib.request.HTTPRedirectHandler):
    """Registries redirect blob GETs to a CDN; the bearer token is for the
    registry only, so drop Authorization when a redirect changes host."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            for k in [k for k in new.headers if k.lower() == "authorization"]:
                del new.headers[k]
            new.unredirected_hdrs.pop("Authorization", None)
        return new


_OPENER = urllib.request.build_opener(_NoAuthAcrossHosts)


def job_marker(total, part, label):
    """Tell Val Ark's job manager which file is growing (real-byte progress);
    same tab-separated contract as _common.sh download_file."""
    if os.environ.get("VALARK_JOB_MARKERS") == "1":
        print("@@valark-dl\t%d\t%s\t0\t%s" % (total or 0, part, label), file=sys.stderr, flush=True)


def parse_ref(ref):
    """'opencfd/openfoam-default:2512' -> (registry, repo, tag). Docker Hub default."""
    registry = "registry-1.docker.io"
    name = ref
    first = ref.split("/", 1)[0]
    if "/" in ref and ("." in first or ":" in first or first == "localhost"):
        registry, name = ref.split("/", 1)
    tag = "latest"
    if "@" in name:
        name, tag = name.split("@", 1)
    elif ":" in name.rsplit("/", 1)[-1]:
        name, tag = name.rsplit(":", 1)
    if registry == "registry-1.docker.io" and "/" not in name:
        name = "library/" + name
    return registry, name, tag


class Registry:
    def __init__(self, base, repo, timeout=60):
        self.base = base.rstrip("/")
        self.repo = repo
        self.timeout = timeout
        self.token = None

    def _auth(self, challenge):
        # WWW-Authenticate: Bearer realm="...",service="...",scope="..."
        if not challenge or not challenge.lower().startswith("bearer"):
            raise RuntimeError("registry wants unsupported auth: %r" % challenge)
        params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
        realm = params.pop("realm", None)
        if not realm:
            raise RuntimeError("bearer challenge without realm")
        params.setdefault("scope", "repository:%s:pull" % self.repo)
        url = realm + "?" + urllib.parse.urlencode(params)
        with _OPENER.open(url, timeout=self.timeout) as r:
            body = json.load(r)
        self.token = body.get("token") or body.get("access_token")

    def open(self, path, accept=None, headers=None):
        url = "%s/v2/%s/%s" % (self.base, self.repo, path)
        # 401 -> (re)authenticate once and retry: the first request has no token,
        # and Docker Hub tokens expire after ~300 s, so a slow pull needs a fresh
        # one part-way through.
        for attempt in range(2):
            h = dict(headers or {})
            if accept:
                h["Accept"] = accept
            if self.token:
                h["Authorization"] = "Bearer " + self.token
            req = urllib.request.Request(url, headers=h)
            try:
                return _OPENER.open(req, timeout=self.timeout)
            except urllib.error.HTTPError as e:
                if e.code == 401 and attempt == 0:
                    self.token = None
                    self._auth(e.headers.get("WWW-Authenticate", ""))
                    continue
                raise
        raise RuntimeError("unauthorized: %s" % url)

    def manifest(self, ref):
        accept = ", ".join(INDEX_TYPES + MANIFEST_TYPES)
        with self.open("manifests/" + ref, accept=accept) as r:
            raw = r.read()
            digest = r.headers.get("Docker-Content-Digest") or ""
        return raw, json.loads(raw), digest


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""):
            h.update(b)
    return h.hexdigest()


def fetch_blob(reg, digest, size, dest, retries=5):
    """Download a blob to dest (resumable), verified against its sha256 digest."""
    hexd = check_digest(digest).split(":", 1)[1]
    if os.path.exists(dest) and os.path.getsize(dest) == size and sha256_file(dest) == hexd:
        return False
    part = dest + ".part"
    for attempt in range(1, retries + 1):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        if size and have > size:
            os.remove(part)
            have = 0
        try:
            # A .part that already holds every declared byte (an earlier run died
            # before the rename) is verified as is: a Range request for it would
            # only get HTTP 416 on every rerun.
            if not (size and have == size):
                hdr = {"Range": "bytes=%d-" % have} if have else None
                job_marker(size, part, "image blob " + digest[7:19])
                with reg.open("blobs/" + digest, headers=hdr) as r:
                    mode = "ab" if (have and r.status == 206) else "wb"
                    written = have if mode == "ab" else 0
                    with open(part, mode) as f:
                        for b in iter(lambda: r.read(CHUNK), b""):
                            written += len(b)
                            if size and written > size:   # never store more than declared
                                raise RuntimeError("blob %s is larger than its declared %d bytes" % (digest[:19], size))
                            f.write(b)
        except RuntimeError:
            if os.path.exists(part):
                os.remove(part)
            raise
        except (urllib.error.URLError, OSError) as e:
            if attempt == retries:
                raise RuntimeError("blob %s failed: %s" % (digest[:19], e))
            time.sleep(min(30, 3 * attempt))
            continue
        got = sha256_file(part)
        if got == hexd and (not size or os.path.getsize(part) == size):
            os.replace(part, dest)
            return True
        os.remove(part)   # corrupt: restart this blob from zero
        if attempt == retries:
            raise RuntimeError("blob %s digest mismatch (got sha256:%s)" % (digest[:19], got[:12]))
    return False


def pick_platform(index, os_name, arch, variant=None):
    for m in index.get("manifests", []):
        p = m.get("platform") or {}
        if p.get("os") == os_name and p.get("architecture") == arch:
            if variant and p.get("variant") and p.get("variant") != variant:
                continue
            return m
    return None


def add_file(tar, name, path):
    info = tar.gettarinfo(path, arcname=name)
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = 0
    with open(path, "rb") as f:
        tar.addfile(info, f)


def add_bytes(tar, name, data):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o644
    tar.addfile(info, io.BytesIO(data))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("image", help="name[:tag], e.g. opencfd/openfoam-default:2512")
    ap.add_argument("--platform", default="linux/amd64", help="os/arch[/variant] (default linux/amd64)")
    ap.add_argument("--out", required=True, help="archive path (.tar)")
    ap.add_argument("--registry", help="override registry base URL (e.g. http://127.0.0.1:5000)")
    ap.add_argument("--max-bytes", type=int, default=0, help="refuse images whose layers total more than this")
    a = ap.parse_args(argv)

    registry, repo, tag = parse_ref(a.image)
    base = a.registry or "https://" + registry
    plat = a.platform.split("/")
    os_name, arch = plat[0], plat[1]
    variant = plat[2] if len(plat) > 2 else None
    reg = Registry(base, repo)

    raw, doc, digest = reg.manifest(tag)
    mt = doc.get("mediaType", "")
    if mt in INDEX_TYPES or "manifests" in doc:
        m = pick_platform(doc, os_name, arch, variant)
        if not m:
            have = sorted({"%s/%s" % ((x.get("platform") or {}).get("os"), (x.get("platform") or {}).get("architecture"))
                           for x in doc.get("manifests", [])})
            print("oci_pull: %s has no %s image (has: %s)" % (a.image, a.platform, ", ".join(have)), file=sys.stderr)
            return 1
        raw, doc, digest = reg.manifest(check_digest(m["digest"]))
        digest = m["digest"]
        mt = doc.get("mediaType") or m.get("mediaType") or MANIFEST_TYPES[0]
    if not digest:
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    if hashlib.sha256(raw).hexdigest() != check_digest(digest).split(":", 1)[1]:
        print("oci_pull: manifest digest mismatch for %s" % a.image, file=sys.stderr)
        return 1

    out = os.path.abspath(a.out)
    stamp = out + ".digest"
    if os.path.exists(out) and os.path.exists(stamp) and open(stamp).read().strip() == digest:
        print(json.dumps({"image": a.image, "platform": a.platform, "digest": digest,
                          "bytes": os.path.getsize(out), "status": "current"}))
        return 0

    layers = doc.get("layers", [])
    total = sum(int(l.get("size", 0)) for l in layers) + int(doc["config"].get("size", 0))
    if a.max_bytes and total > a.max_bytes:
        print("oci_pull: %s is %d bytes, over the %d byte limit" % (a.image, total, a.max_bytes), file=sys.stderr)
        return 1

    blobs = [doc["config"]] + layers
    for b in blobs:
        check_digest(b.get("digest"))
    blobdir = out + ".blobs"
    os.makedirs(blobdir, exist_ok=True)
    for i, b in enumerate(blobs):
        d = b["digest"]
        dest = os.path.join(blobdir, d.split(":", 1)[1])
        print("oci_pull: blob %d/%d %s (%.1f MB)" % (i + 1, len(blobs), d[:19], int(b.get("size", 0)) / 1e6),
              file=sys.stderr)
        fetch_blob(reg, d, int(b.get("size", 0)), dest)

    # A single-manifest image (no index) never named its platform: check the
    # config so an amd64-only image is not packed as linux/arm64.
    with open(os.path.join(blobdir, doc["config"]["digest"].split(":", 1)[1]), "rb") as f:
        cfg = json.load(f)
    if (cfg.get("os"), cfg.get("architecture")) != (os_name, arch):
        print("oci_pull: %s is %s/%s, not %s" % (a.image, cfg.get("os"), cfg.get("architecture"), a.platform), file=sys.stderr)
        return 1
    name = "%s:%s" % (repo[len("library/"):] if repo.startswith("library/") else repo, tag)
    if registry != "registry-1.docker.io" and not a.registry:
        name = registry + "/" + name
    blob = lambda d: "blobs/sha256/" + d.split(":", 1)[1]
    docker_manifest = [{"Config": blob(doc["config"]["digest"]), "RepoTags": [name],
                        "Layers": [blob(l["digest"]) for l in layers]}]
    index = {"schemaVersion": 2, "mediaType": INDEX_TYPES[0], "manifests": [{
        "mediaType": mt if mt in MANIFEST_TYPES else MANIFEST_TYPES[0], "digest": digest, "size": len(raw),
        "annotations": {"io.containerd.image.name": ("docker.io/%s:%s" % (repo, tag)) if registry == "registry-1.docker.io" else name,
                        "org.opencontainers.image.ref.name": tag},
        "platform": dict({"os": os_name, "architecture": arch}, **({"variant": variant} if variant else {}))}]}

    part = out + ".part"
    with tarfile.open(part, "w", format=tarfile.PAX_FORMAT) as t:
        add_bytes(t, "oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
        add_bytes(t, "index.json", json.dumps(index).encode())
        add_bytes(t, "manifest.json", json.dumps(docker_manifest).encode())
        add_bytes(t, blob(digest), raw)
        for b in blobs:
            add_file(t, blob(b["digest"]), os.path.join(blobdir, b["digest"].split(":", 1)[1]))
    os.replace(part, out)
    with open(stamp, "w") as f:
        f.write(digest + "\n")
    shutil.rmtree(blobdir, ignore_errors=True)
    print(json.dumps({"image": a.image, "platform": a.platform, "digest": digest, "name": name,
                      "layers": len(layers), "bytes": os.path.getsize(out), "status": "pulled"}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, urllib.error.URLError, OSError, KeyError, ValueError) as e:
        print("oci_pull: %s" % e, file=sys.stderr)
        sys.exit(1)
