// Val Ark — first-boot commissioning (roadmap Phase 1). Shared by scripts/server.js
// (the web wizard) and scripts/valark (console). Builds on lib/auth.js for identity.
//
// Security contract (docs/design/commissioning.md + recovery.md):
//   - An un-commissioned box is claimed with a printed/console CLAIM TOKEN. Setup
//     from the LAN is FAIL-CLOSED: no/most wrong token → refused. The box's own
//     console/localhost is trusted and may commission without a token (physical
//     possession = ownership), which is also what keeps recovery possible.
//   - The token is single-use: consumed when commissioning completes.
//   - Nothing here touches the content/model libraries (config lives in <state>).
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const auth = require('./auth');

function stateDir(dir) { return dir || auth.resolveStateDir(); }
function settingsPath(dir) { return path.join(stateDir(dir), 'settings.json'); }
function claimPath(dir) { return path.join(stateDir(dir), 'claim-token.txt'); }

function readSettings(dir) {
  try { return JSON.parse(fs.readFileSync(settingsPath(dir), 'utf8')); } catch (_) { return {}; }
}
function writeSettings(obj, dir) {
  const d = stateDir(dir);
  fs.mkdirSync(d, { recursive: true });
  const p = settingsPath(d);
  const tmp = p + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, p);
  return p;
}

function isCommissioned(dir) { return !!readSettings(dir).commissionedAt; }

// One-time migration for boxes set up BEFORE the wizard existed: record them as
// commissioned so first-boot never hijacks a working Ark. Decided ONCE (at first
// server start, from whether a library already exists) and made sticky — so content
// that appears later (e.g. a LAN download on a genuinely fresh box) can NOT flip an
// un-owned box to "commissioned" and lock its owner out of the wizard.
function grandfather(dir) {
  if (isCommissioned(dir)) return false;
  const s = readSettings(dir);
  s.commissionedAt = new Date().toISOString();
  s.via = 'legacy';
  writeSettings(s, dir);
  return true;
}

// A short, human-typeable claim code (no ambiguous 0/O/1/I) proving possession.
function genToken() {
  const alpha = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const b = crypto.randomBytes(8);
  let s = '';
  for (let i = 0; i < 8; i++) s += alpha[b[i] % alpha.length];
  return s.slice(0, 4) + '-' + s.slice(4);
}
function readClaim(dir) { try { return fs.readFileSync(claimPath(dir), 'utf8').trim(); } catch (_) { return ''; } }
function ensureClaim(dir) {
  if (isCommissioned(dir)) return '';            // an owned box has no claim code
  let t = readClaim(dir);
  if (!t) {
    const d = stateDir(dir);
    fs.mkdirSync(d, { recursive: true });
    t = genToken();
    fs.writeFileSync(claimPath(d), t + '\n', { mode: 0o600 });
  }
  return t;
}
function consumeClaim(dir) { try { fs.unlinkSync(claimPath(dir)); } catch (_) {} }

