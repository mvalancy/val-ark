// Val Ark — browse-catalog TSV parser (zero-dep, pure, unit-testable offline).
//
// Turns the rows emitted by `librarian.sh catalog <kind>` into the item list the
// web UI browse feed serves. The optional ZIM language filter narrows the OUTPUT
// only — it NEVER narrows the shared on-disk cache. That distinction is the fix
// for #57: the server used to shell the catalog with VALARK_ZIM_LANGS=eng, which
// made catalog_refresh_zim re-fetch English-only and atomically overwrite the full
// multi-language cache. Now the server always refreshes the full cache and filters
// languages here, on the way out, so a browse can never degrade the cache.
'use strict';
const path = require('path');

// planner --list-absent rows: id bucket cat value bytes source url dest extra phase
// opts:
//   maxItems : cap the returned list (bounds the JSON payload); default 4000
//   langs    : whitespace/comma-separated ZIM language codes to keep. A content
//              candidate id ends in `_<lang>` (e.g. `zim:wikipedia_en_all_eng`);
//              only rows matching one of these langs are kept. Non-ZIM ids
//              (`model:` / `inst:`) carry no language suffix and are always kept.
//              Empty/absent => keep every language.
function parseCatalogTSV(stdout, opts) {
    opts = opts || {};
    const maxItems = opts.maxItems || 4000;
    const langs = String(opts.langs || '').split(/[\s,]+/).filter(Boolean);
    const items = [];
    for (const line of String(stdout).split('\n')) {
        if (!line) continue;
        const p = line.split('\t');
        if (p.length < 9) continue;
        const id = p[0];
        // Language filter applies to ZIM/content candidates only. Filter FIRST,
        // then count toward maxItems, so a narrow filter still yields up to
        // maxItems matching items instead of being truncated by skipped rows.
        if (langs.length && id.startsWith('zim:')
            && !langs.some((l) => id.endsWith('_' + l))) continue;
        const bytes = parseInt(p[4], 10) || 0;
        const name = path.basename(p[7] || '') || p[8] || id;
        items.push({
            id,
            category: String(p[2] || '').replace(/^zim:|^model:/, '') || 'other',
            value: parseInt(p[3], 10) || 0,
            bytes,
            name,
        });
        if (items.length >= maxItems) break;
    }
    return items;
}

module.exports = { parseCatalogTSV };
