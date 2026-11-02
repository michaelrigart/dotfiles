"""snapshot: find the task-review subagents in Claude Code transcripts, group them per task, read their
fix ranges, measure what they cost, and copy their transcripts (and their controllers') into the state.

Transcript layout (see measure-interventions.py): <projects>/<project>/<session>.jsonl is a main
session; its subagents are <projects>/<project>/<session>/subagents/agent-<id>.jsonl with an
agent-<id>.meta.json beside each: {agentType, description, toolUseId, spawnDepth, parentAgentId?}.
A nested subagent sits flat in the same directory and names its controller in parentAgentId.

The projects directory is only ever read. The copies keep that layout under <state>/transcripts/.
"""
import collections
import hashlib
import json
import os
import re
import shutil

from process_replay import common as C

AGENT_TYPES = ("sp-reviewer", "sp-architect")
DESCRIPTION = re.compile(r"^(Re-review|Review)\s+(.*?)\s*Task\s+(\d+)\b")
SHA = r"([0-9a-fA-F]{7,40})"
_PROSE = re.compile(r"\bfix\s+base\s+`?" + SHA + r"`?\s*[,;]?\s*head\s+`?" + SHA + r"`?\b", re.I)
_DIFF = re.compile(r"\breview-" + SHA + r"\.\.\.?" + SHA + r"\.diff\b")
_VARS = re.compile(r"\b(?:FIX_)?BASE(?:_SHA)?\s*[=:]\s*`?" + SHA + r"`?\b(?:(?!\b(?:FIX_)?BASE(?:_SHA)?\s*[=:]).){0,300}?"
                   r"\bHEAD(?:_SHA)?\s*[=:]\s*`?" + SHA + r"`?\b", re.S)
_HEAD = re.compile(r"\bHEAD(?:_SHA)?\s*[=:]\s*`?" + SHA + r"`?\b")


def add_args(ap):
    pass


# ------------------------------------------------------------------ prompt parsing
def parse_ranges(text):
    """The (base, head) pairs a review prompt names: "Fix base A, head B", a diff file review-A..B.diff,
    FIX_BASE=A ... HEAD=B, or BASE_SHA: A ... HEAD_SHA: B. Lower case, each pair once, in order of
    appearance; SHAs of seven to forty hex digits."""
    found = []
    for rx in (_PROSE, _DIFF, _VARS):
        for m in rx.finditer(text or ""):
            found.append((m.start(), (m.group(1).lower(), m.group(2).lower())))
    out = []
    for _pos, pair in sorted(found, key=lambda f: f[0]):
        if pair not in out:
            out.append(pair)
    return out


def reviewed_head(prompt):
    """The head the review looked at: the last range's head, else a lone HEAD/HEAD_SHA, else None."""
    ranges = parse_ranges(prompt)
    if ranges:
        return ranges[-1][1]
    m = None
    for m in _HEAD.finditer(prompt or ""):
        pass
    return m.group(1).lower() if m else None


def _work_dir(gitdir):
    gitdir = gitdir.rstrip("/")
    if os.path.basename(gitdir) == ".git":
        return os.path.dirname(gitdir)
    return gitdir[:-4] if gitdir.endswith(".git") else gitdir


def repo_for_cwd(cwd, repos):
    """The git dir in `repos` whose work dir W has cwd == W, or cwd under W + "-" (a wt checkout) or
    W + "/" (a harness worktree). Longest W first, so repo-extra is not taken for repo. None when
    none matches; ~/Code/repox never matches ~/Code/repo."""
    if not cwd:
        return None
    cwd = cwd.rstrip("/") or "/"
    for work, repo in sorted(((_work_dir(r), r) for r in repos), key=lambda p: len(p[0]), reverse=True):
        if cwd == work or cwd.startswith(work + "-") or cwd.startswith(work + "/"):
            return repo
    return None


# ------------------------------------------------------------------ transcripts
def read_entries(path):
    """The JSON objects of a transcript, in order; lines that do not parse are skipped."""
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if isinstance(e, dict):
                    out.append(e)
    except OSError:
        pass
    return out


