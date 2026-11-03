"""The final whole-branch review of a replay run (spec 4.4, 7.1): its brief, its staging, finding its transcript and scanning
that transcript, and the subagents it ran, for reads of anything it must not see.

The brief is the prompt of requesting-code-review/code-reviewer.md (PROCESS_REPLAY_SUPERPOWERS when set, tests; else the newest
superpowers version under ~/.claude/plugins/cache) for the scratch's range, then the review package (review-package, run in the
scratch), the scratch path and `Review id: <label>`. It is staged in the run's item directory (common.item_dir: brief.md and
package.diff, and the answer.md the driver writes there); the state keeps a copy of the brief as the marker `pending` lists.
The driving session hands the reviewer the staged brief's path or its text; the reviewer's transcript is the one whose first
prompt holds the `Review id:` line or that path.

The leak scan reads the reviewer's tool calls (Bash commands, Read/Grep/Glob paths) with codex.py's matcher, so one matcher
rules Codex and Claude. It forbids the original checkouts, the state (real and aliased paths) and every other staged item.
"""
import glob
import json
import os
import re
import subprocess

from . import codex as K
from . import common as C
from .common import Failed, jload, jsave


class PlanError(Failed):
    """The branch's plan cannot be told: the run has no final review brief."""


# ------------------------------------------------------------------ the brief
def _version(path):
    return [int(x) for x in re.findall(r"\d+", re.search(r"/superpowers/([^/]+)/skills/", path).group(1))]


def superpowers_root():
    """The superpowers version directory: PROCESS_REPLAY_SUPERPOWERS (tests), else the newest under ~/.claude/plugins/cache."""
    env = os.environ.get("PROCESS_REPLAY_SUPERPOWERS")
    if env:
        return env
    found = glob.glob(os.path.join(glob.escape(os.path.expanduser("~/.claude/plugins/cache")), "*", "superpowers", "*", "skills",
                                   "requesting-code-review", "code-reviewer.md"))
    if not found:
        raise Failed("no superpowers skills under ~/.claude/plugins/cache (set PROCESS_REPLAY_SUPERPOWERS)")
    return max(found, key=_version).split("/skills/")[0]


def prompt_of(template):
    """The prompt of code-reviewer.md: the fenced block's `prompt: |` body, dedented. The whole file if it has none."""
    lines = template.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"\s*prompt:\s*\|\s*\Z", line):
            body = []
            for x in lines[i + 1:]:
                if x == "```":
                    break
                body.append(x[4:] if x.startswith("    ") else x)
            return "\n".join(body).strip("\n") + "\n"
    return template


def plan_path(a, run, branch):
    """The plan file the branch changed in base..tip, in the scratch. Several: the one the branch's plan commit changed. Failed
    when it is still not one file."""
    sd = run["scratch"]
    names = [n for n in C.git(sd, "diff", "--name-only", branch["base"], "HEAD", "--", "docs/superpowers/plans").splitlines() if n.endswith(".md")]
    if len(names) > 1 and branch.get("plan_commit"):
        try:
            view = C.view(a.state, branch["repo"], a.snapshot_root)
            changed = set(C.git(view, "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", branch["plan_commit"]).splitlines())
            names = [n for n in names if n in changed] or names
        except Failed:
            pass
    if len(names) != 1:
        raise PlanError("the plan is {} (the branch changes {})".format("ambiguous" if names else "missing", ", ".join(names) or "no plan under docs/superpowers/plans"))
    return os.path.join(sd, names[0])


