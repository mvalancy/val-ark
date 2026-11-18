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
#               a busy server can't outlive the test and keep its port.
# trap_signals -> make INT/TERM exit through the EXIT trap (bash skips the EXIT trap
#               when killed by a signal it has no trap for), so cleanup always runs.

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
