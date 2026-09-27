#!/usr/bin/python3
# Pinned to the system interpreter, not `env python3`: this runs inside the Codex
# daemon, and PATH there must not be able to shadow it.
"""Reconcile herdr's session id for every Codex pane from the thread id in its title.

Managed by chezmoi (source: dot_codex/executable_herdr-codex-pane-map.py).
Design: docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md, section 6.

Runs inside the Codex daemon as a SessionStart hook (hook JSON on stdin), beside herdr's own
hook, which exits there because the daemon carries no pane environment. Every TUI puts its
thread id first in its terminal title (tui.terminal_title), so the title is the join between
a pane and its thread. Each pass repairs every Codex pane, so one wrong report from anywhere
is fixed by the next session start. An id that is not on a title is never reported.

`--reconcile` runs one pass without hook input. The whole run - listing, every report and
the retries - shares one deadline (PANE_MAP_DEADLINE_SECS, 8 s), inside the 10 s hook timeout.
Never exits non-zero; never blocks a session.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

UUID = re.compile(r"^\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f-])")
DEADLINE = time.monotonic() + float(os.environ.get("PANE_MAP_DEADLINE_SECS", "8"))


def left():
    return DEADLINE - time.monotonic()


def run(cmd):
    """Run a herdr command bounded by what is left of the deadline; None when out of time."""
    budget = min(3.0, left())
    if budget <= 0:
        return None
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=budget)
    except Exception:
        return None


def herdr_bin():
    env = os.environ.get("HERDR_BIN")
    if env:
        return env if os.access(env, os.X_OK) else None
    for c in ("/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", shutil.which("herdr")):
        if c and os.access(c, os.X_OK):
            return c
    return None


def panes(herdr):
    out = run([herdr, "pane", "list"])
    try:
        return json.loads(out.stdout)["result"]["panes"] if out else []
    except Exception:
        return []


def title_uuid(pane):
    title = pane.get("terminal_title_stripped") or pane.get("terminal_title") or ""
    m = UUID.match(title)
    return m.group(1) if m else None


def report(herdr, pane_id, uuid, start_source):
    cmd = [herdr, "pane", "report-agent-session", pane_id, "--source", "herdr:codex",
           "--agent", "codex", "--agent-session-id", uuid, "--seq", str(time.time_ns())]
    if start_source:
        cmd += ["--session-start-source", start_source]
    run(cmd)


def reconcile(herdr, done, session_id=None, start_source=None):
    """One pass. Returns the set of ids currently on Codex pane titles."""
    seen = set()
    for p in panes(herdr):
        if left() <= 0:
            break
        if p.get("agent") != "codex":
            continue
        uuid = title_uuid(p)
        if not uuid:
            continue
        seen.add(uuid)
        current = (p.get("agent_session") or {}).get("value")
        key = (p.get("pane_id"), uuid)
        if uuid != current and key not in done and p.get("pane_id"):
            done.add(key)
            report(herdr, p["pane_id"], uuid, start_source if uuid == session_id else None)
    return seen


def main():
    herdr = herdr_bin()
    if not herdr:
        return
    done = set()
    if "--reconcile" in sys.argv[1:]:
        reconcile(herdr, done)
        return
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except Exception:
        hook = {}
    if not isinstance(hook, dict):
        hook = {}
    sid = hook.get("session_id") if isinstance(hook.get("session_id"), str) else None
    src = hook.get("source") if isinstance(hook.get("source"), str) else None
    retry_until = time.monotonic() + float(os.environ.get("PANE_MAP_RETRY_SECS", "5"))
    while True:
        seen = reconcile(herdr, done, sid, src)
        if not sid or sid in seen or time.monotonic() >= retry_until or left() <= 0.5:
            return
        time.sleep(0.5)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
