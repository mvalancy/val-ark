// Val Ark — admin identity store (Phase 2 safety net). Shared by scripts/valark
// (CLI) and scripts/server.js. Zero-dependency: node's built-in crypto only.
//
// Design contract (docs/design/access-identity.md + recovery.md):
//   - Exactly one Admin identity; NEVER a usable default credential — an un-set
//     admin means Open mode + "localhost/console is admin" (recovery is possible
//     with no password precisely because physical/loopback access = ownership).
//   - The passcode is stored ONLY as a scrypt hash (salted), never in the clear.
//   - The whole store lives in <state>/auth.json, which is physically separate
//     from the multi-TB content/model library — so a reset never wipes content.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const REPO_ROOT = path.resolve(__dirname, '..', '..');

// Mirror scripts/lib/valark-env.sh's STATE_DIR resolution so the CLI (which
// exports VALARK_STATE_DIR) and the server agree on one file.
function resolveStateDir() {
  if (process.env.VALARK_STATE_DIR) return process.env.VALARK_STATE_DIR;
  if (process.env.VALARK_HOME) return path.join(process.env.VALARK_HOME, 'state');
  const data = process.env.VAL_ARK_DATA;
  if (data && path.resolve(data) !== REPO_ROOT) return path.join(data, 'val-ark', 'state');
  return path.join(REPO_ROOT, 'state'); // repo/dev fallback
}

const SCRYPT = { N: 16384, r: 8, p: 1, keylen: 64 };

function hashPassword(pw) {
  const salt = crypto.randomBytes(16);
  const derived = crypto.scryptSync(String(pw), salt, SCRYPT.keylen, { N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p });
  return { algo: 'scrypt', N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p, salt: salt.toString('hex'), hash: derived.toString('hex') };
}

function verifyHash(pw, rec) {
  if (!rec || rec.algo !== 'scrypt' || !rec.salt || !rec.hash) return false;
  try {
    const salt = Buffer.from(rec.salt, 'hex');
    const expected = Buffer.from(rec.hash, 'hex');
    const got = crypto.scryptSync(String(pw), salt, expected.length, { N: rec.N, r: rec.r, p: rec.p });
    return got.length === expected.length && crypto.timingSafeEqual(got, expected);
  } catch (_) { return false; }
}

function storePath(dir) { return path.join(dir || resolveStateDir(), 'auth.json'); }

function readStore(dir) {
  try { return JSON.parse(fs.readFileSync(storePath(dir), 'utf8')); }
  catch (_) { return { version: 1, admin: null, useMode: 'open', accounts: [] }; }
}

function writeStore(obj, dir) {
  const d = dir || resolveStateDir();
  fs.mkdirSync(d, { recursive: true });
  const p = storePath(d);
  const tmp = p + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), { mode: 0o600 }); // 0600: passcode hash is sensitive
  fs.renameSync(tmp, p);
  try { fs.chmodSync(p, 0o600); } catch (_) {}
  return p;
}

function setPassword(pw, username, dir) {
  if (!pw || String(pw).length < 4) throw new Error('passcode must be at least 4 characters');
  const s = readStore(dir);
  s.admin = {
    username: username || (s.admin && s.admin.username) || 'admin',
    created: (s.admin && s.admin.created) || new Date().toISOString(),
    ...hashPassword(pw),
  };
  writeStore(s, dir);
  return s.admin.username;
}

function verify(pw, dir) { return verifyHash(pw, readStore(dir).admin); }

function status(dir) {
  const s = readStore(dir);
  const adminSet = !!(s.admin && s.admin.hash);
  return { commissioned: adminSet, adminSet, useMode: s.useMode || 'open', accounts: Array.isArray(s.accounts) ? s.accounts.length : 0 };
}

function listAdmins(dir) {
  const s = readStore(dir);
  const out = [];
  if (s.admin && s.admin.username) out.push({ username: s.admin.username, role: 'admin', created: s.admin.created || null });
  (s.accounts || []).forEach((a) => out.push({ username: a.username, role: a.role || 'member' }));
  return out;
}

function setUseMode(mode, dir) {
  if (!['open', 'passworded', 'accounts'].includes(mode)) throw new Error('mode must be open|passworded|accounts');
  const s = readStore(dir);
  s.useMode = mode;
  writeStore(s, dir);
  return mode;
}

// Tier-1 recovery: forget the admin passcode + reset access to Open. Keeps pins,
// accounts, and everything else. From this box/localhost you then set a new admin.
function resetTier1(dir) {
  const s = readStore(dir);
  s.admin = null;
  s.useMode = 'open';
  writeStore(s, dir);
  return true;
}

// ---- Admin sessions (stateless, HMAC-signed) ---------------------------------
// A LAN admin proves who they are once (POST /api/auth/login with the passcode) and
// gets a signed session cookie. Tokens are self-contained (`payload.hmac`); the
// server keeps no session table. "Sign out everywhere" = rotate the secret.
function sessionSecret(dir) {
  const s = readStore(dir);
  if (!s.sessionSecret) { s.sessionSecret = crypto.randomBytes(32).toString('hex'); writeStore(s, dir); }
  return s.sessionSecret;
}
function issueSession(dir, ttlMs) {
  const exp = Date.now() + (ttlMs || 12 * 3600 * 1000);
  const payload = Buffer.from(JSON.stringify({ v: 1, exp })).toString('base64url');
  const mac = crypto.createHmac('sha256', sessionSecret(dir)).update(payload).digest('hex');
  return payload + '.' + mac;
}
function verifySession(token, dir) {
  if (typeof token !== 'string') return false;
  const dot = token.indexOf('.');
  if (dot < 1) return false;
  const payload = token.slice(0, dot), mac = token.slice(dot + 1);
  try {
    const expected = crypto.createHmac('sha256', sessionSecret(dir)).update(payload).digest('hex');
    const a = Buffer.from(mac), b = Buffer.from(expected);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false;
    const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    return !!(data && data.exp && data.exp > Date.now());
  } catch (_) { return false; }
}
function rotateSessionSecret(dir) {
  const s = readStore(dir);
  s.sessionSecret = crypto.randomBytes(32).toString('hex');
  writeStore(s, dir);
  return true;
}

module.exports = {
  resolveStateDir, hashPassword, verifyHash, readStore, writeStore,
  setPassword, verify, status, listAdmins, setUseMode, resetTier1, storePath,
  issueSession, verifySession, rotateSessionSecret,
};

// ---- CLI mode (invoked by scripts/valark) ------------------------------------
// The passcode is passed via the VALARK_PW env var (never argv, so it doesn't
// show up in `ps`). Output is JSON on stdout; exit code carries verify results.
if (require.main === module) {
  const [cmd, ...rest] = process.argv.slice(2);
  const emit = (o) => process.stdout.write(JSON.stringify(o) + '\n');
  try {
    switch (cmd) {
      case 'setpassword': emit({ ok: true, username: setPassword(process.env.VALARK_PW, rest[0]) }); break;
      case 'verify':      process.exit(verify(process.env.VALARK_PW) ? 0 : 1); break;
      case 'status':      emit(status()); break;
      case 'list':        emit({ admins: listAdmins() }); break;
      case 'setmode':     emit({ ok: true, useMode: setUseMode(rest[0]) }); break;
      case 'reset-tier1': resetTier1(); emit({ ok: true, reset: 'tier1' }); break;
      default:            process.stderr.write('unknown auth command: ' + cmd + '\n'); process.exit(2);
    }
  } catch (e) {
    emit({ ok: false, error: e.message });
    process.exit(1);
  }
}