def write_brief(a, run, branch):
    """The staged brief and package of run's final review, then the state's copy of the brief."""
    root = superpowers_root()
    sd, jid = run["scratch"], run["label"]
    with open(os.path.join(root, "skills", "requesting-code-review", "code-reviewer.md"), encoding="utf-8") as f:
        text = prompt_of(f.read())
    tip = C.git(sd, "rev-parse", "HEAD")
    plan = plan_path(a, run, branch)
    d = C.item_dir(a.state, "final", jid)
    package = os.path.join(d, "package.diff")
    p = subprocess.run(["bash", os.path.join(root, "skills", "subagent-driven-development", "scripts", "review-package"), plan, branch["base"], tip, package],
                       cwd=sd, capture_output=True, env=C.git_env())
    if p.returncode != 0:
        raise Failed("review-package failed ({}): {}".format(p.returncode, p.stderr.decode("utf-8", "replace").strip()))
    for key, value in (("[DESCRIPTION]", "The change on {}.".format(branch["branch"])), ("[PLAN_OR_REQUIREMENTS]", plan),
                       ("[BASE_SHA]", branch["base"]), ("[HEAD_SHA]", tip)):
        text = text.replace(key, value)
    text += "\nReview package (read it first): {}\nRepository: {}\nReview id: {}\n".format(package, sd, jid)
    jsave(os.path.join(d, "brief.md"), text)
    jsave(os.path.join(a.state, "final", jid, "brief.md"), text)


def answer(a, jid):
    """The text of the final review's answer.md (collected from its staged directory), or None."""
    path = C.collect_final(a.state, jid)
    if path is None:
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


# ------------------------------------------------------------------ its transcript
def _key():
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(os.path.expanduser("~/Code/.replay")))


def _first_prompt(path):
    """The text of the first user message of a Claude transcript."""
    try:
        with open(path, "rb") as f:
            for line in f:
                if b'"user"' not in line:
                    continue
                try:
                    rec = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                if rec.get("type") != "user":
                    continue
                content = (rec.get("message") or {}).get("content")
                if isinstance(content, list):
                    content = "\n".join(x.get("text", "") for x in content if isinstance(x, dict))
                return content if isinstance(content, str) else ""
    except OSError:
        pass
    return ""


def transcripts(a, jid):
    """The transcripts, under the projects of ~/Code/.replay, whose first prompt carries the line `Review id: <jid>` or the
    path of the review's staged brief (a driver hands a reviewer its brief by path)."""
    key, found = _key(), []
    try:
        names = sorted(os.listdir(a.projects_dir))
    except OSError:
        return found
    line = re.compile(r"^Review id: " + re.escape(jid) + r"\s*$", re.M)
    brief = os.path.join(C.item_dir(a.state, "final", jid), "brief.md")
    for name in names:
        if name != key and not name.startswith(key + "-"):
            continue
        root = os.path.join(a.projects_dir, name)
        for path in sorted(glob.glob(os.path.join(glob.escape(root), "**", "*.jsonl"), recursive=True)):
            first = _first_prompt(path)
            if line.search(first) or brief in first:
                found.append(path)
    return found


def overrides(a):
    """{review id: transcript path} of --transcript ID=PATH."""
    out = {}
    for item in getattr(a, "transcript", None) or []:
        jid, sep, path = item.partition("=")
        if not (sep and jid and path):
            raise Failed("--transcript wants ID=PATH, not {!r}".format(item))
        out[jid] = os.path.abspath(os.path.expanduser(path))
    return out


def lookup(a, jid):
    """([transcript], None) when exactly one is known, else ([], what to tell the operator): none, several (never picked), or a
    --transcript that is not a file."""
    given = overrides(a).get(jid)
    if given:
        if os.path.isfile(given):
            return [given], None
        return [], "final review {}: --transcript names {}, which is not a file".format(jid, given)
    found = transcripts(a, jid)
    if not found:
        return [], ("final review {}: its answer is in, but no transcript with `Review id: {}` or its staged brief path was found under {}; "
                    "point at it with `match --transcript {}=<path>`; it is not accepted until then".format(jid, jid, a.projects_dir, jid))
    if len(found) > 1:
        return [], ("final review {}: {} transcripts match ({}); none is picked: name the right one with `match --transcript {}=<path>`".format(
            jid, len(found), ", ".join(found), jid))
    return found, None


