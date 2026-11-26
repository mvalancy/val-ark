# Val Ark — Choosing What Goes on Your Ark

[Back to Docs](README.md) | [Back to Project Root](../README.md)

An Ark fills its disk by itself, but you decide what matters most. There are four places to say
so, from the simplest to the most detailed.

## 1. Pick a focus when you set it up

The setup wizard asks **"What do you want on it?"**. Pick one focus:

| Focus | What it favours |
|---|---|
| **A bit of everything** (default) | Wikipedia, how-to, an AI helper and tools: a sensible starter mix. |
| **Knowledge & reference** | Wikipedia, wikis, textbooks and Q&A: the biggest library. |
| **AI helper** | Local chat models and the docs they answer from. |
| **Software & tools** | Offline installers and dev/creative apps for every platform. |
| **Grid-down survival** | Medicine, water, food, repair, power and radio first; maps and manuals over big AI models. |

You can change it any time in **Settings → Downloads & Priorities** (admin only). A focus doesn't
add or remove anything by itself: it raises the weight of one kind of content (reference content,
models or tools) when the Librarian ranks what fits. To set it from `.env` instead, use
`VALARK_PROFILE=knowledge` (or `balanced`, `ai`, `tools`, `survival`).

## 2. What always comes first, whatever the focus

Before any focus applies, the Librarian takes the **grid-down essentials** in
[`data/essentials.tsv`](../data/essentials.tsv): safe water, field medicine, food, repair, a pocket
Wikipedia, a tiny setup assistant and the network-boot images, each in its smallest version. Some
rows only apply to one focus (Army field manuals, for example, only for *Grid-down survival*).
Then it fills by kind and by value per byte until the disk reaches its reserve. The
[Librarian guide](LIBRARIAN.md#the-priority-model) has the exact order, and
[how it works, in pictures](HOW-IT-WORKS.md#2-filling-the-disk) shows it as a diagram.

## 3. Ask for something specific

Anyone the [Use Mode](design/access-identity.md) allows can browse **Library → Software, AI Models
or Offline Library** and press **Request** on an item that isn't on the box yet, for example all of
Wikipedia. A request is *pinned*: it downloads now, is never evicted, and the 24/7 loop keeps it.
If the disk is full, the lowest-value unpinned item makes room. From the command line:

```bash
./scripts/librarian.sh request content wikipedia_en_all_maxi   # or: request model <id>, request tool <id>
./scripts/librarian.sh pins                                    # what's pinned
./scripts/librarian.sh unpin <id>                              # let the Librarian manage it again
```

## 4. Set limits in `.env`

| Setting | What it does |
|---|---|
| `VALARK_MAX_GB` | The most disk Val Ark may use in total (on a shared disk). |
| `VALARK_MODEL_MAX_GB` | Skip any single AI model larger than this. |
| `VALARK_RESERVE_PCT`, `VALARK_RESERVE_MIN_GB` | Free space always kept (default 2% or 50 GB, whichever is larger). |
| `VALARK_LASTBOOK_PACK` | Which Lastbook survival pack: `auto` (largest that fits), a size, `every` (servers) or `none`. |
| `VALARK_SERVICES` | Which community apps run (chat, mail, forum, paste). |

See [`.env.example`](../.env.example) for every setting and its default.

## Where to watch it

**Activity** shows what is downloading now and what is queued. **Library → Downloads** lists
what is on the box. `./scripts/librarian.sh plan` prints what the Librarian would fetch next,
in order, without downloading anything.
