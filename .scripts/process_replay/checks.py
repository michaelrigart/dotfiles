"""Build checks on an injected tree (spec 4.3; plan ruling R2): cheap and lexical, never a build, except `cargo check` for Rust.

One classifier, file_kind(name, first line), says what language a file is in: a shebang that names a known interpreter wins, else
the extension, else a path convention (a file under a zsh/functions directory is zsh). The syntax checks and the dangling-name
check both ask it, so a file is the same kind to both.

  coherent       bash -n, zsh -n, Python's ast, ruby -c or a JSON parse on each file a step changed. A file that is gone, a symlink
                 and a file of no known kind pass; so does one whose tool is not installed, but the tool is then named in `notes`.
  removed_names  the names a revert removes: defined by the lines the fix added and not by those it removed, where a line defines a
                 name only in a file of a kind in which that is a definition.
  dangling       a removed name that another tracked file (outside docs/superpowers and the files the step changed) still has as a
                 word. Lexical: a comment or a string that says the name counts.
  cargo_check    `cargo check --offline --all-targets`, with a target directory per repository.
"""
import json
import os
import re
import shutil
import subprocess
import sys

from . import common as C
from . import patches as P
from .common import Failed

CHECK_TIMEOUT = 60

_INTERPRETERS = {"bash": "bash", "sh": "bash", "dash": "bash", "ksh": "bash", "zsh": "zsh", "python": "python", "ruby": "ruby",
                 "node": "js", "nodejs": "js", "deno": "js", "bun": "js"}
_EXTENSIONS = {".sh": "bash", ".bash": "bash", ".zsh": "zsh", ".py": "python", ".rb": "ruby", ".json": "json", ".rs": "rust",
               ".js": "js", ".jsx": "js", ".mjs": "js", ".cjs": "js", ".ts": "js", ".tsx": "js"}


def _interpreter(line):
    """The kind a shebang line names (`#!/bin/sh`, `#!/usr/bin/env -S python3 -u`, `#!/usr/bin/ruby2.7`), or None."""
    if not line or not line.startswith("#!"):
        return None
    words = line[2:].split()
    if words and os.path.basename(words[0]) == "env":
        words = [w for w in words[1:] if not w.startswith("-") and "=" not in w]
    m = re.match(r"[a-z]+", os.path.basename(words[0])) if words else None
    return _INTERPRETERS.get(m.group(0)) if m else None


def file_kind(name, first_line=None):
    """The language of the file `name` (a path in the repository) whose first line is `first_line` (None when unknown): bash, zsh,
    python, ruby, json, rust, js, or None for anything else (TOML, YAML, INI, Markdown, plain text, ...)."""
    return (_interpreter(first_line) or _EXTENSIONS.get(os.path.splitext(name)[1])
            or ("zsh" if "/zsh/functions/" in "/" + name else None))


def first_line(path):
    """The first line of a regular file, or None (gone, a symlink, unreadable)."""
    if not os.path.isfile(path) or os.path.islink(path):
        return None
    try:
        with open(path, "rb") as f:
            return f.readline(200).decode("utf-8", "replace").rstrip("\r\n")
    except OSError:
        return None


# ------------------------------------------------------------------ syntax
def _run_check(argv, cwd, notes):
    try:
        p = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, timeout=CHECK_TIMEOUT)
    except FileNotFoundError:
        if notes is not None and "{} not found".format(argv[0]) not in notes:
            notes.append("{} not found".format(argv[0]))
        return True, ""
    except subprocess.TimeoutExpired:
        return False, "timed out"
    lines = p.stderr.decode("utf-8", "replace").strip().splitlines()
    return p.returncode == 0, lines[-1] if lines else ""


def coherent(work, files, notes=None):
    """(True, "") when every file of `files` (paths below `work`) that has a cheap syntax check passes it, else (False, "<path>: <why>")."""
    for name in sorted(files):
        path = os.path.join(work, name)
        line = first_line(path)
        if line is None:
            continue
        kind = file_kind(name, line)
        if kind in ("bash", "zsh"):
            good, why = _run_check([kind, "-n", path], work, notes)
        elif kind == "python":
            good, why = _run_check([shutil.which("python3") or sys.executable, "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", path],
                                   work, notes)
        elif kind == "ruby":
            good, why = _run_check(["ruby", "-c", path], work, notes)
        elif kind == "json":
            try:
                with open(path, "rb") as f:
                    json.loads(f.read().decode("utf-8"))
                good, why = True, ""
            except (ValueError, OSError) as e:
                good, why = False, str(e)
        else:
            continue
        if not good:
            return False, "{}: {}".format(name, why)
    return True, ""