# ------------------------------------------------------------------ the leak scan
def descendants(path):
    """The transcripts of the subagents a transcript ran. For a subagent's: those beside it whose parentAgentId chain leads to
    it. For a session's own file (`<session>.jsonl`): every transcript in `<session>/subagents/`."""
    m = re.search(r"agent-([^/]+)\.jsonl\Z", path)
    d = os.path.dirname(path)
    if not m or os.path.basename(d) != "subagents":
        if path.endswith(".jsonl") and not os.path.basename(d) == "subagents":
            return sorted(glob.glob(os.path.join(glob.escape(path[:-len(".jsonl")]), "subagents", "agent-*.jsonl")))
        return []
    aid = m.group(1)
    parent = {}
    for meta in glob.glob(os.path.join(glob.escape(d), "agent-*.meta.json")):
        doc = jload(meta)
        parent[os.path.basename(meta)[len("agent-"):-len(".meta.json")]] = doc.get("parentAgentId") if isinstance(doc, dict) else None
    out = []
    for child in sorted(parent):
        seen, up = {child}, parent[child]
        while isinstance(up, str) and up and up not in seen:
            if up == aid:
                mine = os.path.join(d, "agent-{}.jsonl".format(child))
                if os.path.isfile(mine):
                    out.append(mine)
                break
            seen.add(up)
            up = parent.get(up)
    return out


walled_leaks = K.walled_leaks


def session_dir(path):
    """The directory Claude Code keeps a transcript's session in: <project>/<session>/ holds its subagents/ and the tool-results/ it
    saves large tool outputs to, which the agent reads back."""
    if os.path.basename(os.path.dirname(path)) == "subagents":
        return os.path.dirname(os.path.dirname(path))
    return path[:-len(".jsonl")] if path.endswith(".jsonl") else path


_unspell = K.unspell


def transcript_leaks(path, forbidden, cwd, walled=None, exempt=()):
    """The forbidden paths a transcript's tool calls name (Bash commands, Read/Grep/Glob paths), by codex.py's matcher, and, with
    `walled` = (review-work directory, [allowed directories]), anything under review-work that is not allowed. A path inside a
    directory of `exempt` (the reviewer's own session) is not read for the first."""
    found = set()
    with open(path, "rb") as f:
        for line in f:
            if b"tool_use" not in line:
                continue
            try:
                rec = json.loads(line.decode("utf-8"))
            except ValueError:
                continue
            content = (rec.get("message") or {}).get("content") if isinstance(rec, dict) else None
            for item in content if isinstance(content, list) else []:
                if not (isinstance(item, dict) and item.get("type") == "tool_use" and isinstance(item.get("input"), dict)):
                    continue
                inp = item["input"]
                parts = [inp[k] for k in ("command", "file_path", "path", "notebook_path") if isinstance(inp.get(k), str)]
                if item.get("name") == "Glob" and isinstance(inp.get("pattern"), str):
                    parts.append(inp["pattern"])
                commands = [inp["command"]] if isinstance(inp.get("command"), str) else []
                for name in K.named(_unspell("\n".join(parts), exempt), rec.get("cwd") or cwd, forbidden, commands):
                    found.add(name)
                if walled:
                    found |= walled_leaks("\n".join(parts), rec.get("cwd") or cwd, walled[0], walled[1])
    return sorted(found)


def leaks(a, run, branch, path):
    """What the reviewer's transcript `path` and its subagents' name that they must not (codex.forbidden)."""
    paths, walled = K.forbidden(a.state, branch, [C.item_dir(a.state, "final", run["label"]), run["scratch"]], getattr(a, "snapshot_root", None))
    forbidden = K.forbidden_paths(paths, walled[1])
    mine = [path] + descendants(path)
    exempt = sorted(set(session_dir(p) for p in mine))      # its own saved tool results; another session's files stay forbidden
    return sorted(set(x for p in mine for x in transcript_leaks(p, forbidden, run["scratch"], walled, exempt)))