// Recovery code: the one-time reset code printed on the recovery card at setup. Stored
// (like the claim token) in the 0600 settings file so the card can be reprinted; a LAN
// device that has it can reset a forgotten admin passcode. Longer than the claim code.
function genRecoveryCode() {
  const alpha = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const b = crypto.randomBytes(12);
  let s = '';
  for (let i = 0; i < 12; i++) s += alpha[b[i] % alpha.length];
  return s.slice(0, 4) + '-' + s.slice(4, 8) + '-' + s.slice(8);
}
function readRecovery(dir) { return readSettings(dir).recovery || ''; }
function ensureRecovery(dir) {
  const s = readSettings(dir);
  if (!s.recovery) { s.recovery = genRecoveryCode(); writeSettings(s, dir); }
  return s.recovery;
}
function regenerateRecovery(dir) {
  const s = readSettings(dir);
  s.recovery = genRecoveryCode();
  writeSettings(s, dir);
  return s.recovery;
}
function verifyRecovery(code, dir) {
  const expected = readRecovery(dir);
  if (!expected) return false;
  const a = Buffer.from(String(code || '').toUpperCase().replace(/[\s-]/g, ''));
  const b = Buffer.from(expected.toUpperCase().replace(/[\s-]/g, ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Forgot-password: set a new admin passcode. Trusted (localhost/console) may do it
// with no code; from the LAN you must present the recovery code from the card. On
// success the code is ROTATED (single-use) and a fresh session is the caller's to take.
function recoverAdmin(dir, opts, ctx) {
  opts = opts || {}; ctx = ctx || {};
  if (!ctx.trusted && !verifyRecovery(opts.code, dir)) {
    return { error: 'Invalid recovery code. Check the card printed when you set up this box.' };
  }
  const pw = String(opts.password || '');
  if (pw.length < 8) return { error: 'New passcode must be at least 8 characters.' };
  auth.setPassword(pw, 'admin', dir);
  const fresh = regenerateRecovery(dir);   // single-use: old code is now dead
  return { ok: true, recovery: fresh };
}

// Public state for the wizard — NEVER leaks the claim token itself.
function state(dir, trusted) {
  const s = readSettings(dir);
  const a = auth.status(dir);
  const commissioned = !!s.commissionedAt;
  return {
    commissioned,
    adminSet: a.adminSet,
    useMode: a.useMode,
    name: s.name || null,
    profile: s.profile || null,
    trusted: !!trusted,
    hasClaim: !commissioned && !!readClaim(dir),
    // From the LAN you must present the claim code; on the box/localhost you don't.
    needsClaim: !commissioned && !trusted && !!readClaim(dir),
  };
}

const PROFILES = ['knowledge', 'ai', 'tools', 'balanced'];
const USE_MODES = ['open', 'passworded', 'accounts'];

// Complete first-boot setup. Fail-closed on the claim token unless the caller is the
// trusted box/localhost. `ctx.trusted` comes from the server's isLocalhost(req).
function commission(dir, opts, ctx) {
  opts = opts || {}; ctx = ctx || {};
  if (isCommissioned(dir)) return { error: 'This Val Ark is already set up.' };

  const trusted = !!ctx.trusted;
  if (!trusted) {
    const expected = readClaim(dir);
    const given = String(opts.token || '').toUpperCase().replace(/[\s-]/g, '');
    if (!expected || given !== expected.toUpperCase().replace(/[\s-]/g, '')) {
      return { error: 'Invalid or missing claim code. Find it on the box’s screen or label.' };
    }
  }

  const name = (String(opts.name || 'valark').trim().slice(0, 40).replace(/[^A-Za-z0-9 _-]/g, '') || 'valark');
  const profile = PROFILES.includes(opts.profile) ? opts.profile : 'balanced';
  const useMode = USE_MODES.includes(opts.useMode) ? opts.useMode : 'open';

  // Admin passcode is OPTIONAL (Jordan can skip; localhost still administers).
  if (opts.password != null && String(opts.password).length) {
    if (String(opts.password).length < 8) return { error: 'Passcode must be at least 8 characters.' };
    auth.setPassword(String(opts.password), 'admin', dir);
  }
  if (useMode !== 'open') auth.setUseMode(useMode, dir);

  const s = readSettings(dir);
  s.name = name;
  s.profile = profile;
  s.emphasis = opts.emphasis || profile;
  s.commissionedAt = new Date().toISOString();
  s.recovery = s.recovery || genRecoveryCode();   // the one-time code for the recovery card
  writeSettings(s, dir);
  consumeClaim(dir);
  return { ok: true, commissioned: true, name, profile, useMode, adminSet: auth.status(dir).adminSet, recovery: s.recovery };
}

module.exports = { state, commission, isCommissioned, ensureClaim, readClaim, consumeClaim, readSettings, writeSettings, PROFILES,
  ensureRecovery, readRecovery, regenerateRecovery, verifyRecovery, recoverAdmin, grandfather };

// ---- CLI mode (invoked by scripts/valark) ------------------------------------
if (require.main === module) {
  const cmd = process.argv[2];
  const emit = (o) => process.stdout.write(JSON.stringify(o) + '\n');
  try {
    switch (cmd) {
      case 'claim':  emit({ claim: ensureClaim(), commissioned: isCommissioned() }); break;
      case 'status': emit(state(undefined, true)); break;
      default: process.stderr.write('unknown commission command: ' + cmd + '\n'); process.exit(2);
    }
  } catch (e) { emit({ ok: false, error: e.message }); process.exit(1); }
}
