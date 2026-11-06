#!/bin/bash
# Runs outside the sandbox (a herdr tab bar command), so it resolves nothing a sandboxed command
# can write (spec 2026-10-16, sandbox write boundary). PINNED_PATH is for the suites only.
PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
exec /usr/bin/python3 -I - <<'PY'
from __future__ import annotations

import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import List, Optional, Tuple

SEPARATOR = " · "
WARN = " ⚠"
DASH = "—"
WARN_AT = 80
MAX_PCT = 1000
STALE_AFTER = 1800
TAGTEAM_TIMEOUT = 3
CODEX_MAX_AGE = 7 * 86400
CHUNK = 64 * 1024

# (percent used, window label, reset time as epoch seconds or None when not reported,
#  window length in seconds)
Window = Tuple[float, str, Optional[float], float]
CLAUDE_WINDOWS = (("fiveHour", "5h", 5 * 3600), ("sevenDay", "wk", 7 * 86400))


def number(value) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


def percent(value) -> Optional[float]:
    pct = number(value)
    return pct if pct is not None and 0 <= pct <= MAX_PCT else None


def seconds(value) -> Optional[float]:
    n = number(value)
    return n if n is not None and n >= 0 else None


def parse_iso(value) -> Optional[float]:
    if not isinstance(value, str):
        return None
    text = value.strip()
    if text[-1:] in ("Z", "z"):
        text = text[:-1] + "+00:00"
    text = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], text, count=1)
    try:
        moment = datetime.fromisoformat(text)
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=timezone.utc)
        return moment.timestamp()
    except (ValueError, OverflowError, OSError):
        return None


def now_epoch() -> float:
    try:
        return float(os.environ["HERDR_USAGE_NOW"])
    except (KeyError, ValueError):
        return time.time()


def fmt_age(age: float) -> str:
    secs = int(max(0.0, age))
    if secs < 3600:
        return "%dm" % (secs // 60)
    if secs < 48 * 3600:
        return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)


def pick_window(windows: List[Window], now: float, age: Optional[float]) -> Optional[Tuple[float, str]]:
    def is_live(window: Window) -> bool:
        if window[2] is not None:
            return window[2] > now
        return age is not None and age <= window[3]

    live = [w for w in windows if is_live(w)]
    if not live:
        return None
    best = max(live, key=lambda w: w[0])
    return best[0], best[1]


def render(label: str, picked: Optional[Tuple[float, str]], age: Optional[float], force_age: bool = False) -> str:
    if picked is None:
        return "%s %s" % (label, DASH)
    pct, win = picked
    out = "%s %d%% %s" % (label, int(pct + 0.5), win)
    if pct >= WARN_AT:
        out += WARN
    if age is None:
        out += " ·?"
    elif force_age or age > STALE_AFTER:
        out += " ·" + fmt_age(age)
    return out


