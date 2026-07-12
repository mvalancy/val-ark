# Val Ark — Recovery

Part of the [design hierarchy](README.md). Pairs with [access-identity.md](access-identity.md).
Answers: *What if someone forgets the password? How do they recover on a plugged-in
monitor, or headless? Is localhost different?* The rule that makes all of this safe:
**being physically at the box (its console) or on `localhost` = you are the Admin.**

## The recovery promise

> There is **always** a safe way back in that needs **no memory and no internet**, and
> the default recovery **never deletes your content**.

Because Val Ark is offline there is **no email reset, no "forgot password" link to the
cloud** — so recovery must be **fully local and paper-backed**. This is the single most
important thing to get right for a box in a closet owned by someone who "barely knows what
GitHub is." Two mechanisms make it work:

### The recovery card (generated at setup, meant to be printed)
Commissioning ([commissioning.md](commissioning.md)) generates a **recovery card** — a
small printable/QR card the owner keeps *by the box* — listing: the box's address
(`valark.local` + fallback IP), a **one-time recovery code**, and the reset button/beep
steps. It's the offline equivalent of the login sticker on a router. (Invert Umbrel's
"you'll never see this again" trap: offline owners must have a paper path.)

### The content-safety invariant (nothing below ever wipes Wikipedia or the models)
The tiny **config/state** (`valark/state` — admin, settings, pins) lives **physically
separate** from the multi-TB **content/model** library ([storage.md](storage.md)). Every
recovery and reset below touches *only the state*; a "panic reset" can never re-trigger a
multi-day re-download. Only an explicit, type-the-word **disk-erase** ever removes content.

## 1. Forgot the admin passcode

### If a monitor + keyboard are plugged into the box
- The box shows a simple **on-screen status page** (see [commissioning.md](commissioning.md) — the same local console used for first-boot). It always offers **"Reset admin passcode."**
- Choosing it lets you set a new passcode on the spot — you're physically at the box, so you're trusted. Nothing is wiped.
- Equivalently: open a browser **on the box itself** to `http://localhost/` — that session is Admin, so **Settings → Reset admin passcode** just works.

### If the box is headless (no monitor)
By design, another device on the LAN **cannot** reset the admin (that's the point of the passcode). So a headless reset requires proving physical presence, via one of these **rescue gestures** (documented on the box's label / quick-start card and in the UI):
- **USB rescue file** — drop an empty file named `VALARK-RESET` on a USB stick and plug it in (or create it at a known path on the boot media). On next boot the box enters **Rescue Mode**.
- **Power-cycle 3×** (router-style) — three quick power cycles trips Rescue Mode.
- **Hardware reset button** — on appliance builds with one.

In **Rescue Mode**, the box:
- Prints a **one-time reset code** to the console/log/screen and lights a clear "Rescue" indicator.
- Opens a time-boxed (e.g. 15-min) window where the **next device on the LAN** to visit the box can set a new admin passcode by entering that code — or, simplest, any `localhost` session can reset with no code.
- Leaves all content, users, and data untouched.

> This mirrors how routers (hold-reset → open `192.168.x.1`), Synology (reset button →
> re-run setup), and Home Assistant (safe mode) recover — adapted to be offline and
> content-preserving.

## 2. Locked out (too many wrong attempts)

- The passcode/login has a **cooldown**, not a permanent lock: wrong attempts slow down, then pause for a few minutes. It never bricks access.
- **`localhost`/console always bypasses the cooldown**, so the owner is never truly locked out.
- The lockout screen says, in plain words: *"Too many tries — wait 5 minutes, or reset from the box itself."* with a link to these steps.

## 3. Factory reset (start over)

Reachable from the console, `localhost`, an Admin session, or a rescue gesture. Always a
**two-choice** dialog, defaulting to the safe one:

- **Reset settings & accounts, keep my content** *(default)* — forgets the admin passcode,
  users, network/access choices, and service configs, then re-runs commissioning. Your
  Library, models, and apps stay. This is the "I messed up the settings" button.
- **Erase everything** — also removes downloaded content. Requires an explicit typed
  confirmation ("ERASE"). This is the "give the box to someone else" button.

## 4. Rescue Mode is always available (even if config is broken)

- A minimal, always-bootable state (independent of the main config) where, from the
  box/localhost/rescue-window, you can: reset the admin, fix network/access, roll back the
  last update, or factory-reset.
- If the main server can't start (bad config, half-finished update), the box **auto-enters
  Rescue Mode** and shows a plain "Val Ark needs attention — tap to fix" page rather than a
  dead port. Ties into [errors-selfheal.md](errors-selfheal.md).

## 5. Localhost / console *is* a different, more-trusted experience

To make the above concrete, the same UI adapts to **where you're connecting from**:

| From | Sees | Can do without a passcode |
|------|------|---------------------------|
| **The box's screen / `localhost`** | Everything + an "Admin (this device)" badge | Everything, incl. reset admin, factory reset |
| **LAN / tailnet** | Per the Use Mode | Use the box; Admin actions need the admin passcode (or an admin account) |
| **Public internet** | Nothing (writes denied; ideally not reachable at all) | — |

This is why "I forgot everything" is never fatal: walk up to the box (or open it on the box),
and you're in.

## What we build (summary → [roadmap.md](roadmap.md))

- A tiny **admin identity store** (hashed passcode / accounts) with a "trusted if localhost/console" rule.
- A **Rescue Mode** boot path + the three rescue gestures + one-time code.
- Console + `localhost` recovery screens; LAN lockout with cooldown + bypass.
- Factory reset with the two-choice, content-preserving default.
- Auto-Rescue when the main server can't start.
