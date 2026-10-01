#!/usr/bin/env python3
"""Mechanical intervention metrics from Claude Code transcripts.

The safe-autonomy evaluation (docs/superpowers/specs/2026-09-30-safe-autonomy-design.md,
section 5) compares these against the 2026-09-16..30 baseline. Only what a transcript
records mechanically is counted here; whether a human turn was AVOIDABLE stays a
hand-labelling pass.

    .scripts/measure-interventions.py [--days 14] [--projects-dir ~/.claude/projects]

Prints one JSON object. Streams every file line by line and keeps only per-file state,
so a month of transcripts never has to fit in memory. Standard library only.

Transcript shape (observed 2026-09-30, Claude Code 2.1.285):
  <projects-dir>/<project>/<session>.jsonl                  a main session
  <projects-dir>/<project>/<session>/subagents/<agent>.jsonl a subagent of it
  a genuine human turn is either a `user` entry whose origin.kind is "human" (tool
  results, peer messages and task notifications carry other origins or none), or an
  `attachment` entry of type queued_command whose origin.kind is "human" (typed while
  the agent was working).
  a backgrounded Bash call answers at once with "running in background with ID: <id>";
  its real outcome is a later user entry whose content is a <task-notification> carrying
  that <task-id>, a <status> (completed or failed) and, in the <summary>, an exit code.
  While the agent is mid-turn the same notification arrives instead as an `attachment`
  entry of type queued_command whose origin.kind is "task-notification" and whose text
  is in attachment.prompt; it settles the call the same way and is never a human turn.
  an interrupt is a `user` entry with no origin whose content is a text block starting
  "[Request interrupted by user".

Known edges of the counts:
  - a session that straddles the cutoff has its first IN-WINDOW human turn treated as
    its first, so it does not count toward human_turns.after_first;
  - an unfinished trailing stretch (the last human turn, never followed by another one
    the agent waited for) is dropped from autonomous_stretch;
  - autonomous_stretch.tool_calls counts main-session tool calls only, never a
    subagent's;
  - an xreview call the harness or a guard refused (no verdict, a guard denial) never
    ran, so it still counts as a dispatch or collect but never as a failure.
"""
import argparse
import datetime
import json
import os
import re
import sys

DENIALS = [
    ("path-resolution-guard", r"Compound command starting with `cd`|Recursive search rooted at"),
    ("git-forge-guard", r"This repo ships an MR/PR template|Agent attribution is not allowed"),
    ("push-guard", r"Push guard|unsupported push configuration for the push guard"),
    ("worktree-guard", r"Raw `git worktree remove`"),
    ("xreview-guard", r"No (approved pre-merge )?Codex cross-review on record"),
    ("xreview-apply-guard", r"Outside the cross-review apply window"),
    ("classifier-deny", r"Permission for this action was denied by the Claude Code auto mode"),
    ("classifier-no-verdict", r"The server-side auto mode classifier gave no verdict"),
    ("builtin-safety-check", r"Permission for this command was denied by a built-in"),
    ("user-rejected", r"The user doesn't want to proceed"),
]
# Anchored at the start of the tool result, after an optional hook-error prefix, so a
# result that merely QUOTES a guard message (a cat of the guard, a grep) is not a denial.
DENIAL_RES = [(name, re.compile(r"^(?:PreToolUse:\w+ hook error: )?(?:" + pat + ")"))
              for name, pat in DENIALS]
# xreview in command position: at the start, after an operator, or inside $( ... ), which
# is how the cross-review skill writes it (NONCE=$(xreview dispatch ...)). A quoted mention
# (rg "xreview dispatch") is not a call, and single-quoted text is removed first: nothing
# inside single quotes executes (printf %s 'NONCE=$(xreview dispatch ...)').
SINGLE_QUOTED = re.compile(r"'[^']*'")
XREVIEW_RE = re.compile(r"(?:^|[;&|(\n]|\$\()\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:command\s+)?(?:\S*/)?xreview\s+(dispatch|collect)\b")
INTERRUPT = "[Request interrupted by user"
BACKGROUND_ID_RE = re.compile(r"running in background with ID: ([A-Za-z0-9_-]+)")
NOTIFICATION = "<task-notification>"
TASK_ID_RE = re.compile(r"<task-id>([^<]*)</task-id>")
STATUS_RE = re.compile(r"<status>([^<]*)</status>")
EXIT_CODE_RE = re.compile(r"exit(?: code)?[ :]+(\d+)")
SUMMARY_RE = re.compile(r"<summary>(.*?)</summary>", re.S)


