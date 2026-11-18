#!/bin/bash
# Shared helpers for tests that start a throwaway server (source it; no side effects).
#
# free_port   -> an unused TCP port on 127.0.0.1, picked by the kernel (bind to port 0).
#               Never hardcode a port: test suites run in parallel (several worktrees /
#               workers on one box), and a fixed port means one run talks to another's
#               server, or fails "did not start" because a leftover holds it.
#               A small race remains (the port is free when picked, not reserved), which
#               is far rarer than two runs choosing the same literal.
# stop_pids P.. -> TERM each pid, wait up to ~3s, then KILL whatever is still alive, so
#               a busy server can't outlive the test and keep its port. Call it from the
#               EXIT trap / cleanup for EVERY server the test started (and to stop one
#               mid-test), so the port is actually free when it returns.
# trap_signals -> INT/TERM exit with the conventional 130/143 through the EXIT trap.
#               bash 5.x already runs the EXIT trap on TERM/INT, so this is belt and
#               braces (other shells / older bash), not the fix for leaked servers.
#
# Why a test's server.js gets left behind (and holds its port for every later run):
#   * the EXIT trap never kills the server (it only `rm -rf`s the temp dir), or kills
#     an empty/stale $SRV_PID because the pid was captured inside `$(...)` / a subshell;
#   * the test is SIGKILLed (`timeout -s KILL`, an OOM kill): no trap can run then;
#   * the server ignores or outlives a plain TERM (stop_pids escalates to KILL).

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

stop_pids() {
    local p i alive
    for p in "$@"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    for i in $(seq 1 30); do
        alive=0
        for p in "$@"; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=1; done
        [ "$alive" = 0 ] && return 0
        sleep 0.1
    done
    for p in "$@"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
    return 0
}

trap_signals() { trap 'exit 130' INT; trap 'exit 143' TERM; }