# ------------------------------------------------------------------ names a revert removes
_SHELL_FN = (r"^\s*(?:export\s+)?function\s+([A-Za-z_][\w:-]*)", r"^\s*([A-Za-z_][\w-]*)\s*\(\)\s*\{?\s*$")
_DEFINES = {
    "bash": _SHELL_FN, "zsh": _SHELL_FN,
    "python": (r"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)", r"^\s*class\s+([A-Za-z_]\w*)", r"^([A-Za-z_]\w*)\s*=[^=]"),
    "ruby": (r"^\s*def\s+(?:self\.)?([A-Za-z_]\w*[?!]?)", r"^\s*class\s+([A-Za-z_]\w*)", r"^\s*module\s+([A-Za-z_]\w*)"),
    "rust": (r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+([A-Za-z_]\w*)",),
    "js": (r"^\s*(?:export\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)",
           r"^\s*(?:export\s+)?(?:(?:const|let|var)\s+)?([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\("),
}
_DEFINES = dict((k, [re.compile(x) for x in v]) for k, v in _DEFINES.items())


def _defined_by(lines, kind):
    out = set()
    for line in lines:
        for rx in _DEFINES.get(kind, ()):
            m = rx.match(line)
            if m:
                out.add(m.group(1))
    return out


def _line_one(sec):
    """Line 1 of a patch section's file after the change, when a hunk of the section starts there; else None."""
    for h in sec["hunks"]:
        if h["ns"] <= 1:
            for x in h["lines"]:
                if x[:1] in ("+", " "):
                    return x[1:]
            return None
    return None


def removed_names(patch, work=None):
    """The names a revert of `patch` (a fix) removes. Each file's kind comes from file_kind, fed the file's first line in `work` (the tree
    after the revert) when it is there, else line 1 as the patch shows it (a file the revert deletes: the fix added all of it)."""
    plus, minus = set(), set()
    try:
        sections = P.parse_patch(patch)
    except Failed:
        return []                                  # lines with no file header: no file kind, no definition
    for sec in sections:
        path = os.path.join(work, sec["file"]) if work else None
        line = first_line(path) if path and os.path.lexists(path) else _line_one(sec)
        kind = file_kind(sec["file"], line)
        for h in sec["hunks"]:
            plus |= _defined_by([x[1:] for x in h["lines"] if x.startswith("+")], kind)
            minus |= _defined_by([x[1:] for x in h["lines"] if x.startswith("-")], kind)
    return sorted(plus - minus)


def dangling(work, patch, files):
    """(True, "") unless a name the revert of `patch` removed (the revert is applied in `work`) is still used, as a word, by a tracked file
    it did not change, outside docs/superpowers: then (False, "<name> is still used by <file>")."""
    skip = [":(top,exclude)" + f for f in [P.DOCS] + list(files)]
    for name in removed_names(patch, work)[:50]:
        p = C.git_run(work, ["grep", "-l", "-w", "-F", "-I", "-e", name, "--", ":(top)"] + skip)
        if p.returncode == 0:
            return False, "{} is still used by {}".format(name, p.stdout.decode("utf-8", "replace").split("\n")[0])
    return True, ""


# ------------------------------------------------------------------ cargo
def cargo_check(a, work, repo_name):
    """(passed, why) of `cargo check --offline --all-targets` in `work`: passed is True, False, or None when it did not finish within
    the budget (`a.budget`, 3600 s); None when cargo is not installed."""
    env = dict(os.environ, CARGO_TARGET_DIR=os.path.join(a.state, "cargo", repo_name))
    budget = getattr(a, "budget", 3600)
    try:
        p = subprocess.run(["cargo", "check", "--offline", "--all-targets"], cwd=work, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                           timeout=budget)
    except FileNotFoundError:
        return None
    except subprocess.TimeoutExpired:
        return None, "cargo check did not finish within {} s".format(budget)
    tail = p.stderr.decode("utf-8", "replace").strip().splitlines()[-3:]
    return p.returncode == 0, "cargo check failed: " + " | ".join(x.strip() for x in tail)