def parse_ts(value):
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in content)
    return ""


def is_human(entry):
    kind = entry.get("type")
    if kind == "user":
        if (entry.get("origin") or {}).get("kind") != "human" or entry.get("isMeta"):
            return False
        content = (entry.get("message") or {}).get("content")
        if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return False
        return not text_of(content).startswith(INTERRUPT)
    if kind == "attachment":
        att = entry.get("attachment") or {}
        return att.get("type") == "queued_command" and (att.get("origin") or {}).get("kind") == "human"
    return False


def is_interrupt(entry):
    if entry.get("type") != "user":
        return False
    content = (entry.get("message") or {}).get("content")
    return text_of(content).startswith(INTERRUPT)


def percentile(values, p):
    if not values:
        return None
    xs = sorted(values)
    k = (len(xs) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo), 2)


class Totals:
    def __init__(self):
        self.sessions = 0
        self.human_total = 0
        self.human_after_first = 0
        self.human_queued = 0
        self.interrupts = {"main": 0, "subagent": 0}
        self.denials = {name: {"main": 0, "subagent": 0} for name, _ in DENIALS}
        self.escapes = {"main": 0, "subagent": 0}
        self.xreview = {"dispatches": 0, "dispatch_failures": 0, "collects": 0, "collect_failures": 0}
        self.stretch_tools = []
        self.stretch_minutes = []


def settle_notification(body, pending_background, totals):
    """A background task's outcome: count the xreview call it was running if it failed."""
    task = TASK_ID_RE.search(body)
    verbs = pending_background.pop(task.group(1), ()) if task else ()
    if not verbs:
        return
    status = STATUS_RE.search(body)
    summary = SUMMARY_RE.search(body)
    codes = EXIT_CODE_RE.findall(summary.group(1)) if summary else []
    # "(exit code 0)" / "failed with exit code 3": the last one is the outcome
    if (status and status.group(1).strip() == "failed") or (codes and int(codes[-1]) != 0):
        for verb in verbs:
            key = "dispatch_failures" if verb == "dispatch" else "collect_failures"
            totals.xreview[key] += 1


