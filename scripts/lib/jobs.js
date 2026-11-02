// Val Ark — download / mirror job manager (zero-dep, unit-testable).
//
// Contract with the web UI (the whole point of this module): a mirror/clone job
// ALWAYS ends in exactly one honest terminal state, and the UI can always re-sync it
// from GET /api/status/downloads:
//
//   running   -> bytes/progress are measured from the file actually being written
//                (never a guessed percent; `progress: null` = size unknown)
//   complete  -> the process exited 0 AND the post-job verify (if any) passed;
//                `outcome` carries the verify result (per-platform state + integrity)
//   failed    -> non-zero exit, killed by a signal, the process could not start,
//                a no-progress stall (no output, no file growth AND no I/O or CPU in the
//                job's process group), nothing was actually mirrored, or the server
//                restarted mid-job; `error` is a human sentence, `tail` the last log lines
//   cancelled -> the user cancelled it
//   deferred  -> the script said "busy, try later" (exit 75): NOT a success
//   queued    -> waiting behind another job of the same type
//
// Before this module a job was `status = exit-code === 0 ? 'complete' : 'failed'`
// with no reason, a progress value that stayed at 0 unless a script printed
// "Progress: N%", a cancelled job overwritten to "failed" by its own exit, a failure
// the UI hid after 8 seconds, and a "Retry" that restarted `tools all`.
'use strict';
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const SIGNALS = { 1: 'SIGHUP', 2: 'SIGINT', 3: 'SIGQUIT', 4: 'SIGILL', 6: 'SIGABRT', 7: 'SIGBUS', 8: 'SIGFPE', 9: 'SIGKILL', 11: 'SIGSEGV', 13: 'SIGPIPE', 15: 'SIGTERM' };
const ANSI = /\x1b\[[0-9;]*m/g;
const ERR_LINE = /^(ERROR|ERR|FAILED|FATAL)\b|\bFAILED\b|rate limit|\bHTTP [45]\d\d\b|\bNo space left\b|\bPermission denied\b/i;
const WARN_LINE = /^WARN(ING)?\b/;
const CURL_BAR = /^[#=>\s-]*(\d+(?:\.\d+)?)%\s*$/;

// The most informative line among a job's error lines: a concrete cause (rate limit, HTTP
// status, auth, no response, zero bytes...) beats a generic trailing "Could not find ...".
function bestReason(errors, warnings) {
    const strong = (errors || []).find(l => /rate limit|HTTP [45]\d\d|denied|authentication|unreachable|not found upstream|no response|zero-byte|Stalled|No space/i.test(l));
    const pick = strong || (errors || [])[(errors || []).length - 1] || (warnings || [])[(warnings || []).length - 1] || '';
    return pick.replace(/^((ERROR|ERR|FAILED|FATAL|WARN)\b:?\s*)+/i, '');
}

// Is anything in this job's process group doing work? Sums rchar+wchar (bytes read/written
// incl. sockets) and CPU ticks over every process whose pgrp is the job's (jobs are spawned
// detached, so pgid == the child's pid). A downloader that prints nothing - wget captured inside
// $(...), `hf download`, `git clone`, a quiet multi-GB tar extract - still moves this number;
// a hung job (sleep / dead socket) does not. Returns null when /proc is unavailable.
const HAVE_PROC = (() => { try { return fs.existsSync('/proc/self/stat'); } catch (_) { return false; } })();
function groupActivity(pgid) {
    if (!HAVE_PROC || !pgid) return null;
    let total = 0, seen = 0;
    let pids; try { pids = fs.readdirSync('/proc').filter(n => /^\d+$/.test(n)); } catch (_) { return null; }
    for (const pid of pids) {
        let st; try { st = fs.readFileSync(`/proc/${pid}/stat`, 'utf8'); } catch (_) { continue; }
        const rest = st.slice(st.lastIndexOf(')') + 2).split(' ');       // fields after "(comm) "
        if (Number(rest[2]) !== pgid) continue;                          // rest[2] = pgrp
        seen++;
        total += (Number(rest[11]) || 0) + (Number(rest[12]) || 0);       // utime + stime
        try {
            const io = fs.readFileSync(`/proc/${pid}/io`, 'utf8');
            const r = io.match(/^rchar:\s*(\d+)/m), w = io.match(/^wchar:\s*(\d+)/m);
            total += (r ? Number(r[1]) : 0) + (w ? Number(w[1]) : 0);
        } catch (_) { /* not readable: CPU ticks still count */ }
    }
    return seen ? total : 0;
}

function createJobManager(o) {
    const root = o.root;
    const stateDir = o.stateDir;
    const broadcast = o.broadcast || (() => {});
    const onFinish = o.onFinish || (() => {});
    const checkDisk = o.checkDisk || (() => null);
    const stallMs = o.stallMs > 0 ? o.stallMs : 15 * 60 * 1000;
    const pollMs = o.pollMs > 0 ? o.pollMs : 1000;
    const historyMax = o.historyMax || 40;
    const baseEnv = o.env || process.env;
    const jobsFile = stateDir ? path.join(stateDir, 'jobs.json') : null;

    const jobs = new Map();        // id -> job (internal)
    let counter = 0;

    // ── public view ─────────────────────────────────────────────────────────
    function view(j, forPersist) {
        return {
            id: j.id, type: j.type, target: j.target, label: j.label, desc: j.desc,
            status: j.status, phase: j.phase || null,
            progress: j.progress, bytes: j.bytes, total: j.total, file: j.fileLabel || null,
            overall: j.overall, lastLine: j.lastLine,
            queuedAt: j.queuedAt, startedAt: j.startedAt, finishedAt: j.finishedAt,
            exitCode: j.exitCode, signal: j.signal || null,
            error: j.error || null, warnings: j.warnings.slice(-8), outcome: j.outcome || null,
            tail: (j.status === 'failed' || j.status === 'deferred') ? j.tail.slice(-12) : undefined,
            note: j.note || null,
            retryable: !!j.desc && ['failed', 'cancelled', 'deferred'].includes(j.status),
            // pid/script are persisted (orphan cleanup after a restart) but never served over the API
            pid: forPersist && j.status === 'running' && j.proc ? j.proc.pid : undefined,
            script: forPersist && j.status === 'running' && j.spec ? path.basename(j.spec.script) : undefined,
            pstart: forPersist && j.status === 'running' && j.proc ? (j.pstart || (j.pstart = procStart(j.proc.pid))) : undefined,
            server: forPersist ? process.pid : undefined,
        };
    }
    const emit = (event, j, extra) => broadcast(event, Object.assign(view(j), extra || {}));

    function persist() {
        if (!jobsFile) return;
        try {
            // Running/queued jobs are persisted too: after a restart they are reported as
            // "interrupted" instead of silently disappearing (recover()).
            const done = [...jobs.values()].sort((a, b) => Number(a.id) - Number(b.id)).slice(-historyMax).map(j => view(j, true));
            fs.mkdirSync(stateDir, { recursive: true });
            const tmp = jobsFile + '.tmp';
            fs.writeFileSync(tmp, JSON.stringify({ counter, jobs: done }));
            fs.renameSync(tmp, jobsFile);
        } catch (_) { /* history is best-effort; live state is in memory */ }
    }

    // On boot: history survives a restart, and anything that was mid-flight is reported
    // as interrupted — never left "running" forever (nor silently forgotten).
    function recover() {
        if (!jobsFile) return;
        try {
            const data = JSON.parse(fs.readFileSync(jobsFile, 'utf8'));
            if (!data || typeof data !== 'object' || !Array.isArray(data.jobs)) return;   // wrong shape: ignore, never crash the server
            counter = Math.max(counter, Number(data.counter) || 0);
            for (const v of data.jobs) {
                if (!v || typeof v !== 'object' || v.id == null) continue;
                const j = hydrate(v);
                if (['running', 'queued'].includes(j.status)) {
                    j.status = 'failed'; j.finishedAt = Date.now();
                    const killed = stopOrphan(v);
                    j.error = 'Interrupted: Val Ark restarted while this was in progress.' + (killed ? ' The leftover download process was stopped.' : '') + ' Partial files are kept — Retry resumes.';
                }
                jobs.set(j.id, j);
                counter = Math.max(counter, Number(j.id) || 0);
            }
        } catch (_) { /* unreadable / corrupt history is best-effort */ }
    }
    // The detached job process group outlives a server restart. Stop it (so a Retry does not
    // start a second writer on the same files) — but ONLY if the recorded pid is still the same
    // job: after a reboot the pid may belong to something unrelated, so its command line must
    // still name the job's script.
    function procStart(pid) {            // /proc/<pid>/stat field 22 (starttime): identifies THIS process, not a recycled pid
        try { const st = fs.readFileSync(`/proc/${pid}/stat`, 'utf8'); return st.slice(st.lastIndexOf(')') + 2).split(' ')[19] || null; } catch (_) { return null; }
    }
    function pidAlive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }
    function stopOrphan(v) {
        const pid = Number(v.pid);
        if (!pid || !v.script || !HAVE_PROC) return false;
        // Another server sharing this state dir may still own the job: never touch it while that
        // server is alive, and only stop a process whose start time matches what was recorded.
        if (v.server && Number(v.server) !== process.pid && pidAlive(Number(v.server))) return false;
        if (!v.pstart || procStart(pid) !== String(v.pstart)) return false;
        try {
            const cmd = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8');
            if (!cmd.includes(v.script)) return false;
            process.kill(-pid, 'SIGTERM');
            setTimeout(() => { try { process.kill(-pid, 'SIGKILL'); } catch (_) {} }, 5000).unref();
            return true;
        } catch (_) { return false; }
    }
    function hydrate(v) {
        return Object.assign(blank(String(v.id), v.type, v.target, v.label, v.desc), v,
            { warnings: v.warnings || [], tail: v.tail || [], errors: [], spec: null });
    }
    function blank(id, type, target, label, desc) {
        return {
            id, type, target: target || null, label: label || type, desc: desc || null,
            status: 'queued', progress: null, bytes: null, total: null, fileLabel: null, overall: null,
            lastLine: '', warnings: [], errors: [], tail: [], proc: null, spec: null,
            queuedAt: Date.now(), startedAt: null, finishedAt: null, exitCode: null,
            lastOutputAt: 0, lastBytesAt: 0, file: null, curlPct: null,
        };
    }

    // ── starting ───────────────────────────────────────────────────────────
    // spec: { type, target, label, script, args[], desc, verify?: async (job)=>result }
    function start(spec) {
        for (const j of jobs.values()) {
            if (['running', 'queued'].includes(j.status) && j.type === spec.type && j.target === (spec.target || null)) {
                return { id: j.id, type: j.type, existing: true, status: j.status };
            }
        }
        const dErr = checkDisk();
        if (dErr) return { error: dErr };
        // A new run of the same thing supersedes the old finished ones (a Retry must not leave
        // the stale failed card beside the new result, and Dismiss must not resurrect an
        // older run's strip).
        for (const [oid, o] of jobs) {
            if (!['running', 'queued'].includes(o.status) && o.type === spec.type && o.target === (spec.target || null)) jobs.delete(oid);
        }
        const id = String(++counter);
        const j = blank(id, spec.type, spec.target, spec.label, spec.desc);
        j.spec = spec;
        jobs.set(id, j);
        trim();
        const lane = [...jobs.values()].find(x => x !== j && x.type === j.type && x.status === 'running');
        if (lane) {
            j.status = 'queued';
            j.note = `Waiting for "${lane.label}" to finish.`;
            emit('start', j);
            persist();
            return { id, type: j.type, status: 'queued' };
        }
        run(j);
        return { id, type: j.type, pid: j.proc && j.proc.pid, status: j.status };
    }

    function run(j) {
        const spec = j.spec;
        j.status = 'running'; j.note = null; j.startedAt = Date.now();
        j.lastOutputAt = j.lastBytesAt = j.startedAt;
        const env = Object.assign({}, baseEnv, spec.env || {}, { FORCE_COLOR: '0', VALARK_JOB_MARKERS: '1' });
        let proc;
        try {
            proc = spawn('/usr/bin/bash', [spec.script, ...(spec.args || [])], { cwd: root, env, detached: true });
        } catch (e) {
            return finish(j, { error: 'Could not start: ' + e.message });
        }
        j.proc = proc;
        emit('start', j);
        persist();
        let pending = '';
        const feed = (chunk) => {
            pending += chunk.toString();
            const parts = pending.split(/[\r\n]+/);
            pending = parts.pop();
            for (const p of parts) onLine(j, p);
        };
        proc.stdout.on('data', feed);
        proc.stderr.on('data', feed);
        proc.on('error', (err) => finish(j, { error: 'Could not start: ' + err.message }));
        proc.on('close', (code, signal) => {
            if (pending) onLine(j, pending);
            sample(j);
            finish(j, { code, signal });
        });
    }

    function onLine(j, raw) {
        const line = raw.replace(ANSI, '').replace(/^\[\d{2}:\d{2}:\d{2}\]\s*/, '').trim();
        if (!line) return;
        j.lastOutputAt = Date.now();
        if (line.startsWith('@@valark-dl\t')) {            // <total>\t<part>\t<sparse>\t<label>
            const f = line.split('\t');
            j.file = { total: Number(f[1]) || 0, part: f[2] || '', sparse: f[3] === '1' };
            j.fileLabel = f.slice(4).join('\t') || null;
            j.total = j.file.total || null; j.bytes = 0; j.curlPct = null;
            j.progress = j.file.total > 0 ? 0 : null;     // a NEW file starts at 0 — never inherit the last file's percent
            sample(j); broadcastProgress(j);
            return;
        }
        if (/already (extracted|exists|mirrored|cloned)|\bskipping\b/i.test(line)) j.sawAlready = true;
        if (/^(OK:? )?(Downloaded|Extracted|Cloned)\b/.test(line)) j.sawFresh = true;
        if (/^(OK:? )?(Downloaded|Cloned)\b/.test(line) && j.file) {   // the script renamed .part into place: this file is complete
            j.file.done = true;
            if (j.file.total > 0) { j.bytes = j.file.total; j.progress = 100; }
        }
        if (/^[#O=>\s-]+$/.test(line)) return;              // curl's spinner when the size is unknown: noise, not a message
        const pm = line.match(/Progress:\s*(\d+)%/);
        if (pm) { j.overall = Math.min(100, parseInt(pm[1], 10)); }
        const cm = line.match(CURL_BAR);
        if (cm) {                                         // curl's per-file bar: real, but only for this file
            j.curlPct = Math.min(100, parseFloat(cm[1]));
            if (!j.file || !j.file.total) j.progress = Math.floor(j.curlPct);
            return;
        }
        j.lastLine = line.slice(0, 200);
        j.tail.push(j.lastLine); if (j.tail.length > 40) j.tail.shift();
        if (ERR_LINE.test(line)) { j.errors.push(j.lastLine); if (j.errors.length > 20) j.errors.shift(); }
        else if (WARN_LINE.test(line)) { j.warnings.push(j.lastLine); if (j.warnings.length > 20) j.warnings.shift(); }
        broadcastProgress(j);
    }
    function broadcastProgress(j) {
        emit('progress', j, { line: j.lastLine });
    }

    // Measure the file the script is actually writing: this is the ONLY source of the
    // job's percent. Called by the poll timer and on every marker/close.
    function sample(j) {
        const f = j.file; if (!f || !f.part || f.done) return;
        let st; try { st = fs.statSync(f.part); } catch (_) { return; }   // renamed = finished; keep last reading
        const got = f.sparse ? Math.min(st.size, st.blocks * 512) : st.size;
        if (got !== j.bytes) { j.bytes = got; j.lastBytesAt = Date.now(); }
        j.progress = f.total > 0 ? Math.max(0, Math.min(100, Math.floor(got * 100 / f.total))) : (j.curlPct != null ? Math.floor(j.curlPct) : null);
    }

    // ── watchdog: sample real bytes + kill a job with no output AND no byte growth ─
    const timer = setInterval(() => {
        const now = Date.now();
        for (const j of jobs.values()) {
            if (j.status !== 'running' || !j.proc || j.phase === 'verifying') continue;
            const before = j.bytes, beforeP = j.progress;
            sample(j);
            if (j.bytes !== before || j.progress !== beforeP) broadcastProgress(j);
            // Liveness = output OR measured file growth OR any I/O / CPU in the process group.
            const act = groupActivity(j.proc.pid);
            if (act !== null && act !== j.lastActivity) { j.lastActivity = act; j.lastActAt = now; }
            const idleFor = now - Math.max(j.lastOutputAt, j.lastBytesAt, j.startedAt, j.lastActAt || 0);
            // Without /proc we cannot see silent downloaders: don't guess — only an explicitly
            // marker-tracked job (real bytes) can be declared stalled there.
            if (act === null && !j.file) continue;
            if (idleFor > stallMs && !j.stalled) {
                j.stalled = true;
                j.error = `Stalled: no download progress for ${fmtDur(idleFor)}${j.fileLabel ? ' (' + j.fileLabel + ')' : ''}. The job was stopped; partial files are kept so Retry resumes.`;
                killGroup(j, 'SIGTERM');
                setTimeout(() => killGroup(j, 'SIGKILL'), 5000).unref();
            }
        }
    }, pollMs);
    timer.unref();

    function killGroup(j, sig) {
        if (!j.proc || !j.proc.pid) return;
        try { process.kill(-j.proc.pid, sig); }
        catch (_) { try { process.kill(j.proc.pid, sig); } catch (__) { /* already gone */ } }
    }

    // ── finishing: the ONE place a terminal state is decided ───────────────────
    async function finish(j, r) {
        if (j.finalized) return;
        j.finalized = true;
        j.exitCode = r.code == null ? null : r.code;
        j.signal = r.signal || null;
        // A shell child killed by a signal reports 128+N (its parent bash swallows the signal):
        // recognise it so a crash reads "killed by SIGKILL", not a bare "exit code 137".
        if (!r.signal && r.code > 128 && r.code < 160 && SIGNALS[r.code - 128]) { r.signal = SIGNALS[r.code - 128]; j.signal = r.signal; }
        let status, error = null;
        if (j.cancelRequested) { status = 'cancelled'; }
        else if (j.stalled) { status = 'failed'; error = j.error; }
        else if (r.error) { status = 'failed'; error = r.error; }
        else if (r.signal) { status = 'failed'; error = `The job was killed by ${r.signal}${r.signal === 'SIGKILL' ? ' (out of memory or stopped from outside)' : ''}.` + lastReason(j); }
        else if (r.code === 75) { status = 'deferred'; j.note = 'Another mirror/fill is busy. The item is pinned and will be fetched automatically — or press Retry.'; }
        else if (r.code !== 0) {
            status = 'failed';
            const why = bestReason(j.errors, j.warnings);
            const more = j.errors.length > 1 ? ` (+${j.errors.length - 1} more error${j.errors.length > 2 ? 's' : ''} in the log below)` : '';
            error = why ? why + more : `Exited with code ${r.code}.` + lastReason(j);
        }
        else { status = 'complete'; }

        if (status === 'complete' && j.spec && j.spec.verify) {
            j.phase = 'verifying'; j.lastLine = 'Verifying what was mirrored…'; emit('progress', j, { line: j.lastLine });
            try {
                const v = await j.spec.verify(j);
                if (v) {
                    j.outcome = v;
                    if (v.warnings && v.warnings.length) j.warnings.push(...v.warnings);
                    if (v.ok === false) { status = 'failed'; error = v.error || 'Verification failed.'; }
                }
            } catch (e) {
                status = 'failed'; error = 'Could not verify the result: ' + e.message;
            }
            j.phase = null;
        }
        j.status = status; j.error = error; j.finishedAt = Date.now(); j.proc = null;
        if (status === 'complete') { j.progress = 100; if (j.total) j.bytes = j.total; }
        try { onFinish(j); } catch (_) {}
        emit('complete', j, { error: j.error, exitCode: j.exitCode });
        persist();
        const nextJob = [...jobs.values()].find(x => x.type === j.type && x.status === 'queued');
        if (nextJob) run(nextJob);
    }
    function lastReason(j) {
        const e = j.errors[j.errors.length - 1] || j.tail[j.tail.length - 1];
        return e ? ' Last output: ' + e : '';
    }
    function fmtDur(ms) { const s = Math.round(ms / 1000); return s < 120 ? s + 's' : Math.round(s / 60) + ' min'; }

    // ── control ────────────────────────────────────────────────────────────
    function cancel(id) {
        const j = jobs.get(id);
        if (!j) return { error: 'Download not found' };
        if (j.status === 'queued') {
            j.status = 'cancelled'; j.finishedAt = Date.now(); j.cancelRequested = true; j.finalized = true;
            emit('complete', j); persist();
            return { ok: true };
        }
        if (j.status !== 'running') return { error: 'Download not running' };
        if (j.phase === 'verifying') return { error: 'Already finishing (verifying the result)' };
        j.cancelRequested = true;
        killGroup(j, 'SIGTERM');
        setTimeout(() => killGroup(j, 'SIGKILL'), 5000).unref();
        return { ok: true };
    }
    function dismiss(id) {
        const j = jobs.get(id);
        if (!j) return { error: 'Download not found' };
        if (['running', 'queued'].includes(j.status)) return { error: 'Cancel it first' };
        jobs.delete(id); persist();
        return { ok: true };
    }
    function trim() {
        const done = [...jobs.values()].filter(j => !['running', 'queued'].includes(j.status));
        const over = done.length - historyMax;
        if (over > 0) done.sort((a, b) => (a.finishedAt || 0) - (b.finishedAt || 0)).slice(0, over).forEach(j => jobs.delete(j.id));
    }
    const get = (id) => jobs.get(id) ? view(jobs.get(id)) : null;
    function snapshot() { const out = {}; for (const [id, j] of jobs) out[id] = view(j); return out; }

    recover();
    return { start, cancel, dismiss, get, snapshot, view, _jobs: jobs, _stop: () => clearInterval(timer) };
}

module.exports = { createJobManager, bestReason };