def _texts(content):
    if isinstance(content, str):
        return [content] if content.strip() else []
    out = []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str) and b["text"].strip():
                out.append(b["text"])
    return out


def _message(e):
    m = e.get("message")
    return m if isinstance(m, dict) else {}


def cost(path):
    """{tokens, start, end} of one transcript. A message streamed as several entries shares one
    message.id and counts once, by its last usage; tokens are input + output + cache creation +
    cache read; start and end are the first and last timestamps."""
    return _cost(read_entries(path))


def _cost(entries):
    usage = collections.OrderedDict()
    stamps = [e["timestamp"] for e in entries if isinstance(e.get("timestamp"), str)]
    for i, e in enumerate(entries):
        m = _message(e)
        if e.get("type") != "assistant" or not isinstance(m.get("usage"), dict):
            continue
        usage[m.get("id") or ("entry", i)] = m["usage"]
    total = 0
    for u in usage.values():
        for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
            v = u.get(k)
            total += v if isinstance(v, int) else 0
    return {"tokens": total, "start": stamps[0] if stamps else None, "end": stamps[-1] if stamps else None}


def _prompt(entries):
    for e in entries:
        if e.get("type") == "user":
            t = "\n".join(_texts(_message(e).get("content")))
            if t:
                return t
    return ""


def _report(entries):
    """The text of the last assistant message that has any; a message streamed over several entries
    contributes all of them."""
    by_id = collections.OrderedDict()
    for i, e in enumerate(entries):
        if e.get("type") != "assistant":
            continue
        m = _message(e)
        by_id.setdefault(m.get("id") or ("entry", i), []).extend(_texts(m.get("content")))
    for parts in reversed(list(by_id.values())):
        if parts:
            return "\n".join(parts)
    return ""


def _model(entries):
    for e in reversed(entries):
        m = _message(e)
        if e.get("type") == "assistant" and isinstance(m.get("model"), str) and not m["model"].startswith("<"):
            return m["model"]
    return None


def _cwd(entries):
    for e in entries:
        if isinstance(e.get("cwd"), str) and e["cwd"]:
            return e["cwd"]
    return None