def scan_file(path, scope, cutoff, totals):
    """One transcript. Returns True when it had any entry inside the window."""
    pending_xreview = {}            # tool_use id -> the xreview verbs that call ran
    pending_background = {}         # background task id -> the xreview verbs it is running
    seen = False
    humans = 0
    tools_since_human = 0
    last_human_ts = None
    last_agent_ts = None
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return False
    with fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            ts = parse_ts(entry.get("timestamp"))
            if ts is None or ts < cutoff:
                continue
            seen = True
            kind = entry.get("type")
            if kind == "assistant":
                last_agent_ts = ts
                for block in (entry.get("message") or {}).get("content") or []:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    tools_since_human += 1
                    inp = block.get("input") or {}
                    if block.get("name") != "Bash" or not isinstance(inp, dict):
                        continue
                    if inp.get("dangerouslyDisableSandbox"):
                        totals.escapes[scope] += 1
                    command = SINGLE_QUOTED.sub("''", inp.get("command") or "").strip()
                    verbs = set(XREVIEW_RE.findall(command))
                    for verb in verbs:
                        totals.xreview["dispatches" if verb == "dispatch" else "collects"] += 1
                    if verbs:
                        pending_xreview[block.get("id")] = verbs
                continue
            if kind == "user":
                content = (entry.get("message") or {}).get("content")
                if isinstance(content, list) and any(
                        isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
                    last_agent_ts = ts
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_result":
                            continue
                        verbs = pending_xreview.pop(block.get("tool_use_id"), ())
                        text = text_of(block.get("content"))
                        denied = None
                        if block.get("is_error"):
                            for name, rx in DENIAL_RES:
                                if rx.match(text):
                                    denied = name
                                    totals.denials[name][scope] += 1
                                    break
                        if not verbs or denied:
                            continue           # a refused call never ran: no failure
                        background = None if block.get("is_error") else BACKGROUND_ID_RE.search(text)
                        if background:
                            # the immediate result is a success either way; the outcome
                            # arrives later as a task notification
                            pending_background[background.group(1)] = verbs
                        elif block.get("is_error"):
                            for verb in verbs:
                                key = "dispatch_failures" if verb == "dispatch" else "collect_failures"
                                totals.xreview[key] += 1
                    continue
                body = text_of(content)
                if body.startswith(NOTIFICATION):
                    settle_notification(body, pending_background, totals)
                    continue
                if is_interrupt(entry):
                    totals.interrupts[scope] += 1
                    continue
            if kind == "attachment":
                # mid-turn the harness delivers a task notification as a queued_command
                # attachment whose text is in `prompt`; it is settled, never a human turn
                prompt = (entry.get("attachment") or {}).get("prompt")
                if isinstance(prompt, str) and prompt.startswith(NOTIFICATION):
                    settle_notification(prompt, pending_background, totals)
                    continue
            if scope == "main" and is_human(entry):
                totals.human_total += 1
                queued = kind == "attachment"
                if queued:
                    totals.human_queued += 1
                if humans > 0:
                    totals.human_after_first += 1
                    # The stretch a typed-ahead (queued) message interrupts is not over, so
                    # only a turn the agent actually waited for closes one.
                    if not queued and last_human_ts is not None:
                        totals.stretch_tools.append(tools_since_human)
                        end = last_agent_ts if last_agent_ts and last_agent_ts >= last_human_ts else last_human_ts
                        totals.stretch_minutes.append((end - last_human_ts) / 60.0)
                humans += 1
                if not queued:
                    tools_since_human = 0
                    last_human_ts = ts
    return seen


def measure(projects_dir, days, now=None):
    now = now if now is not None else datetime.datetime.now(datetime.timezone.utc).timestamp()
    cutoff = now - days * 86400
    totals = Totals()
    for project in sorted(os.listdir(projects_dir)):
        pdir = os.path.join(projects_dir, project)
        if not os.path.isdir(pdir):
            continue
        for name in sorted(os.listdir(pdir)):
            path = os.path.join(pdir, name)
            if not name.endswith(".jsonl") or not os.path.isfile(path):
                continue
            if os.path.getmtime(path) < cutoff:
                continue
            if scan_file(path, "main", cutoff, totals):
                totals.sessions += 1
            subdir = os.path.join(pdir, name[:-len(".jsonl")], "subagents")
            if os.path.isdir(subdir):
                for sub in sorted(os.listdir(subdir)):
                    spath = os.path.join(subdir, sub)
                    if sub.endswith(".jsonl") and os.path.getmtime(spath) >= cutoff:
                        scan_file(spath, "subagent", cutoff, totals)
    x = totals.xreview
    return {
        "window_days": days,
        "since": datetime.datetime.fromtimestamp(cutoff, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sessions": totals.sessions,
        "human_turns": {"total": totals.human_total, "after_first": totals.human_after_first,
                        "queued": totals.human_queued},
        "interrupts": totals.interrupts,
        "denials": totals.denials,
        "sandbox_escapes": totals.escapes,
        "xreview": dict(x, dispatch_failure_rate=(
            round(x["dispatch_failures"] / x["dispatches"], 3) if x["dispatches"] else None)),
        "autonomous_stretch": {
            "n": len(totals.stretch_tools),
            "tool_calls": {"median": percentile(totals.stretch_tools, 0.5),
                           "p90": percentile(totals.stretch_tools, 0.9)},
            "minutes": {"median": percentile(totals.stretch_minutes, 0.5),
                        "p90": percentile(totals.stretch_minutes, 0.9)},
        },
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--days", type=int, default=14, help="window size in days (default 14)")
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"),
                    help="Claude Code transcript root (default ~/.claude/projects)")
    args = ap.parse_args(argv)
    if args.days <= 0:
        ap.error("--days must be positive")
    if not os.path.isdir(args.projects_dir):
        ap.error("no such directory: " + args.projects_dir)
    json.dump(measure(args.projects_dir, args.days), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
