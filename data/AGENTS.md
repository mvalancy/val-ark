# data/ — the catalog TSVs

Pipe-delimited (`|`) catalogs that decide what to mirror: the librarian's fill reads `installers.tsv`,
`models-extra.tsv` and `essentials.tsv`; the standalone mirror CLIs (run by hand, outside the fill)
read `dev-stack.tsv`, `apt-sets.tsv` and `source-repos.tsv`. Edit here to add
freely-redistributable install media or a small high-value model; the header comment inside each
file is the canonical schema.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

## What's here

| File | Purpose |
|------|---------|
| `installers.tsv` | Freely-redistributable OS / router-firmware / netboot / Jetson-BSP images for PXE commissioning of the mesh. |
| `apt-sets.tsv` | Offline APT package **sets** (LAMP, LAN core: DHCP/DNS/NTP/PXE/firewall, routing/VPN, file, mail/chat, directory, apps, containers, ops, plus dev-toolchain, security, reverse-eng, virt-cloud, the `desktop-apps` creative/engineering/office apps and `desktop-src`, their Ubuntu source + every build dependency). Resolved per Ubuntu suite+arch with all dependencies by `scripts/lib/apt_offline.py` into a flat local repo. |
| `essentials.tsv` | Grid-down **essentials**, ranked: what the box must hold first if the internet disappears (water, medicine, food, shelter, a pocket encyclopedia + small assistant, repair/power/radio, netboot). The planner takes these in rank order before any other phase, smallest variant first. Schema `rank\|kind\|match\|focus\|note` (`kind` = zim/model/inst, `focus` = `all` or profiles). |
| `models-extra.tsv` | Curated small, high-value models that broaden modality diversity (embeddings, rerankers, tiny VLMs, OCR, speech, safety, plus setup-assistant chat LLMs). |
| `dev-stack.tsv` | The developer + security stack: projects (not files) whose **current release** `scripts/lib/release_mirror.py` resolves live for every platform: Python, compilers, decompilers, security tools, containers/Kubernetes, cloud, S3 storage, databases, everyday CLI tools. Schema `rank\|kind\|ref\|match\|group\|note`; `match` is a regex and may contain `\|` (ref, group and note never do). |
| `source-repos.tsv` | Curated upstream source repos (`value\|owner/repo\|group`, ~240: toolchains/OS, firmware, containers, CAD, robotics, Jetson, ML, LLM inference, LAMP/LAN servers, self-hosted apps) mirrored as full-history git bundles by `scripts/lib/git_bundle_mirror.py`. |

## Schemas (field order the consumers depend on)

`installers.tsv`:

```
value|id|name|category|arch|url|bytes|sha_url|note
```

`apt-sets.tsv`:

```
value|set|packages|note
```

`packages` are binary package names, plus `build-dep:SRC` (the Build-Depends of the Ubuntu
source package SRC) and `source:SRC` (that source package, stored under `source/SRC/`). A set
using either makes `apt_offline.py` also read deb-src lists. Keep each `build-dep:X` paired
with `source:X` (tests/test-server-stack.sh checks it).

`dev-stack.tsv`:

```
rank|kind|ref|match|group|note
```

`essentials.tsv`:

```
rank|kind|match|focus|note
```

`source-repos.tsv`:

```
value|repo|group
```

`models-extra.tsv`:

```
value|id|category|repo|file|format|gated|bytes|dest|note
```

- `value` — intrinsic importance **0–1000**, NOT size; the planner derives value-per-byte from
  `value` and `bytes`, so a big high-`value` item can still lose to several small ones.
- `installers`: `category` is the diversity axis (`netboot | os-install | router-firmware | jetson-bsp | server-source`);
  `arch` is free-form/informational; `sha_url` points at the upstream checksum file.
- `models-extra`: `format` = `gguf | onnx | repo` (`repo` = HF download using `file` as an `--include`
  glob); `gated` = `no | yes`; `dest` = subdir under `MODELS_DIR`.
- `dev-stack`: `rank` orders fetching (higher first), unlike `value` it is not weighed against size;
  `kind` picks the resolver (`gh | index | gnu | go | python | pypi | pypi-top | template | snap`, see
  the header of `scripts/lib/release_mirror.py`); `match` is a regex for most kinds and may contain
  `|`, because everything between `ref` and the last two fields is the match. `ref`, `group` and
  `note` must not contain `|`.

## Consumers (change a column position → breakage)

- `scripts/lib/catalog.sh` — parses `models-extra.tsv` + `installers.tsv` into candidates.
- `scripts/lib/planner.py` — ranks candidates by derived value-per-byte; reads `essentials.tsv` (phase 0,
  via `planner.py --essentials`, which `librarian.sh plan|fill` always passes), matching `kind`+`match` against candidate ids.
- `scripts/lib/git_bundle_mirror.py` — reads `source-repos.tsv`. Use canonical `owner/repo` names (GitHub redirects renamed repos, but duplicates then slip in); `tests/test-git-bundle-mirror.sh` rejects case-insensitive duplicates.
- `scripts/loop.sh` — link-checks the `url` field on the self-heal cycle.
- `scripts/lib/apt_offline.py` — reads `apt-sets.tsv` (`sets` / `resolve` / `fetch` / `index` / `build`).
- `scripts/lib/release_mirror.py` — reads `dev-stack.tsv` (`plan` / `fetch`); `tests/test-release-mirror.sh`
  checks that every row parses and that no kind+ref+match appears twice.

`#` and blank lines are skipped by every consumer.

## How to work here

- Add a row (don't reorder or add columns without updating every consumer above).
- `curl -sI <url>` and confirm a `200` before committing; keep `bytes` roughly accurate (the planner
  and footprint caps use it).
- Prefer OPEN / redistributable sources. Dated release paths self-heal — the link-repair loop
  re-resolves `current`/`latest` dirs.

## Gotchas

- **`server-source` rows are pinned upstream releases.** Re-resolve versions when bumping (each `sha_url`
  is the upstream checksum or signature beside the tarball); `latest` URLs (WordPress, Nextcloud,
  Composer) self-heal but their `bytes` drift, so keep them within ~3%: the librarian accepts a download
  at >= 90% of `bytes`, but the planner/`candidate_present` only count it as present at >= 97%, so a row
  whose upstream shrank more than 3% re-downloads every cycle.
- **A dev-stack index row must list plain HTML.** `release_mirror.py` is stdlib-only, so a server that
  answers with Brotli (some CDN mirrors do, even to `Accept-Encoding: identity`) is an error, not
  an empty listing; pick a mirror that serves plain HTML (Wireshark: `www.wireshark.org/download/`).
- **apt sets are resolved independently** because some packages conflict (`mariadb-server` vs
  `mysql-server`); never merge conflicting packages into one set.
- **`gated: yes` models are HINTS, never auto-fetched.** They need an HF login + license acceptance,
  so the librarian skips them unless a token is present and the license is accepted.
- **One file name per category.** Rows land at `installers/<category>/<url basename>`, so two releases that
  publish the same name (NVIDIA `public_sources.tbz2`) overwrite each other; `tests/test-installers-catalog.sh`
  fails on that.
- **Value is importance, not bytes.** Setting `value` high to "force" a large download is wrong — it
  only raises priority; the size penalty still comes from `bytes`.

## Related

- [`../scripts/lib/AGENTS.md`](../scripts/lib/AGENTS.md) — `catalog.sh` / `planner.py` that consume these files
- [`../docs/LIBRARIAN.md`](../docs/LIBRARIAN.md) — the disk-fill / priority model
