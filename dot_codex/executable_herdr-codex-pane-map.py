#!/usr/bin/python3
# Pinned to the system interpreter, not `env python3`: this runs inside the Codex
# daemon, and PATH there must not be able to shadow it.
"""Reconcile herdr's session id for every Codex pane from the thread id prefix in its title.

Managed by chezmoi (source: dot_codex/executable_herdr-codex-pane-map.py).
Design: docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md, section 6.

Runs inside the Codex daemon as a SessionStart hook (hook JSON on stdin), beside herdr's own
hook, which exits there because the daemon carries no pane environment. Every TUI puts its
thread id first in its terminal title (tui.terminal_title), but Codex truncates that item to
29 characters plus "..." once the thread is named (F11/F21), so the title carries only a
PREFIX. The hook's own `session_id` is a full id, so a pane whose title prefix matches it is
resolved for free; every other pane's prefix is resolved to a full id through `xreview-rpc
thread-resolve`. A prefix is never reported as if it were a full id. Each pass repairs every
Codex pane, so one wrong report from anywhere is fixed by the next session start. An id that
is not on a title is never reported.

`--reconcile` runs one pass without hook input. The whole run - listing, every report, every
resolve and the retries - shares one deadline (PANE_MAP_DEADLINE_SECS, 8 s), inside the 10 s
hook timeout. Never exits non-zero; never blocks a session.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

TITLE_ID_RE = re.compile(r"^\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{5,12})(?![0-9a-f-])")
# A raw (unstripped) title leads with a run of whitespace and/or non-ASCII spinner glyphs
# before the thread-id item; terminal_title_stripped already has that removed.
RAW_LEAD_RE = re.compile(r"^[\s\x80-\U0010FFFF]+")


def env_float(name, default):
    """An env var parsed as a float, falling back to `default` (never raising) on anything
    malformed - a bad PANE_MAP_DEADLINE_SECS or PANE_MAP_RETRY_SECS must not crash the hook."""
    try:
        return float(os.environ.get(name, default))
    except Exception:
        return float(default)


DEADLINE = time.monotonic() + env_float("PANE_MAP_DEADLINE_SECS", "8")


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


def rpc_bin():
    env = os.environ.get("XREVIEW_RPC_BIN")
    if env:
        return env if os.access(env, os.X_OK) else None
    for c in (os.path.expanduser("~/.local/bin/xreview-rpc"), shutil.which("xreview-rpc")):
        if c and os.access(c, os.X_OK):
            return c
    return None


def resolve_thread_id(prefix):
    """A title prefix resolved to a full thread id through xreview-rpc, bound by the shared
    deadline (run()). Missing, failing or timed-out resolution reports nothing for that pane -
    a prefix is never reported as if it were a full id."""
    b = rpc_bin()
    if not b:
        return None
    out = run([b, "thread-resolve", "--prefix", prefix])
    if out is None or out.returncode != 0:
        return None
    line = (out.stdout or "").strip()
    return line or None


def panes(herdr):
    out = run([herdr, "pane", "list"])
    try:
        return json.loads(out.stdout)["result"]["panes"] if out else []
    except Exception:
        return []


def title_prefix(pane):
    stripped = pane.get("terminal_title_stripped")
    if stripped:
        title = stripped
    else:
        title = RAW_LEAD_RE.sub("", pane.get("terminal_title") or "", count=1)
    m = TITLE_ID_RE.match(title)
    return m.group(1) if m else None


def report(herdr, pane_id, uuid, seq, start_source):
    cmd = [herdr, "pane", "report-agent-session", pane_id, "--source", "herdr:codex",
           "--agent", "codex", "--agent-session-id", uuid, "--seq", str(seq)]
    if start_source:
        cmd += ["--session-start-source", start_source]
    run(cmd)


def reconcile(herdr, done, session_id=None, start_source=None, failed=None):
    """One pass. Returns the set of title PREFIXES currently on Codex pane titles.

    A malformed pane entry (not a dict, a string agent_session, ...) is skipped without
    stopping the rest of the pass. `failed` is a per-run set of prefixes the resolver has
    already failed on; they are never retried within the same run (--reconcile call, or
    hook invocation across its retry passes)."""
    if failed is None:
        failed = set()
    seen = set()
    listed = panes(herdr)

    def own_pane_first(p):
        # The pane matching the hook's own session_id is handled first each pass, so a
        # deadline cutoff never leaves the just-started session unfixed for the sake of
        # unrelated panes.
        if not session_id or not isinstance(p, dict):
            return 1
        try:
            pfx = title_prefix(p)
        except Exception:
            return 1
        return 0 if pfx and session_id.startswith(pfx) else 1

    if session_id:
        listed = sorted(listed, key=own_pane_first)

    # One fingerprint for every report this pass makes: they all describe the state
    # observed in this one `pane list`, not one each's own call time.
    seq = time.time_ns()
    for p in listed:
        if left() <= 0:
            break
        try:
            if not isinstance(p, dict):
                continue
            if p.get("agent") != "codex":
                continue
            prefix = title_prefix(p)
            if not prefix:
                continue
            seen.add(prefix)
            pane_id = p.get("pane_id")
            if not pane_id:
                continue
            agent_session = p.get("agent_session")
            current = agent_session.get("value") if isinstance(agent_session, dict) else None
            if current and current.startswith(prefix):
                continue   # already correct - a prefix match is enough, never re-resolved
            if session_id and session_id.startswith(prefix):
                # The hook's own session: its full id is already known, no daemon needed.
                full, src = session_id, start_source
            elif prefix in failed:
                full, src = None, None   # already tried and failed this run - never retried
            else:
                full, src = resolve_thread_id(prefix), None
                if not full:
                    failed.add(prefix)
            if not full:
                continue
            key = (pane_id, full)
            if key in done:
                continue
            done.add(key)
            report(herdr, pane_id, full, seq, src)
        except Exception:
            continue
    return seen


def main():
    herdr = herdr_bin()
    if not herdr:
        return
    done = set()
    failed = set()
    if "--reconcile" in sys.argv[1:]:
        reconcile(herdr, done, failed=failed)
        return
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except Exception:
        hook = {}
    if not isinstance(hook, dict):
        hook = {}
    sid = hook.get("session_id") if isinstance(hook.get("session_id"), str) else None
    src = hook.get("source") if isinstance(hook.get("source"), str) else None
    retry_until = time.monotonic() + env_float("PANE_MAP_RETRY_SECS", "5")
    while True:
        seen = reconcile(herdr, done, sid, src, failed)
        # "on some title" means some title's prefix is a prefix of sid - titles never carry
        # the full id once Codex has named the thread (F11/F21).
        if not sid or any(sid.startswith(p) for p in seen) or time.monotonic() >= retry_until \
           or left() <= 0.5:
            return
        time.sleep(0.5)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