# ------------------------------------------------------------------ discovery
def _listdir(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def _subagents(projects):
    """(project, session, agent id, meta) of every subagent with a readable meta.json, sorted."""
    for project in _listdir(projects):
        pdir = os.path.join(projects, project)
        for session in _listdir(pdir):
            sdir = os.path.join(pdir, session, "subagents")
            if not os.path.isdir(sdir):
                continue
            for name in _listdir(sdir):
                if not (name.startswith("agent-") and name.endswith(".meta.json")):
                    continue
                meta = C.jload(os.path.join(sdir, name))
                if isinstance(meta, dict):
                    yield project, session, name[len("agent-"):-len(".meta.json")], meta


def _task_review(meta):
    """(kind, prefix, task) when the subagent is a task review, else None."""
    if meta.get("agentType") not in AGENT_TYPES or not isinstance(meta.get("description"), str):
        return None
    m = DESCRIPTION.match(meta["description"])
    if not m:
        return None
    return ("re-review" if m.group(1) == "Re-review" else "review"), m.group(2).strip(), int(m.group(3))


def _agent_files(projects, project, session, aid):
    base = os.path.join(projects, project, session, "subagents", "agent-" + aid)
    return base + ".jsonl", base + ".meta.json"


def _controllers(projects, project, session, aid, meta):
    """The chain of controller ids above a subagent that have a transcript, nearest first."""
    chain, seen = [], {aid}
    parent = meta.get("parentAgentId")
    while isinstance(parent, str) and parent and parent not in seen:
        seen.add(parent)
        jsonl, mfile = _agent_files(projects, project, session, parent)
        if not os.path.isfile(jsonl):
            break
        chain.append(parent)
        up = C.jload(mfile)
        parent = up.get("parentAgentId") if isinstance(up, dict) else None
    return chain


def _group_id(project, session, prefix, task):
    return "g" + hashlib.sha1("\0".join((project, session, prefix, str(task))).encode("utf-8")).hexdigest()[:8]


def _copy(src, dest):
    """Copy keeping the mtime; a copy already there with the same size and mtime is left alone."""
    try:
        s, d = os.stat(src), os.stat(dest)
        if s.st_size == d.st_size and s.st_mtime_ns == d.st_mtime_ns:
            return
    except OSError:
        pass
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".tmp{}".format(os.getpid())
    shutil.copy2(src, tmp)
    os.replace(tmp, dest)


def find(projects, repos):
    """(groups, copies): every task review under `projects` grouped per (project, session, prefix,
    task), and the (source, relative destination) of every file to copy. No date filter."""
    grouped, copies = {}, {}
    for project, session, aid, meta in _subagents(projects):
        found = _task_review(meta)
        if not found:
            continue
        kind, prefix, task = found
        jsonl, mfile = _agent_files(projects, project, session, aid)
        if not os.path.isfile(jsonl):
            continue
        entries = read_entries(jsonl)
        prompt = _prompt(entries)
        ranges = parse_ranges(prompt)
        c = _cost(entries)
        dest = os.path.join("transcripts", project, session, "subagents", "agent-" + aid)
        for src, rel in ((jsonl, dest + ".jsonl"), (mfile, dest + ".meta.json")):
            copies[rel] = src
        for cid in _controllers(projects, project, session, aid, meta):
            cj, cm = _agent_files(projects, project, session, cid)
            cdest = os.path.join("transcripts", project, session, "subagents", "agent-" + cid)
            copies[cdest + ".jsonl"] = cj
            if os.path.isfile(cm):
                copies[cdest + ".meta.json"] = cm
        main = os.path.join(projects, project, session + ".jsonl")
        if os.path.isfile(main):
            copies[os.path.join("transcripts", project, session + ".jsonl")] = main
        grouped.setdefault((project, session, prefix, task), []).append({
            "agent": aid, "kind": kind, "description": meta["description"], "start": c["start"], "end": c["end"],
            "prompt": prompt, "report": _report(entries), "ranges": [list(r) for r in ranges],
            "reviewed_head": reviewed_head(prompt), "tokens": c["tokens"], "model": _model(entries),
            "transcript": dest + ".jsonl", "_cwd": _cwd(entries)})
    groups = []
    for (project, session, prefix, task), reviews in sorted(grouped.items()):
        reviews.sort(key=lambda r: (r["start"] or "", r["agent"]))
        cwd = next((r["_cwd"] for r in reviews if r["_cwd"]), None)
        if cwd is None:
            cwd = _cwd(read_entries(os.path.join(projects, project, session + ".jsonl")))
        for r in reviews:
            del r["_cwd"]
        groups.append({"id": _group_id(project, session, prefix, task), "project": project, "session": session,
                       "cwd": cwd, "repo": repo_for_cwd(cwd, repos), "prefix": prefix, "task": task, "reviews": reviews})
    return groups, copies


def cmd_snapshot(a):
    """Write <state>/reviews.json and copy the transcripts it names to <state>/transcripts/. Nothing
    is filtered by date: which branches count is decided by merge date, and a branch merged in
    October may have been reviewed in September. With --dry-run nothing is written."""
    repos = []
    for repo, _entries in C.XR.ledgers():
        if repo not in repos:
            repos.append(repo)
    groups, copies = find(a.projects_dir, repos)
    n = sum(len(g["reviews"]) for g in groups)
    sessions = len({(g["project"], g["session"]) for g in groups})
    unmapped = sum(1 for g in groups if g["repo"] is None)
    if a.dry_run:
        C.say("would snapshot {} task reviews in {} groups from {} sessions ({} files, {} groups without a repository)".format(
            n, len(groups), sessions, len(copies), unmapped))
        return 0
    for rel, src in sorted(copies.items()):
        _copy(src, os.path.join(a.state, rel))
    C.jsave(os.path.join(a.state, "reviews.json"), {"groups": groups})
    C.say("snapshot: {} task reviews in {} groups from {} sessions; {} files copied to {} ({} groups without a repository)".format(
        n, len(groups), sessions, len(copies), os.path.join(a.state, "transcripts"), unmapped))
    return 0
