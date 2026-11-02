# data/ — the catalog TSVs

Two pipe-delimited (`|`) catalogs the librarian reads to decide what to mirror. Edit here to add
freely-redistributable install media or a small high-value model; the header comment inside each
file is the canonical schema.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

## What's here

| File | Purpose |
|------|---------|
| `installers.tsv` | Freely-redistributable OS / router-firmware / netboot / Jetson-BSP images for PXE commissioning of the mesh. |
| `models-extra.tsv` | Curated small, high-value models that broaden modality diversity (embeddings, rerankers, tiny VLMs, OCR, speech, safety, plus setup-assistant chat LLMs). |

## Schemas (field order the consumers depend on)

`installers.tsv`:

```
value|id|name|category|arch|url|bytes|sha_url|note
```

`models-extra.tsv`:

```
value|id|category|repo|file|format|gated|bytes|dest|note
```

- `value` — intrinsic importance **0–1000**, NOT size; the planner derives value-per-byte from
  `value` and `bytes`, so a big high-`value` item can still lose to several small ones.
- `installers`: `category` is the diversity axis (`netboot | os-install | router-firmware | jetson-bsp`);
  `arch` is free-form/informational; `sha_url` points at the upstream checksum file.
- `models-extra`: `format` = `gguf | onnx | repo` (`repo` = HF download using `file` as an `--include`
  glob); `gated` = `no | yes`; `dest` = subdir under `MODELS_DIR`.

## Consumers (change a column position → breakage)

- `scripts/lib/catalog.sh` — parses both files.
- `scripts/planner.py` — ranks rows by derived value-per-byte.
- `scripts/loop.sh` — link-checks the `url` field on the self-heal cycle.

`#` and blank lines are skipped by all three.

## How to work here

- Add a row (don't reorder or add columns without updating all three consumers above).
- `curl -sI <url>` and confirm a `200` before committing; keep `bytes` roughly accurate (the planner
  and footprint caps use it).
- Prefer OPEN / redistributable sources. Dated release paths self-heal — the link-repair loop
  re-resolves `current`/`latest` dirs.

## Gotchas

- **`gated: yes` models are HINTS, never auto-fetched.** They need an HF login + license acceptance,
  so the librarian skips them unless a token is present and the license is accepted.
- **Value is importance, not bytes.** Setting `value` high to "force" a large download is wrong — it
  only raises priority; the size penalty still comes from `bytes`.

## Related

- [`../scripts/lib/AGENTS.md`](../scripts/lib/AGENTS.md) — `catalog.sh` / `planner.py` that consume these files
- [`../docs/LIBRARIAN.md`](../docs/LIBRARIAN.md) — the disk-fill / priority model