def tagteam_status():
    try:
        proc = subprocess.Popen(
            ["tagteam", "status", "--json"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return None
    try:
        out, _ = proc.communicate(timeout=TAGTEAM_TIMEOUT)
    except subprocess.TimeoutExpired:
        # SIGTERM, never SIGKILL: tagteam may be mid token refresh, and only its TERM handler
        # releases the account and credential locks without losing the rotated refresh token.
        # It runs in its own session, so nothing here waits for it to finish.
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(out.decode("utf-8"))
    except ValueError:
        return None


def claude_windows(block) -> List[Window]:
    windows: List[Window] = []
    if not isinstance(block, dict):
        return windows
    for key, label, length in CLAUDE_WINDOWS:
        entry = block.get(key)
        if not isinstance(entry, dict):
            continue
        pct = percent(entry.get("pct"))
        if pct is not None:
            windows.append((pct, label, parse_iso(entry.get("resetsAt")), length))
    return windows


def claude_segment(now: float) -> Optional[str]:
    data = tagteam_status()
    active = data.get("active") if isinstance(data, dict) else None
    if not isinstance(active, dict):
        return None
    alias = active.get("alias")
    label = alias if isinstance(alias, str) and alias.strip() and alias.isprintable() else "claude"
    if active.get("usage") is not None:
        age = seconds(active.get("usageAgeSeconds"))
        return render(label, pick_window(claude_windows(active["usage"]), now, age), age)
    if active.get("lastGoodUsage") is not None:
        age = seconds(active.get("lastGoodAgeSeconds"))
        return render(label, pick_window(claude_windows(active["lastGoodUsage"]), now, age), age, force_age=True)
    return render(label, None, 0)


def window_label(minutes: float) -> Optional[str]:
    mins = int(minutes)
    if mins < 1:
        return None
    if mins == 300:
        return "5h"
    if mins == 10080:
        return "wk"
    if mins % 1440 == 0:
        return "%dd" % (mins // 1440)
    if mins % 60 == 0:
        return "%dh" % (mins // 60)
    return "%dm" % mins


def codex_windows(rate_limits: dict) -> List[Window]:
    windows: List[Window] = []
    for key in ("primary", "secondary"):
        entry = rate_limits.get(key)
        if not isinstance(entry, dict):
            continue
        pct = percent(entry.get("used_percent"))
        minutes = number(entry.get("window_minutes"))
        label = window_label(minutes) if minutes is not None else None
        if pct is not None and label is not None:
            windows.append((pct, label, number(entry.get("resets_at")), minutes * 60))
    return windows


def token_count_line(line: bytes):
    if b"token_count" not in line:
        return None
    try:
        record = json.loads(line)
    except Exception:
        return None
    payload = record.get("payload") if isinstance(record, dict) else None
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return None
    rate_limits = payload.get("rate_limits")
    stamp = parse_iso(record.get("timestamp"))
    if not isinstance(rate_limits, dict) or stamp is None:
        return None
    return stamp, rate_limits


def last_token_count(path: str):
    try:
        with open(path, "rb") as handle:
            pos = handle.seek(0, os.SEEK_END)
            partial = b""
            while pos > 0:
                start = max(0, pos - CHUNK)
                handle.seek(start)
                block = handle.read(pos - start)
                trace("read %d" % len(block))
                lines = (block + partial).split(b"\n")
                pos = start
                if pos > 0:
                    partial, lines = lines[0], lines[1:]
                else:
                    partial = b""
                for line in reversed(lines):
                    found = token_count_line(line)
                    if found is not None:
                        return found
    except OSError:
        pass
    return None


def rollout_files(home: str, now: float) -> List[Tuple[float, str]]:
    cutoff = now - CODEX_MAX_AGE
    files: List[Tuple[float, str]] = []
    for sub in ("sessions", "archived_sessions"):
        for dirpath, _dirs, names in os.walk(os.path.join(home, sub)):
            for name in names:
                if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    info = os.lstat(path)
                except OSError:
                    continue
                if stat.S_ISREG(info.st_mode) and info.st_mtime >= cutoff:
                    files.append((info.st_mtime, path))
    files.sort(reverse=True)
    return files


def trace(entry: str) -> None:
    target = os.environ.get("HERDR_USAGE_TRACE")
    if not target:
        return
    try:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(entry + "\n")
    except OSError:
        pass


def codex_segment(now: float) -> Optional[str]:
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    best = None
    for mtime, path in rollout_files(home, now):
        if best is not None and mtime < best[0]:
            break
        trace(path)
        found = last_token_count(path)
        if found is not None and (best is None or found[0] > best[0]):
            best = found
    if best is None:
        return None
    stamp, rate_limits = best
    age = max(0.0, now - stamp)
    return render("codex", pick_window(codex_windows(rate_limits), now, age), age)


def main() -> None:
    now = now_epoch()
    segments = []
    for build in (claude_segment, codex_segment):
        try:
            segment = build(now)
        except Exception:
            segment = None
        if segment:
            segments.append(segment)
    sys.stdout.buffer.write((SEPARATOR.join(segments) + "\n").encode("utf-8"))


try:
    main()
except Exception:
    sys.stdout.buffer.write(b"\n")
PY
