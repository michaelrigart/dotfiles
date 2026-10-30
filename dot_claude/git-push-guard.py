#!/usr/bin/env python3
# Rule 4 of git-forge-guard.sh: the push gate. Design: section 1.1 of
# docs/superpowers/specs/2026-09-30-safe-autonomy-design.md.
#
# Reads the PreToolUse payload on stdin. Prints ONE hookSpecificOutput object when a push
# must ask or be denied, and nothing when the command may go ahead.
#
# It judges a push only when the WHOLE command is a plain push, by this grammar over the
# shlex tokens (nothing else may be left over):
#
#   [cd <literal path> (&& | ;)]
#   [VAR=value ...]
#   [command | sudo | env [VAR=value ...]]        no options on sudo or env
#   git [allowlisted global options]              -C <path>, --no-pager, ...
#   push | <an alias that expands to push>
#   [allowlisted push options] [<remote> [<refspec> ...]]
#   [2>&1] [| tail|head [-n N | -N]]              a read-only output tail, nothing else
#
# No token may hold a $( ) or backtick substitution other than the three current-branch
# forms, and no token may begin with # (a comment, or a quoted '#...' literal: both are
# outside the grammar). A single git command of the same shape that does not push is left
# alone. Any other command that could run git push (git and push in its text, or git and a
# push alias) is a silent deny asking for the push as a plain command. could_push reads the
# command text as a superset, except that the arguments of provably inert commands (rg, cat,
# echo, git commit, ...: see inert_text) are data and do not count, so a commit message or a
# file name that mentions a push is no push. Nothing else is parsed: no control structures,
# subshells, heredocs, evaluators or chains.
#
# Fail direction: a push this cannot resolve is DENIED with a reason the agent can act on.
# It never asks on doubt (an ask costs Michael a prompt) and never allows on doubt (a push
# is the one irreversible outward path).
#
# Threat model: rule 4 covers the commands an agent plausibly writes, accidents included.
# Deliberate obfuscation is out of scope, because a text-matching hook cannot close it (a
# script file always gets round it); the auto-mode classifier and server-side branch
# protection cover it. For example a push word assembled by expansion (git ${X:-pu}sh) has
# no literal push in the payload, so the shell fast path never starts this helper.
#
# Merged-branch deletes (spec 2026-10-28-reload-functions-merged-deletes, section 2). A
# classifier rule (autoMode.allow in dot_claude/modify_private_settings.json) lets the
# auto-mode classifier allow the plain pinned delete of a merged branch, trusting this guard
# to have verified the merge and the pin. So the words verified must be the words the shell
# runs: a delete-only push of merged branches, each pinned, passes silently only as a bare
# git push in canonical text (plain words, see CANONICAL), which bash and zsh hand git
# unchanged, with no wrapper, assignment, cd prefix or global option before push. Merged and
# pinned in any other text, it is denied with the plain pinned command printed. A deny that
# prints a corrected push prints the plain git push form when the push runs in the session's
# own checkout (the toplevel of the payload's cwd); otherwise it names the checkout the push
# runs in and says the push must run from there or Michael runs it, since the classifier
# rule names only the plain form.
#
# Glob command words (spec section 7). A command word that a shell could expand to git or a
# git-* name is read as a possible git: the span from the first [ that has a later ] through the
# last ] is any characters, and so is an in-word (...) group, which zsh reads as an alternation
# (glue_paren_groups); the rest is matched against the four names. Only a word made of * alone is
# exempt (a case arm, a markdown bullet), judged on the raw word. Assumed: the shells are bash,
# sh and zsh -f with nobareglobqual and without extendedglob or kshglob, so #, ^ and ~ patterns
# (extendedglob) and *(...) forms (kshglob) are out of scope.
#
# Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from bisect import bisect_left, bisect_right
from collections import namedtuple

# Claude Code treats a hook that outruns its timeout as non-blocking, so a slow helper
# would let the push through. The helper therefore gives up first, and a give-up is a
# deny: no single git call may take more than CALL_TIMEOUT, and the whole run may not
# take more than BUDGET. PUSH_GUARD_BUDGET exists only so the test suite can shorten it.
START = time.monotonic()
CALL_TIMEOUT = 5.0
try:
    BUDGET = float(os.environ.get("PUSH_GUARD_BUDGET", "30"))
except ValueError:
    BUDGET = 30.0
# Environment for the object lookups that must stay local: lazy fetch off, so a remote that
# config marks a promisor is never asked for a missing object (that would run its
# uploadpack, vcs and credential settings, unsandboxed). Replacement objects, grafts and the
# commit-graph are off too (LOCAL_OPTS carries the last): each is local state the sandbox can
# write, and each can make an unmerged branch look like an ancestor of the default branch.
LOCAL_ENV = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_NO_REPLACE_OBJECTS="1",
                 GIT_GRAFT_FILE=os.devnull)
LOCAL_OPTS = ("-c", "core.commitGraph=false")

PUNCT =";&|()<>\n"
# Canonical text (spec 2026-10-28, section 2, canonical text), the only text in which a merged,
# pinned delete passes silently: the raw command, with at most one trailing newline removed
# and then its leading and trailing spaces stripped (canonical), is git push and its arguments
# separated by single spaces, then at most one trailer (2>&1, a tail or head with -n N or -N,
# or both). Every argument is one plain word that no shell option rewrites (SHELL_REWRITES). An
# allowlist of the shell surface, not a denylist: bash and zsh hand git exactly these words
# (differential check and option survey recorded in tests/git-forge-guard.test.sh).
PLAIN_WORD = "[A-Za-z0-9._/:=@+,%-]+"
CANONICAL = re.compile("git push((?: " + PLAIN_WORD + ")*)(?: 2>&1)?(?: \\| (?:tail|head) (?:-n [0-9]+|-[0-9]+))?")
# The plain words a shell option still rewrites, by the survey of every zsh and bash option over
# the plain-word alphabet: one starting with = (zsh EQUALS: =ls is /bin/ls), one holding == or
# := (zsh MAGIC_EQUAL_SUBST: x==ls is x=/bin/ls, a=b:=ls is a=b:/bin/ls), and one shaped NAME=
# or NAME+= (bash set -k moves it into the environment, so git never sees it). canonical()
# refuses such a word, and shell_word() quotes it.
SHELL_REWRITES = re.compile(r"^=|==|:=|^[A-Za-z_][A-Za-z0-9_]*\+?=")
PLAIN_WORDS = ("plain words: git push and its arguments, each made of letters, digits and "
               "._/:=@+,%- (none starting with =, holding == or :=, or shaped NAME= or NAME+=), "
               "separated by single spaces, nothing before git, and at most 2>&1 and "
               "| tail or | head with -n N or -N after")
# The opening of every deny for a dry run outside canonical text.
DRY_REFUSED = "Push guard: this dry run is refused because it is not written in " + PLAIN_WORDS + "."
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Could this text run git push? git, then push (or a push alias), within one command.
PUSH_SHAPE = re.compile(r"\bgit\b[^;&|\n]*\bpush\b")
TAILS = {"tail", "head"}
# An alias whose value names one of these may push (http-push contains push): it is a push
# candidate, and judge decides on what it expands to. The shell fast path keeps the same list.
PUSHY_ALIAS = re.compile(r"push|send-pack")
# A refspec written as the current branch through a command substitution; anything else
# carrying $ or a backtick is a value the guard cannot know.
CURRENT_BRANCH = {"$(git branch --show-current)", "$(git rev-parse --abbrev-ref HEAD)",
                  "$(git symbolic-ref --short HEAD)"}

# git global options this parser recognises. -C moves the working directory and resolves
# correctly; every other repository or configuration selector is unsupported on a push,
# and so is any option not listed here (git rejects attached forms such as -C<path>).
GIT_FLAGS = {"-p", "-P", "--paginate", "--no-pager", "--bare", "--no-replace-objects",
             "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
             "--icase-pathspecs", "--no-optional-locks", "--no-advice", "--no-lazy-fetch"}
GIT_LONG_OPTS_WITH_VALUE = {"--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"}
GIT_CONFIG_OPTS = {"-c", "--config-env"}
# Environment assignments that select a repository or inject configuration.
GIT_ENV_UNSUPPORTED = re.compile(r"^(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_NAMESPACE|GIT_CONFIG.*)$")
# Builtins cannot be aliased, so these never need an alias lookup.
GIT_BUILTINS = {
    "add", "am", "apply", "bisect", "blame", "branch", "cat-file", "checkout", "cherry-pick",
    "clean", "clone", "commit", "config", "describe", "diff", "fetch", "for-each-ref",
    "format-patch", "gc", "grep", "help", "init", "log", "ls-files", "ls-remote", "merge",
    "merge-base", "mv", "name-rev", "notes", "pull", "range-diff", "rebase", "reflog",
    "remote", "reset", "restore", "rev-list", "rev-parse", "revert", "rm", "shortlog", "show",
    "show-ref", "sparse-checkout", "stash", "status", "submodule", "switch", "symbolic-ref",
    "tag", "update-ref", "var", "version", "worktree",
}
# The git push options this guard models. Every other option is a silent deny naming it,
# every --no-* negation included (--no-dry-run turns a dry run into a real push); the one
# allowed negation is --no-verify, which only skips local hooks.
PUSH_LONG = {"--set-upstream", "--force-with-lease", "--force-if-includes", "--force", "--tags",
             "--follow-tags", "--all", "--mirror", "--delete", "--prune", "--dry-run", "--quiet",
             "--verbose", "--progress", "--porcelain", "--atomic", "--push-option", "--no-verify"}
PUSH_LONG_WITH_VALUE = {"--force-with-lease", "--push-option"}    # --x=value accepted
PUSH_SHORT = set("ufdnqv")                                        # plus -o <value>
# The push option values (-o, --push-option, push.pushOption) the guard lets through; GitLab
# reads them. Every other value is refused, merge_request.* above all: it creates or
# auto-merges an MR from the push, past the pre-merge review gate on glab mr create.
PUSH_OPTIONS_OK = re.compile(r"ci\.skip|integrations\.skip_ci|ci\.variable=.*", re.S)

# Subcommands that push without being git push: always refused. Any other subcommand that
# is not a builtin and is given the word push (subtree, lfs, ...) is refused as well.
PUSHING_SUBCOMMANDS = {"send-pack", "http-push"}
# A refspec destination that git resolves as a ref path rather than a branch name.
DWIM_PREFIXES = ("heads/", "tags/", "remotes/", "refs/")
# A delete-only push of merged branches needs no ask once each delete is pinned to the tip
# the guard read (spec 2026-10-16, section 4). A push carrying one of these flags updates,
# prunes or force-pushes more than the branches it names, so it is never delete-only.
NOT_DELETE_ONLY = {"--prune", "--mirror", "--all", "--force", "-f", "--tags", "--follow-tags"}
SHA_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")

UNSUPPORTED = ("unsupported push configuration for the push guard: {}; "
               "push by hand or simplify the configuration")
GITLEAKS_LEAKS_EXIT = 99
# gitleaks parses `git log -p` output, and log formatting config breaks the parse. Under
# Michael's own format.pretty it reported "0 commits scanned" and findings with no commit,
# so no commit-bound fingerprint. These pin git's default output for the scan alone.
GIT_LOG_DEFAULTS = [("format.pretty", "medium"), ("log.showSignature", "false"),
                    ("log.abbrevCommit", "false"), ("diff.noprefix", "false"),
                    ("diff.mnemonicPrefix", "false"), ("color.ui", "false"),
                    ("color.diff", "false"),
                    # diff.submodule=diff starts a child diff inside a bumped submodule, which
                    # has no --no-ext-diff of its own: its diff.external and textconv would run
                    ("diff.submodule", "short"),
                    # past this size git prints "Binary files differ" for a text file
                    ("core.bigFileThreshold", "2g")]
# The scan reads a merge as the diff against what git would merge by itself (remerge), so a
# secret added while committing a merge is seen; git log -p shows a merge with no diff.
MERGE_DIFF = "--diff-merges=remerge"
# Options that make `git log -p` show every added line: a root commit, a file marked binary
# or -diff by .gitattributes or .git/info/attributes, a textconv or external diff driver.
# --submodule=short keeps a bumped gitlink a one-line patch: under diff.submodule=diff git
# runs a child diff in the submodule, whose own configuration then runs its drivers.
PATCH_OPTS = ["--root", "--text", "--no-textconv", "--no-ext-diff", "--submodule=short",
              MERGE_DIFF]
# The file that changes what gitleaks reports. Only a committed one is a reviewed exception.
EXCEPTION_FILES = [".gitleaksignore"]
# A gitleaks config, in any extension or letter case. gitleaks reads one from the directory
# it scans (.gitleaks.toml, then any .gitleaks.<ext> viper finds beside it), and a config can
# extend another file, so the guard supports none: the scan always runs the default rules.
GITLEAKS_CONFIG_RE = re.compile(r"\.gitleaks\..*", re.I)
SCANNED_RE = re.compile(r"\b(\d+) commits? scanned\b")
ERR_RE = re.compile(r"^\S+\s+ERR\b", re.M)
PLAIN = ("Push guard: this command may run git push in a shape the guard does not check. Run "
         "the push as a plain command of its own: git push [options] <remote> <branch> "
         "(for another repository: git -C <path> push [options] <remote> <branch>; piped only "
         "to tail or head). If the command does not push, keep git and push apart in its text "
         "with a bracket, for example rg 'git pu[s]h'; a word split by quotes or backslashes is "
         "read as a hidden push.")


TIMED_OUT = "Push guard: the push check timed out, so the push is refused. Retry the push."


class Deny(Exception):
    """A push that must be refused, carrying the reason the agent reads."""


def decision(kind, reason):
    # Compact separators: the shell side matches "permissionDecision":"ask" literally.
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": kind,
        "permissionDecisionReason": reason,
    }}, separators=(",", ":"))


# ------------------------------------------------------------------ the grammar
GLUE_STOP = " \t\r\n;&|()<>`$=\\"
GLUE_BAD = set(" \t\r\n;&<>")
GLUE_MAX = 256                      # a longer group is no realistic alternation; keeps it linear


def glue_paren_groups(text):
    """text with every in-word (...) group rewritten as [*...*] of the same length. zsh reads
    word(a|b)word as an alternation (with bareglobqual and extendedglob off), so the group is a
    glob, but the tokenizers split a word at ( and ), which would lose it. A group opens
    glued to the word before it or to a group just before it (not after whitespace, an operator,
    $, = or a backtick: those start a subshell, a substitution or an array), is not empty
    (name() defines a function), holds no blank, newline, ; & < or > (so a subshell, a call that
    spans lines or a redirect is never swallowed), balances, and is at most GLUE_MAX characters
    long. Quotes are skipped, so a quoted ( stays literal. One linear pass with a stack; the
    length is kept, so spans into the original text stay valid."""
    if "(" not in text:
        return text
    n, i, prev_end, open_groups = len(text), 0, -1, 0
    stack, groups = [], []
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'" or (c == "$" and text[i + 1:i + 2] == "'"):
            ansi = c == "$"
            i += 2 if ansi else 1
            while i < n and text[i] != "'":
                i += 2 if (ansi and text[i] == "\\") else 1
        elif c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c in GLUE_BAD:
            stack, open_groups = [], 0
        elif c == "(":
            glued = i > 0 and (text[i - 1] not in GLUE_STOP or prev_end == i) \
                and text[i + 1:i + 2] != ")"
            stack.append((i, glued))
            open_groups += glued
        elif c == ")" and stack:
            start, glued = stack.pop()
            if glued:
                open_groups -= 1
                if open_groups == 0 and i - start < GLUE_MAX:
                    groups.append((start, i + 1))
                    prev_end = i + 1
        i += 1
    if not groups:
        return text
    out, last = [], 0
    for start, end in groups:
        out.append(text[last:start])
        out.append("[" + "*" * (end - start - 2) + "]")
        last = end
    out.append(text[last:])
    return "".join(out)


def tokenize(cmd):
    """Shell words and operator tokens. Raises ValueError on unbalanced quotes."""
    lx = shlex.shlex(glue_paren_groups(cmd.replace("\\\n", " ")), posix=True,
                     punctuation_chars=PUNCT)
    lx.whitespace = " \t\r"          # a newline separates commands; it is not a blank
    lx.whitespace_split = True
    lx.commenters = ""
    return list(lx)


def is_operator(tok):
    return bool(tok) and all(c in PUNCT for c in tok)


def substitutes(tok):
    return ("$(" in tok or "`" in tok) and tok not in CURRENT_BRANCH


def dynamic(word, dollar=True, star=True):
    """Does the shell rewrite this word before git sees it (a variable, a substitution, a
    brace list, a glob)? The guard reads the literal text, so such a word may run as
    another command or name another ref. dollar=False lets a $ through: the value of -C is
    expanded by this guard itself, and one it cannot expand fails the repository lookup.
    A word holding whitespace was quoted, so its braces and globs stay literal."""
    if "`" in word or (dollar and "$" in word):
        return True
    if any(c.isspace() for c in word):
        return False
    return any(c in word for c in ("{}?[*" if star else "{}?["))


def parse_plain(tokens, cwd):
    """The one git invocation of a plain command, as the grammar in the header allows it,
    as a dict; or None when the command is anything else."""
    t = list(tokens)
    while t and t[-1] == "\n":
        t.pop()
    n, i, cd_used = len(t), 0, False
    if any(substitutes(x) or x.startswith("#") for x in t):
        return None
    if n >= 3 and t[0] == "cd" and t[2] in ("&&", ";") and not is_operator(t[1]):
        target = os.path.expanduser(t[1])
        if "$" in target or target == "-":
            return None
        cwd, cd_used, i = os.path.normpath(os.path.join(cwd, target)), True, 3
    assigns = []
    while i < n and ASSIGN_RE.match(t[i]):
        assigns.append(t[i].split("=", 1)[0])
        i += 1
    if i < n and t[i] in ("command", "sudo"):
        i += 1
    elif i < n and t[i] == "env":
        i += 1
        while i < n and ASSIGN_RE.match(t[i]):
            assigns.append(t[i].split("=", 1)[0])
            i += 1
    if i >= n or os.path.basename(t[i]) != "git":
        return None
    i += 1
    repo_opts, config_opts, unknown = [], [], []
    while i < n and t[i].startswith("-") and not is_operator(t[i]):
        w = t[i]
        name = w.split("=", 1)[0]
        if w in ("-C", "-c") or (name in GIT_LONG_OPTS_WITH_VALUE and "=" not in w):
            if i + 1 >= n or is_operator(t[i + 1]):
                return None
            if dynamic(w) or dynamic(t[i + 1], dollar=(w != "-C")):
                return None
            opt, i = [w, t[i + 1]], i + 2
        elif name in GIT_LONG_OPTS_WITH_VALUE:
            if dynamic(w):
                return None
            opt, i = [w], i + 1
        else:
            if dynamic(w):
                return None
            if w not in GIT_FLAGS and not w.startswith("--exec-path"):
                unknown.append(w)
            i += 1
            continue
        if name in GIT_CONFIG_OPTS:
            config_opts.extend(opt)
        else:
            # ~ and $HOME are expanded as the shell would; a value still holding $ names
            # a variable only the shell knows, and git -C resolves it to nothing.
            repo_opts.extend(os.path.expanduser(os.path.expandvars(x)) for x in opt)
    if i >= n or is_operator(t[i]):
        return None
    if dynamic(t[i]):
        return None                                    # git ${X:-push} origin main
    sub, args, i = t[i], [], i + 1
    while i < n and not is_operator(t[i]) and t[i:i + 3] != ["2", ">&", "1"]:
        args.append(t[i])
        i += 1
    if t[i:i + 3] == ["2", ">&", "1"]:
        i += 3
    if i < n and t[i] == "|":
        if i + 1 >= n or t[i + 1] not in TAILS:
            return None
        i += 2
        if i + 1 < n and t[i] == "-n" and t[i + 1].isdigit():
            i += 2
        elif i < n and re.match(r"^-[0-9]+$", t[i]):
            i += 1
    if i != n:
        return None
    return {"cwd": cwd, "cd_used": cd_used, "assigns": assigns, "repo_opts": repo_opts,
            "config_opts": config_opts, "unknown": unknown, "sub": sub, "args": args}


# ------------------------------------------------------------------ git queries
class Repo:
    def __init__(self, cwd, repo_opts):
        self.base = ["git", "-C", cwd] + list(repo_opts)

    def run(self, *args, env=None, long=False, raw=False):
        """stdout of a git query, or None when git fails. env replaces the environment; long
        lifts the per-call limit to what is left of the budget (a patch listing of a large
        push). Output is decoded leniently: git can print any bytes. raw returns the bytes as
        git wrote them, for a patch listing: text mode also turns every CR into a line break.
        Lazy fetch is always off (GIT_NO_LAZY_FETCH): a promisor remote that config names
        would otherwise run its uploadpack, unsandboxed, for a missing object."""
        remaining = BUDGET - (time.monotonic() - START)
        if remaining <= 0:
            raise Deny(TIMED_OUT)
        env = dict(env if env is not None else os.environ)
        env["GIT_NO_LAZY_FETCH"] = "1"
        text = {} if raw else {"encoding": "utf-8", "errors": "replace"}
        try:
            p = subprocess.run(self.base + list(args), capture_output=True, env=env, **text,
                               timeout=remaining if long else min(CALL_TIMEOUT, remaining))
        except subprocess.TimeoutExpired:
            raise Deny(TIMED_OUT)
        except OSError:
            return None
        return p.stdout if p.returncode == 0 else None

    def config(self, key):
        """A config value, or None when the key is not set."""
        out = self.run("config", "--get", key)
        return None if out is None else out.strip()

    def has_ref(self, ref):
        return self.run("show-ref", "--verify", "--quiet", ref) is not None


def expand_alias(repo, sub, args, depth=0):
    """Follow git aliases until a builtin appears. An alias whose expansion starts with
    push becomes a push; a shell alias that mentions push cannot be resolved."""
    if sub == "push" or sub in GIT_BUILTINS or depth > 5:
        return sub, args
    value = repo.config("alias." + sub)
    if value is None:
        return sub, args
    if value.startswith("!"):
        if re.search(r"\b(push|send-pack|http-push)\b", value):
            raise Deny(UNSUPPORTED.format("alias." + sub + " is a shell alias that pushes"))
        return sub, args
    try:
        expanded = shlex.split(value)
    except ValueError:
        return sub, args
    if not expanded:
        return sub, args
    if expanded[0].startswith("-"):
        if "push" in expanded:
            raise Deny(UNSUPPORTED.format("alias." + sub + " passes git options before push"))
        return sub, args
    return expand_alias(repo, expanded[0], expanded[1:] + list(args), depth + 1)


def push_aliases(cwd, selector):
    """Names of the aliases that expand to a push, in cwd or the repository a -C or
    --git-dir selector names."""
    out = Repo(cwd, selector).run("config", "--get-regexp", r"^alias\.") or ""
    names = set()
    for line in out.splitlines():
        name, _, value = line.partition(" ")
        if PUSHY_ALIAS.search(value):
            names.add(name[len("alias."):])
    return names


WRAPPERS = {"command", "env", "sudo", "time", "nohup", "xargs", "exec", "nice", "builtin"}
DASH_PUSH = {"git-push", "git-send-pack", "git-http-push"}
GIT_NAMES = ("git",) + tuple(sorted(DASH_PUSH))
# Shell reserved words: the word after one is still in command position.
RESERVED = {"if", "then", "elif", "else", "do", "while", "until", "!", "{"}


def starts_command(tok):
    """An operator after which a new command begins (not a redirect)."""
    return is_operator(tok) and "<" not in tok and ">" not in tok


def command_words(tokens, runners=None):
    """Indexes of the words in command position: at the start, after an operator, after
    VAR=value assignments, and after a wrapper (command, env, sudo, time, xargs, ...).
    runners, when given, collects the indexes of the nice words that sit in command position
    (a wrapper, so never listed in the result)."""
    out, i, n, at = [], 0, len(tokens), True
    while i < n:
        t = tokens[i]
        if starts_command(t):
            at = True
        elif not is_operator(t) and at:
            if ASSIGN_RE.match(t) or t in RESERVED:
                pass
            elif os.path.basename(t) in WRAPPERS:
                if runners is not None and os.path.basename(t) in RUN_OPTS_WITH_VALUE:
                    runners.append(i)
                while i + 1 < n and not is_operator(tokens[i + 1]) and (
                        tokens[i + 1].startswith("-") or ASSIGN_RE.match(tokens[i + 1])):
                    i += 1
            else:
                out.append(i)
                at = False
        i += 1
    return out


def case_pattern(tokens, k):
    """Is the command word at k a case pattern: right after an operator (;; or a newline),
    words joined by | and closed by ), as in a) ... ;; g*|*git*) ...? A git spelled there
    would run with no arguments. A word after a wrapper (xargs g[i]t)) is never one."""
    if k > 0 and not starts_command(tokens[k - 1]):
        return False
    j, n = k + 1, len(tokens)
    while j + 1 < n and tokens[j] == "|" and not is_operator(tokens[j + 1]):
        j += 2
    return j < n and is_operator(tokens[j]) and tokens[j].startswith(")")


_GLOB_MEMO = {}


def _glob_elements(word):
    """The word as a list of elements: a literal character, ("?",) for one character, ("*",)
    for any number (runs collapsed). The span from the first [ that has a later ] through the
    last ] of the word is one ("*",): whatever a shell makes of the brackets inside it (the first
    ] closing, classes [:x:] [.x.] [=x=], zsh closing [!] at once, a quoted ] the tokenizer has
    already unquoted), an expression ends inside the span, so the span stands for any characters.
    A [ with no ] after it is a literal. The one exception is a span that holds a single [ and a
    single ] around plain characters (not ! ^ or *: [tag], [x]): every reading agrees that it is one
    character, so it is ("?",). Linear."""
    last = word.rfind("]")
    first = word.find("[", 0, max(last, 0))
    out = []

    def add(text):
        for c in text:
            if c == "*":
                if not out or out[-1] != ("*",):
                    out.append(("*",))
            elif c == "?":
                out.append(("?",))
            else:
                out.append(c)

    if first == -1:
        add(word)
    else:
        inner = word[first + 1:last]
        one = (inner and "[" not in inner and "]" not in inner and "*" not in inner
               and inner[0] not in "!^")
        add(word[:first])
        out.append(("?",) if one else ("*",))
        add(word[last + 1:])
    return out


def _glob_matches(elems, name):
    """Does the element list match the whole name? Tracks the set of element indexes reached,
    a * also reaching the elements after it."""
    def close(reached):
        out = set(reached)
        for e in reached:
            while e < len(elems) and elems[e] == ("*",):
                e += 1
                out.add(e)
        return out

    states = close({0})
    for ch in name:
        nxt = set()
        for e in states:
            if e < len(elems):
                el = elems[e]
                if el == ("*",):
                    nxt.add(e)
                elif el == ("?",) or el == ch:
                    nxt.add(e + 1)
        states = close(nxt)
        if not states:
            return False
    return len(elems) in states


def glob_matches_git_name(word):
    """Could a glob word expand to git or a git-* name? The word is read as elements (see
    _glob_elements: the span from the first [ with a later ] through the last ] is any
    characters) and a small linear matcher compares them with the four git names. It never
    raises and costs its length at most, where Python 3.9 fnmatch, which main used here,
    raises re.error on a backwards range ([:-9]), reads ^ as a literal, has no [:alpha:] class and
    is quadratic on a run of [. It over-matches on purpose (g[i]t is g*t); a pairing still needs
    a hidden subcommand word (view side) or a literal one (raw side). Measured against the fnmatch
    of main in the round 6 report: no word that main accepted is refused."""
    hit = _GLOB_MEMO.get(word)
    if hit is not None:
        return hit
    elems = _glob_elements(word)
    # Every element but a * takes exactly one character: more than 13 can match no git name.
    if sum(1 for e in elems if e != ("*",)) > max(len(g) for g in GIT_NAMES):
        hit = False
    else:
        hit = any(_glob_matches(elems, g) for g in GIT_NAMES)
    if len(_GLOB_MEMO) > 512:
        _GLOB_MEMO.clear()
    _GLOB_MEMO[word] = hit
    return hit


def glob_only(word):
    """Is the raw word made of * alone (a case arm, a markdown bullet)? It spells no command
    name and is the only exemption: a word of ?, [..] or both (???, [g][i][t]) can single out
    git, and the collapsed form of [[.g.]i[t] is a *, so the test never looks at the collapse."""
    return bool(word) and not word.strip("*")


def glob_git_word(tokens, k):
    """Is the command word at k a glob that can expand to git or a git-* name: a glob (?, [, *)
    that is not a bare glob (glob_only), not a case pattern, and matches (glob_matches_git_name)?"""
    base = os.path.basename(tokens[k])
    if not any(c in base for c in "?[*"):
        return False
    if glob_only(base) or case_pattern(tokens, k):
        return False
    return glob_matches_git_name(base)


def odd_command_word(tokens):
    """A command word that could be git push under another spelling: git-push,
    git-send-pack or git-http-push by name (the dash form, also behind a path), a glob
    that matches git or one of those names (gi?, g[i]t), or a built word (a last component
    holding $, a backtick, { or }) whose subcommand slot is push or send-pack (built_word_hits,
    the final return). A glob with no literal in it (*) and a case pattern (g*)) are not
    spellings of a command."""
    for k in command_words(tokens):
        base = os.path.basename(tokens[k])
        if base in DASH_PUSH:
            return True
        # Only the last path component decides: $HOME/bin/helm is helm. The glob branch below
        # does not treat $DOCKER as a git spelling; the built-word rule after the loop catches
        # it when its slot is push. A glob is refused when it can match git or a git-* name.
        if glob_git_word(tokens, k):
            return True
    return bool(built_word_hits(tokens))


PUSH_SLOT = {"push", "send-pack", "http-push"}


def git_slot(tokens, k, stop_dynamic=True):
    """Walk git's global options after the command word at k. Returns (j, at_option): j is
    the index of the subcommand slot (n, or an operator, when there is none), or, when
    stop_dynamic and a dynamic option or option value is reached, that option's index with
    at_option true, since the slot is not reached."""
    n = len(tokens)
    j = k + 1
    while j < n and not is_operator(tokens[j]):
        w = tokens[j]
        name = w.split("=", 1)[0]
        if w in ("-C", "-c") or (name in GIT_LONG_OPTS_WITH_VALUE and "=" not in w):
            if stop_dynamic and (dynamic(w) or (
                    j + 1 < n and dynamic(tokens[j + 1], dollar=(w != "-C")))):
                return j, True
            j += 2
        elif w.startswith("-"):
            if stop_dynamic and dynamic(w):
                return j, True
            j += 1
        else:
            break
    return j, False


def git_word_hits(tokens):
    """(git_index, slot_index) for each git command word that can name a push: the word in its
    slot past the global options is either a subcommand the shell rewrites (git ${X:-push}),
    or a push by its raw token (push, send-pack, http-push). A dynamic global option or option
    value is a hit too; slot_index is then that option's index, since the slot is not reached.
    The text cannot rule such a word out. Only a git in command position counts: rg git -g
    '*.sh' names git as an argument."""
    n = len(tokens)
    hits = []
    for k in command_words(tokens):
        if os.path.basename(tokens[k]) != "git":
            continue
        j, at_option = git_slot(tokens, k)
        if at_option or (j < n and not is_operator(tokens[j])
                         and (dynamic(tokens[j]) or tokens[j] in PUSH_SLOT)):
            hits.append((k, j))
    return hits


BUILT_SLOT = {"push", "send-pack"}


def built_word_hits(tokens):
    """(word_index, slot_index) for each command word, in command_words order and not a case
    pattern, whose last path component holds $, a backtick, { or } (a word the shell builds)
    and whose slot past git's global options is push or send-pack. Such a word can be a git
    (spec section 4)."""
    n = len(tokens)
    hits = []
    for k in command_words(tokens):
        base = os.path.basename(tokens[k])
        if not any(c in base for c in "$`{}") or case_pattern(tokens, k):
            continue
        j, _ = git_slot(tokens, k, stop_dynamic=False)
        if j < n and not is_operator(tokens[j]) and tokens[j] in BUILT_SLOT:
            hits.append((k, j))
    return hits


def dynamic_git_word(tokens):
    return bool(git_word_hits(tokens))


SHELL_NAMES = {"sh", "bash", "zsh", "dash", "ksh"}


# Options of a shell that take the next word as their value (-o NAME, -O NAME, --rcfile F).
SHELL_LONG_WITH_VALUE = {"--rcfile", "--init-file"}
# The options of timeout and nice that take the next word as their value.
RUN_OPTS_WITH_VALUE = {"timeout": {"-s", "-k", "--signal", "--kill-after"},
                       "nice": {"-n", "--adjustment"}}


def shell_string_at(tokens, k):
    """The index of the command string of the shell at k, or None. Walks the shell's own options: a bundle
    of letters (-x, +e, -lc, -co NAME), an option with a value (-o NAME, -O NAME, --rcfile F,
    --init-file F), a long flag, and -- ending them. The string is the first word past them,
    and only when a bundle held c."""
    n, j, has_c = len(tokens), k + 1, False
    while j < n and not is_operator(tokens[j]):
        w = tokens[j]
        if w == "--":
            j += 1
            break
        if w in SHELL_LONG_WITH_VALUE:
            j += 2
        elif w.startswith("--") and len(w) > 2:
            j += 1
        elif re.fullmatch(r"[-+][A-Za-z]+", w):
            has_c = has_c or (w[0] == "-" and "c" in w)
            j += 1 + sum(w.count(c) for c in "oO")
        else:
            break
    if has_c and j < n and not is_operator(tokens[j]):
        return j
    return None


def shell_string(tokens, k):
    """The command string of the shell at k, or None (see shell_string_at)."""
    j = shell_string_at(tokens, k)
    return None if j is None else tokens[j]


def run_target(tokens, k, bound=3):
    """Indexes of the words that the timeout or nice command word at k runs, past its options
    (-s SIG, -k DUR, --signal=SIG, --foreground, -n N, ...) and, for timeout, its duration;
    a timeout or nice there chains on, to a bound of 3."""
    base = os.path.basename(tokens[k])
    n, j = len(tokens), k + 1
    while j < n and not is_operator(tokens[j]) and tokens[j].startswith("-") \
            and len(tokens[j]) > 1:
        j += 2 if tokens[j] in RUN_OPTS_WITH_VALUE[base] else 1
    if base == "timeout":
        j += 1
    if j >= n or is_operator(tokens[j]):
        return []
    out = [j]
    if bound > 1 and os.path.basename(tokens[j]) in RUN_OPTS_WITH_VALUE:
        out.extend(run_target(tokens, j, bound - 1))
    return out


def shell_words(tokens):
    """Indexes of the words in command position, and of the words that a timeout or nice in
    command position runs (command_words looks past nice's dash options, but not its -n
    value, and not past timeout). A timeout or nice that is an argument starts nothing."""
    runners = []
    out = list(command_words(tokens, runners))
    runners.extend(k for k in out if os.path.basename(tokens[k]) == "timeout")
    for k in runners:
        out.extend(run_target(tokens, k))
    return out


def nested_token_lists(tokens, depth=3):
    """The tokenized command strings that a shell -c string or an eval, in command position,
    runs, to a nesting depth of 3. Only the command-string argument (the word after the
    shell's options) and eval's joined arguments count. A string the tokenizer cannot split
    is dropped."""
    if depth <= 0:
        return []
    n = len(tokens)
    found = []
    for k in shell_words(tokens):
        base = os.path.basename(tokens[k])
        inner = None
        if base == "eval":
            j = k + 1
            while j < n and not is_operator(tokens[j]):
                j += 1
            inner = " ".join(tokens[k + 1:j])
        elif base in SHELL_NAMES:
            inner = shell_string(tokens, k)
        if not inner:
            continue
        try:
            sub = tokenize(inner)
        except ValueError:
            continue
        found.append(sub)
        found.extend(nested_token_lists(sub, depth - 1))
    return found


def alias_slot_hit(tokens, names):
    """Is the subcommand slot of a git command word in tokens one of these alias names?"""
    n = len(tokens)
    for k in command_words(tokens):
        if os.path.basename(tokens[k]) != "git":
            continue
        j, _ = git_slot(tokens, k, stop_dynamic=False)
        if j < n and not is_operator(tokens[j]) and tokens[j] in names:
            return True
    return False


def outside_grammar(cmd):
    """Text parse_plain cannot judge faithfully: an ANSI-C quote, or a backslash-newline
    inside a word (a continuation between words leaves the grammar's verdict as it was)."""
    return "$'" in cmd or re.search(r"\S\\\n\S", cmd) is not None


def probe_refuses(tokens, cmd, cwd):
    """Would the grammar have denied or asked for cmd, had it been judged as written? A
    command outside the grammar keeps every refusal main gave it, as the plain-push deny.
    A parse that fails says nothing: the path after it decides. A judge that fails, with a
    shape in hand, refuses, as main's internal-error deny did."""
    shape = None
    try:
        shape = parse_plain(tokens, cwd)
        return shape is not None and bool(judge(shape, cwd, canonical(cmd)))
    except Deny:
        return True
    except Exception:
        return shape is not None


# Tools that never execute their arguments: what follows the command word is data, so a
# quoted "git push" there is a mention, not a call. Anything else (a shell, find, sed, awk,
# ssh, watch, timeout, parallel, every WRAPPERS member) may run or re-parse its words.
# uniq is not one: it writes its second operand, a file a later command can run.
INERT_TOOLS = {"rg", "grep", "fd", "cat", "head", "tail", "wc", "echo", "printf", "ls", "eza",
               "diff", "cmp", "cut", "sort", "tr", "jq", "test", "["}
# The git subcommands whose arguments are data: none of their options runs a command or
# writes a file. An allowlist, kept to subcommands with a small option surface: log, show,
# diff, grep, fetch, rebase and the like keep yielding options that do (--output, -O,
# --upload-pack, --exec), and config and remote can plant a command for a later word.
INERT_GIT_SUBCOMMANDS = {
    "add", "commit", "status", "switch", "branch", "rm", "mv", "restore", "rev-parse",
    "tag", "stash",
}
# stash is inert only for these actions: stash list takes log options and stash show diff
# options, both with --output=<file>.
INERT_STASH_ACTIONS = {"push", "save", "pop", "apply", "drop", "clear", "branch"}
# Text that the tokenizer cannot be trusted to split, or that nests a command in a word: the
# whole command is then read raw. A here-document, a backtick, $( ), <( ), >( ) and $'..'
# (shlex does not know it, so a quote inside could hide a push).
UNSPLITTABLE = re.compile(r"<<|`|\$\(|<\(|>\(|\$'")
# Options that make an inert tool run one of its arguments or write a file: rg --pre, fd
# -x/-X/--exec, sort --compress-program and -o/--output (getopt_long takes any prefix, so
# every --c* and --o* counts, and -o anywhere in a bundle), printf -v (assigns text a later
# eval runs).
TOOL_EXEC_ARG = {
    "rg": re.compile(r"^--(pre|hostname-bin)\b"),
    "fd": re.compile(r"^(--exec|-[A-Za-z0-9]*[xX])"),
    "sort": re.compile(r"^(--[co]|-[^-]*o)"),
    "printf": re.compile(r"^-v"),
}
# git long options that hand an argument to a shell or plant one. git accepts any unambiguous
# prefix (--upload-pa), so a --name that is a prefix of one of these counts.
GIT_EXEC_LONG = ("upload-pack", "receive-pack", "exec", "open-files-in-pager", "extcmd",
                 "template", "config-env", "sendmail-cmd", "to-cmd", "cc-cmd", "header-cmd",
                 "tool-cmd")
# The short options that do the same, wherever they sit in a bundle (-nO<cmd>, -qu <cmd>).
GREP_PAGER_BUNDLE = re.compile(r"^-[A-Za-z]*O")
UPLOAD_PACK_BUNDLE = re.compile(r"^-[A-Za-z]*u")


def exec_long_option(word):
    """Is this --name or --name=value a prefix of an option that runs or plants a command?"""
    if not word.startswith("--"):
        return False
    name = word[2:].split("=", 1)[0]
    return bool(name) and any(o.startswith(name) for o in GIT_EXEC_LONG)


# The only operators of a flat list of simple commands. Anything else (a newline, a paren,
# |&, &, ;;) can nest or detach a command from what it feeds, so the text is read raw.
FLAT_OPS = {"&&", "||", ";", "|"}
# A shell keyword as a command word means a compound command (a group, a loop, a test).
SHELL_KEYWORDS = {"{", "}", "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
                  "done", "case", "esac", "select", "function", "!", "[[", "]]"}


def flat_redirect(tokens, j):
    """Is the redirect operator at tokens[j] harmless: output to /dev/null, or a descriptor
    duplication (2>&1, >&2)? Any other redirect can write a file a later command runs, or
    read one into a shell."""
    op, nxt = tokens[j], tokens[j + 1] if j + 1 < len(tokens) else ""
    if op in (">", ">>", "&>", "&>>"):
        return nxt == "/dev/null"
    if op == ">&":
        return nxt in ("-", "/dev/null") or nxt.isdigit()
    return False


def flat_list(tokens):
    """Is this a flat list of simple commands: operators only && || ; |, redirects only to
    /dev/null or between descriptors?"""
    for j, t in enumerate(tokens):
        if not is_operator(t) or t in FLAT_OPS:
            continue
        if ("<" not in t and ">" not in t) or not flat_redirect(tokens, j):
            return False
    return True


def inert_git(args):
    """Are the arguments after a git command word data? Only for a builtin that is neither
    a push nor a command runner, with no -c or --config-env (config can name a command git
    runs), and no option that hands a word to a shell."""
    i, n = 0, len(args)
    while i < n and args[i].startswith("-") and not is_operator(args[i]):
        w = args[i]
        name = w.split("=", 1)[0]
        if dynamic(w) or name in GIT_CONFIG_OPTS:
            return False
        if w == "-C" or (name in GIT_LONG_OPTS_WITH_VALUE and "=" not in w):
            i += 2
        elif w in GIT_FLAGS or name in GIT_LONG_OPTS_WITH_VALUE:
            i += 1
        else:
            return False
    if i >= n or is_operator(args[i]) or dynamic(args[i]):
        return False
    sub, rest = args[i], args[i + 1:]
    if sub not in INERT_GIT_SUBCOMMANDS or runs_command_string(sub, rest):
        return False
    if sub == "stash" and (not rest or rest[0] not in INERT_STASH_ACTIONS):
        return False
    if any(exec_long_option(a) for a in rest):
        return False
    if sub == "grep" and any(GREP_PAGER_BUNDLE.match(a) for a in rest):
        return False
    if sub in ("clone", "fetch", "pull", "ls-remote") and any(
            UPLOAD_PACK_BUNDLE.match(a) for a in rest):
        return False
    return True


def inert_command(seg):
    """For one simple command: the index just past its command word when its arguments are
    inert data, else None. Wrappers (command, env, sudo, xargs, exec, ...) run the next words,
    so they are never inert; assignments before the command stay in the text."""
    words = command_words(seg)
    if not words:
        return None
    k = words[0]
    if any(os.path.basename(t) in WRAPPERS for t in seg[:k]):
        return None
    word, args = seg[k], seg[k + 1:]
    if word == "git":
        return k + 1 if inert_git(args) else None
    if word in INERT_TOOLS and not any(
            TOOL_EXEC_ARG[word].match(a) for a in args if word in TOOL_EXEC_ARG):
        return k + 1
    return None


def inert_text(cmd, tokens):
    """The text could_push matches PUSH_SHAPE and the alias regex against: cmd with the
    arguments of provably inert simple commands dropped. Everything that can execute or
    re-parse text stays: a command the tokenizer cannot split reliably (unbalanced quotes,
    here-document, backtick, $( ), <( ), >( ), $'..', a # comment), every command word that is
    not inert, and a pipeline that feeds any non-inert command (it may run its stdin).
    It redacts only a flat list of simple commands (see flat_list): a group, a loop, a
    newline, a background job, |&, or a redirect to anything but /dev/null or a descriptor
    returns the raw text, as does a shell keyword in command position."""
    if tokens is None or UNSPLITTABLE.search(cmd) or any(t.startswith("#") for t in tokens):
        return cmd
    if not flat_list(tokens):
        return cmd
    segs, ops = [[]], []
    for t in tokens:
        if t in FLAT_OPS:
            ops.append(t)
            segs.append([])
        else:
            segs[-1].append(t)
    for s in segs:
        words = command_words(s)
        if any(t in SHELL_KEYWORDS for t in (s[:words[0] + 1] if words else s)):
            return cmd
    cut = [inert_command(s) for s in segs]
    if all(c is None for c in cut):
        return cmd                                     # nothing dropped: read the raw text
    start = 0
    while start < len(segs):                           # a pipeline: segments joined by |
        end = start
        while end < len(ops) and ops[end] == "|":
            end += 1
        if any(c is None for c in cut[start:end + 1]):
            cut[start:end + 1] = [None] * (end + 1 - start)
        start = end + 1
    out = []
    for i, seg in enumerate(segs):
        out.extend(seg if cut[i] is None else seg[:cut[i]])
        if i < len(ops):
            out.append(ops[i])
    return " ".join(out)


def could_push(cmd, tokens, cwd):
    """For a command outside the grammar: could it run git push? Two readings of the text.
    The raw reading is main's superset and runs only when the fast path saw a push as written
    (raw_checks_enabled): git and push in its text, git and a push alias (from cwd, or a
    repository a -C, --git-dir or GIT_DIR in it names), git under a GIT_CONFIG override, or git
    followed by a subcommand the shell computes. Its text is cmd without the arguments of
    provably inert commands (inert_text); no shape is parsed. The view reading (views,
    view_could_push) decodes the escapes and quotes and denies only a git or push word that was
    spelled with a break; it runs whenever the command holds a hidden-spelling signal. Under
    PUSH_GUARD_LITERAL=0 the raw reading never runs, so a command that holds no push word
    anywhere is judged by its hidden spellings alone."""
    literal = raw_checks_enabled()
    text, nested = cmd, []
    if literal:
        text = inert_text(cmd, tokens)
        if PUSH_SHAPE.search(text):
            return True
        nested = nested_token_lists(tokens) if tokens else []
        if tokens and (dynamic_git_word(tokens) or odd_command_word(tokens)
                       or any(git_word_hits(sub) or odd_command_word(sub) for sub in nested)):
            return True
    # The view side is new code on every path, literal or not: a failure in it denies.
    try:
        vs = views(cmd) if hidden_signal(cmd) else []
        raw_git = literal and re.search(r"\bgit\b", cmd) is not None
        view_git = [v for v in vs if GIT_WORD.search(v.text)]
        if raw_git and "GIT_CONFIG" in cmd:
            return True
        names = set()
        if raw_git or view_git:
            selectors = {()}                               # a set: each one costs a git call
            token_lists = ([tokens or []] + nested) if raw_git else []
            token_lists += [[t for t, _, _ in view_tokens(v.text)] for v in view_git]
            for toks in token_lists:
                for k, tok in enumerate(toks):
                    if tok in ("-C", "--git-dir") and k + 1 < len(toks):
                        selectors.add((tok, os.path.expanduser(toks[k + 1])))
                    elif tok.startswith("--git-dir="):
                        selectors.add((tok,))
                    elif tok.startswith("GIT_DIR="):
                        selectors.add(("--git-dir=" + tok.split("=", 1)[1],))
            for sel in sorted(selectors):
                try:
                    names |= push_aliases(cwd, list(sel))
                except Deny:
                    raise
                except Exception:
                    return True                            # a listing that fails cannot rule a push out
        # A shell string or an eval is read as tokens: a quoted ; in it hides the alias from the
        # text pattern.
        if raw_git and (any(re.search(r"\bgit\b[^;&|\n]*\b" + re.escape(a) + r"\b", text) for a in names)
                        or any(alias_slot_hit(sub, names) for sub in nested)):
            return True
        return bool(vs) and view_could_push(cmd, names)
    except Deny:
        raise
    except Exception:
        return True


# ------------------------------------------------------------------ normalized views
# Spec 2026-10-29-push-guard-escaped-spellings, section 1. A view is the command with every
# backslash escape decoded, wherever it sits, and every quote and leftover backslash deleted;
# no shell context is tracked. A view reports a git or push word only when that word is hidden,
# that is, when its raw span is not exactly the word.
READINGS = ("zsh", "bash5", "bash32")
View = namedtuple("View", "text spans cuts")
# The commands the views are built for: nothing can be hidden without one of these.
HIDDEN_SIGNAL = re.compile(r"\$'|\$\"|\\\n|\\[xuUc0-7]|[A-Za-z0-9]['\"\\]+[A-Za-z0-9]")
# A word of a view is a maximal run of letters, digits, underscores and hyphens: git-pu""sh-guard.py holds
# neither a git word nor a push word, while git-push is both.
WORD_EDGE = r"(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])"
GIT_WORD = re.compile(WORD_EDGE % "git")
DASH_PUSH_WORD = re.compile(WORD_EDGE % "git-(?:push|send-pack|http-push)")
BACKSLASH = re.compile(r"\\")
STEP3 = re.compile(r"\$(?=['\"])|['\"\\]")
VIEW_TOKEN = re.compile(r"\n|`|[;&|()<>]+|[^\s;&|()<>`]+")
WORD_END = re.compile(r"[ \t\n;&|()<>]")
CTRL_LETTER = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r",
               "t": "\t", "v": "\v"}
HEX_DIGITS = "0123456789abcdefABCDEF"
OCT_DIGITS = "01234567"
MAX_VIEWS = 12


def hidden_signal(cmd):
    """Does the raw command hold a spelling that could hide a git or push word?"""
    return HIDDEN_SIGNAL.search(cmd) is not None


def _digits(raw, i, allowed, limit):
    """The end of the run of up to limit characters of allowed that starts at i."""
    j, n = i, len(raw)
    while j < n and j - i < limit and raw[j] in allowed:
        j += 1
    return j


def _code_point(value):
    """The character of a \\u or \\U value, or nothing for one chr() rejects or a surrogate
    (which no later encoding could take)."""
    if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
        return ""
    return chr(value)


def _zsh_key(raw, j, depth):
    """The argument of zsh's \\C- and \\M- at j: (character, end), the character empty when the
    argument is an escape that yields none, or None when there is no argument (end of the text,
    or the quote that closes the body)."""
    if j >= len(raw) or raw[j] == "'":
        return None
    if raw[j] == "\\" and depth > 0 and j + 1 < len(raw):
        out, end = decode_escape(raw, j, "zsh", False, depth - 1)
        if out or end > j + 1:
            return out, end
        return raw[j + 1], j + 2                       # an unknown escape drops its backslash
    return raw[j], j + 1


def decode_escape(raw, i, reading, bare, depth=3):
    """The backslash escape at raw[i] under this reading: (text, end). The text is empty, one
    character, or a kept backslash (bash keeps the backslash of an escape it does not know; the
    character after it stays in the raw text). bare reads a single-letter escape as its bare
    letter, as an unquoted backslash does. NUL is the character U+0000. Never raises."""
    n = len(raw)
    if i + 1 >= n:
        return "\\", i + 1                              # a trailing backslash
    c = raw[i + 1]
    kept = "" if reading == "zsh" else "\\"
    if c in CTRL_LETTER:
        return (c if bare else CTRL_LETTER[c]), i + 2
    if c in "\\'\"?":
        return c, i + 2
    if c in OCT_DIGITS:
        j = _digits(raw, i + 1, OCT_DIGITS, 3)
        return chr(int(raw[i + 1:j], 8) & 0xFF), j
    if c == "x":
        if reading != "zsh" and raw[i + 2:i + 3] == "{":
            j = _digits(raw, i + 3, HEX_DIGITS, n)
            value = int(raw[max(i + 3, j - 2):j], 16) if j > i + 3 else 0
            if raw[j:j + 1] == "}":
                j += 1
            return chr(value & 0xFF), j
        j = _digits(raw, i + 2, HEX_DIGITS, 2)
        if j > i + 2:
            return chr(int(raw[i + 2:j], 16)), j
        return ("\0", i + 2) if reading == "zsh" else (kept, i + 1)
    if c in "uU":
        if reading == "bash32":
            return kept, i + 1
        j = _digits(raw, i + 2, HEX_DIGITS, 4 if c == "u" else 8)
        if j > i + 2:
            return _code_point(int(raw[i + 2:j], 16)), j
        return ("\0", i + 2) if reading == "zsh" else (kept, i + 1)
    if c == "c" and reading != "zsh":
        a = raw[i + 2:i + 3]
        if a == "" or a == "'":
            return ("\\", i + 2) if reading == "bash32" else (kept, i + 1)
        end = i + 3
        if a == "\\" and reading == "bash5" and raw[i + 3:i + 4] == "\\":
            end = i + 4                                 # bash 5 reads \c\\ as control-backslash
        if ord(a) > 0x7F:
            return kept, i + 1
        value = 0x7F if (a == "?" and reading == "bash5") else (ord(a.upper()) & 0x1F)
        return chr(value), end
    if c in "CM" and reading == "zsh":
        j = i + 2
        if raw[j:j + 1] == "-":
            j += 1
        key = _zsh_key(raw, j, depth)
        if key is None:
            return "", j
        ch, end = key
        if not ch:
            return "", end
        if raw[j:j + 1] == "\\" and raw[j + 1:j + 2] in ("u", "U"):
            return ch, end                              # zsh applies neither to a \u or \U character
        o = ord(ch)
        if c == "C":
            value = 0x7F if ch in "?\x7f" else ((o & 0x1F) | (o & 0x80))
        else:
            value = (o | 0x80) if o < 0x100 else o
        return chr(value), end
    return kept, i + 1


def decode_ansi(body, reading):
    """The control-character reading of a $'...' body under this reading ("zsh", "bash5" or
    "bash32"): what printf %s $'<body>' prints, with NUL kept as "\\0", and a byte above 0x7f
    as the character of that value."""
    return _decode_pass(body, reading, False, [m.start() for m in BACKSLASH.finditer(body)])[0]


def _decode_pass(raw, reading, bare, bslashes):
    """Steps 1 and 2 of a view: delete the backslash-newline pairs and decode every escape.
    Returns the text and the marks that map it back to raw spans: parallel lists of the text
    offset a mark starts at, its raw start, and its raw end (-1 for a run copied as it stands,
    where each character is its own span)."""
    parts, mt, mr, me = [], [], [], []
    tlen = pos = 0
    for b in bslashes:
        if b < pos:
            continue                                   # inside an escape already consumed
        if b > pos:
            parts.append(raw[pos:b])
            mt.append(tlen)
            mr.append(pos)
            me.append(-1)
            tlen += b - pos
            pos = b
        if raw[b + 1:b + 2] == "\n":
            pos = b + 2                                # step 1: a continuation vanishes
            continue
        out, end = decode_escape(raw, b, reading, bare)
        if out:
            parts.append(out)
            mt.append(tlen)
            mr.append(b)
            me.append(end)
            tlen += len(out)
        pos = end
    if pos < len(raw):
        parts.append(raw[pos:])
        mt.append(tlen)
        mr.append(pos)
        me.append(-1)
    return "".join(parts), (mt, mr, me)


class Spans(object):
    """spans[k] is the (start, end) raw span of view character k. Built from the kept stretches
    of the decoded text and the marks, and looked up on demand, so a large command costs no
    per-character table."""

    def __init__(self, fstarts, tstarts, length, marks):
        self.fstarts, self.tstarts, self.length = fstarts, tstarts, length
        self.mt, self.mr, self.me = marks

    def __len__(self):
        return self.length

    def __getitem__(self, k):
        if k < 0:
            k += self.length
        if not 0 <= k < self.length:
            raise IndexError(k)
        s = bisect_right(self.fstarts, k) - 1
        t = self.tstarts[s] + (k - self.fstarts[s])
        m = bisect_right(self.mt, t) - 1
        if self.me[m] < 0:
            r = self.mr[m] + (t - self.mt[m])
            return (r, r + 1)
        return (self.mr[m], self.me[m])


def _raw_origin(marks, t):
    """Is the decoded character at t one the raw text holds as it stands (not an escape's)?"""
    mt, _, me = marks
    return me[bisect_right(mt, t) - 1] < 0


def _nul_drops(text, marks, rule):
    """The stretches of the decoded text a NUL drops, and the raw offsets where each begins.
    quote: from the NUL to the next quote the raw text holds (bash ends the value there).
    word: to the next blank or operator the raw text holds (execve ends the word there)."""
    drops, cuts = [], []
    mt, mr, me = marks
    p = text.find("\0")
    while p != -1:
        q = p + 1
        while True:
            if rule == "quote":
                q = text.find("'", q)
                if q == -1:
                    q = len(text)
                    break
            else:
                m = WORD_END.search(text, q)
                if m is None:
                    q = len(text)
                    break
                q = m.start()
            if _raw_origin(marks, q):
                break
            q += 1
        i = bisect_right(mt, p) - 1
        cuts.append(mr[i] + (p - mt[i]) if me[i] < 0 else mr[i])
        drops.append((p, q))
        p = text.find("\0", q)
    return drops, cuts


def _finish(text, marks, drops, cuts):
    """Step 3, with the NUL drops: delete each $ directly before a quote, then every quote and
    every leftover backslash. Returns the View."""
    dels = [(m.start(), m.end()) for m in STEP3.finditer(text)]
    if drops:
        dels = sorted(dels + drops)
    kept, cur = [], 0
    for a, b in dels:
        if a > cur:
            kept.append((cur, a))
        if b > cur:
            cur = b
    if cur < len(text):
        kept.append((cur, len(text)))
    fstarts, tstarts, total = [], [], 0
    for a, b in kept:
        fstarts.append(total)
        tstarts.append(a)
        total += b - a
    out = "".join([text[a:b] for a, b in kept])
    return View(out, Spans(fstarts, tstarts, total, marks), sorted(cuts))


_VIEWS_MEMO = [None, None]


def views(cmd):
    """The views of cmd, deduplicated by text, at most MAX_VIEWS. Under each reading a view is
    the command with steps 1 to 3 applied (see above), once with single-letter escapes as
    control characters and once as bare letters; a NUL, wherever an escape makes one, splits
    each of those in two (quote and word drops). Never raises."""
    if _VIEWS_MEMO[0] == cmd and _VIEWS_MEMO[1] is not None:
        return _VIEWS_MEMO[1]
    bslashes = [m.start() for m in BACKSLASH.finditer(cmd)]
    seen, out = {}, []
    for reading in (READINGS if bslashes else READINGS[:1]):
        for bare in ((False, True) if bslashes else (False,)):
            text, marks = _decode_pass(cmd, reading, bare, bslashes)
            rules = ("quote", "word") if "\0" in text else (None,)
            for rule in rules:
                drops, cuts = _nul_drops(text, marks, rule) if rule else ([], [])
                view = _finish(text, marks, drops, cuts)
                old = seen.get(view.text)
                if old is None:
                    seen[view.text] = view
                    out.append(view)
                elif cuts:
                    old.cuts[:] = sorted(set(old.cuts) | set(cuts))
    result = out[:MAX_VIEWS]
    _VIEWS_MEMO[0], _VIEWS_MEMO[1] = cmd, result
    return result


def view_tokens(text):
    """(token, start, end) for each word, newline and run of operators in a view's text. No
    shlex: the quotes are already gone."""
    return [(m.group(), m.start(), m.end()) for m in VIEW_TOKEN.finditer(glue_paren_groups(text))]


def hidden(cmd, view, start, end):
    """Is the word view.text[start:end] hidden? Its raw span runs from the raw start of its
    first character to the raw end of its last. It is hidden when that raw text is not exactly
    the word, or when a NUL variant began dropping text right after it."""
    if end <= start:
        return False
    a, b = view.spans[start][0], view.spans[end - 1][1]
    if cmd[a:b] != view.text[start:end]:
        return True
    i = bisect_left(view.cuts, b)
    return i < len(view.cuts) and view.cuts[i] == b


def _command_tokens(vt):
    """The tokens of a view with the command starts a view can show: a backtick starts a
    command, and so does the command string of a shell -c and the word after eval (the quotes
    that bounded them are gone)."""
    toks = [";" if t == "`" else t for t, _, _ in vt]
    out = list(toks)
    for k in command_words(toks):
        base = os.path.basename(toks[k])
        if base == "eval":
            out[k] = ";"
        elif base in SHELL_NAMES:
            j = shell_string_at(toks, k)
            if j is not None:
                out[j - 1] = ";"
    return out


def _glob_git_spans(toks, vt):
    """The view spans of the command words that odd_command_word's glob branch reads as a git:
    a glob that can expand to git or a git-* name, not a bare glob, not a case pattern."""
    out = []
    for k in command_words(toks):
        if glob_git_word(toks, k):
            out.append((vt[k][1], vt[k][2]))
    return out


def view_could_push(cmd, aliases):
    """Could some view of cmd run git push, with a git or push word spelled with a break? A
    word is a maximal run of letters, digits and hyphens. True when, in some view, a hidden
    git-push, git-send-pack or git-http-push word stands, or a git word (git, or a glob
    command word that can expand to git) is followed anywhere later by a push word (push,
    send-pack, http-push or an alias in aliases) and at least one of the two is hidden; or
    when git_word_hits or built_word_hits over the view's tokens finds a git word, a built
    command word or a push slot word that is hidden."""
    names = "push|send-pack|http-push" + "".join("|" + re.escape(a) for a in sorted(aliases) if a)
    push_re = re.compile(WORD_EDGE % ("(?:" + names + ")"))
    for v in views(cmd):
        for m in DASH_PUSH_WORD.finditer(v.text):
            if hidden(cmd, v, m.start(), m.end()):
                return True
        gits = [m.span() for m in GIT_WORD.finditer(v.text)]
        pushes = [m.span() for m in push_re.finditer(v.text)]
        if not gits and not pushes:
            continue
        vt = view_tokens(v.text)
        toks = _command_tokens(vt)
        gits = sorted(gits + _glob_git_spans(toks, vt))
        if gits and pushes:
            for s, e in gits:                          # the first hidden git is the best one
                if hidden(cmd, v, s, e):
                    if pushes[-1][0] >= e:
                        return True
                    break
            for s, e in reversed(pushes):              # the last hidden push is the best one
                if hidden(cmd, v, s, e):
                    if gits[0][1] <= s:
                        return True
                    break

        def word_hidden(k):
            return hidden(cmd, v, vt[k][1], vt[k][2])

        if gits:
            for k, j in git_word_hits(toks):
                # A hit at a dynamic option has no slot word: only the git word can be hidden.
                if word_hidden(k) or (not toks[j].startswith("-") and word_hidden(j)):
                    return True
        if pushes:
            for k, j in built_word_hits(toks):
                if word_hidden(k) or word_hidden(j):
                    return True
    return False


def runs_command_string(sub, args):
    """Does this git command execute a shell command given in its arguments?"""
    if sub == "filter-branch":
        return True
    if sub == "submodule":
        return "foreach" in args
    if sub == "bisect":
        return "run" in args
    if sub == "rebase":
        # --exec, its abbreviations (--ex, --exe=cmd), -x, and -x inside bundled flags (-ix)
        return any(len(a.split("=", 1)[0]) >= 4 and "--exec".startswith(a.split("=", 1)[0])
                   or re.match(r"^-[a-z]*x", a) for a in args)
    return False


def canonical(cmd):
    """Is the raw command canonical text (CANONICAL, and no argument a shell option rewrites:
    SHELL_REWRITES)? First
    at most one trailing newline is removed, then leading and trailing spaces: any other
    newline, a tab or a carriage return anywhere, a quote, an escape or any other character
    makes the text not canonical. The text starts with git push itself, so canonical text has
    no cd prefix, assignment, wrapper or global option (-C included: the classifier rule
    names only the plain form), and no alias."""
    text = cmd[:-1] if cmd.endswith("\n") else cmd
    m = CANONICAL.fullmatch(text.strip(" "))
    return bool(m) and not any(SHELL_REWRITES.search(w) for w in m.group(1).split(" ") if w)


def judge(s, session, text=False):
    """None to allow, a reason to ask; raises Deny. s is a plain command from parse_plain;
    session is the hook payload's cwd. text: the raw command is canonical text."""
    sub, args = s["sub"], s["args"]
    if sub != "push" and sub not in GIT_BUILTINS:
        if s["unknown"] or [a for a in s["assigns"] if GIT_ENV_UNSUPPORTED.match(a)]:
            raise Deny(PLAIN)                          # an alias under an override
        # -c options go into the lookup too: `git -c alias.x=push x` defines the alias on
        # the command line itself.
        sub, args = expand_alias(Repo(s["cwd"], s["repo_opts"] + s["config_opts"]), sub, args)
    if runs_command_string(sub, args) and re.search(r"\bpush\b", " ".join(args)):
        # git submodule foreach 'git push', git rebase --exec 'git push': the argument is
        # a shell command that pushes, and it is never read.
        raise Deny("Push guard: git " + sub + " runs a command that pushes. Push with "
                   "git push <remote> <branch> on its own, or push by hand.")
    if sub != "push" and sub not in GIT_BUILTINS and (
            sub in PUSHING_SUBCOMMANDS or "push" in args):
        # git subtree push, git lfs push, git send-pack: a push under another name, with
        # a destination this guard does not read.
        raise Deny("Push guard: git " + sub + " can push in a way the guard does not model. "
                   "Push with git push <remote> <branch>, or push by hand.")
    if sub != "push":
        return None                                    # a plain git command that does not push
    if s["unknown"]:
        raise Deny(UNSUPPORTED.format("the git option " + s["unknown"][0] + " on the push invocation"))
    # The shell runs the substitution where it is, not in the repository -C or a cd
    # selects, so the branch it names may belong to another repository.
    if (s["repo_opts"] or s["cd_used"]) and any(a in CURRENT_BRANCH for a in args):
        raise Deny("Push guard: the current-branch substitution runs where the shell is, not "
                   "in the repository -C or cd selects. Name the branch literally.")
    return evaluate(s["cwd"], s["assigns"], s["repo_opts"], s["config_opts"], args, session,
                    text)


def push_option(value, where=""):
    """Refuse a push option value outside PUSH_OPTIONS_OK. None is a -o with no value."""
    if value is None or not PUSH_OPTIONS_OK.fullmatch(value):
        raise Deny("Push guard: the push option {}{} is not one the guard allows (only ci.skip, "
                   "ci.variable=<name>=<value> and integrations.skip_ci). Push without it, and "
                   "open MRs with glab mr create --draft.".format(
                       "(missing)" if value is None else value, where))


def parse_push(args):
    """Split git push arguments into (flags, remote or None, refspecs). Raises Deny for an
    option outside the modelled set, a push option value outside PUSH_OPTIONS_OK, and the
    -- separator."""
    # Every word of the invocation, option values included: bash expands {x,origin,main}
    # or a glob before git sees it, so the literal words are not what git receives. A *
    # is left to the refspec check, which names it as a wildcard.
    for a in args:
        if a not in CURRENT_BRANCH and dynamic(a, star=False):
            raise Deny(UNSUPPORTED.format(
                "the push word " + a + ", which the shell expands before git sees it"))
    flags, positional, i, n = set(), [], 0, len(args)
    while i < n:
        a = args[i]
        if a == "--":
            raise Deny(UNSUPPORTED.format("the -- separator on the push invocation"))
        if a.startswith("--"):
            name, eq, value = a.partition("=")
            if name not in PUSH_LONG or (eq and name not in PUSH_LONG_WITH_VALUE):
                raise Deny(UNSUPPORTED.format("the push option " + a))
            if name == "--push-option":
                if not eq:
                    i += 1               # its value is the next word
                    value = args[i] if i < n else None
                push_option(value)
            flags.add(name)
        elif a.startswith("-") and len(a) > 1:
            for j, c in enumerate(a[1:], start=1):
                if c == "o":             # -o <option> or -o<option>: the rest is its value
                    if j == len(a) - 1:
                        i += 1
                        push_option(args[i] if i < n else None)
                    else:
                        push_option(a[j + 1:])
                    break
                if c not in PUSH_SHORT:
                    raise Deny(UNSUPPORTED.format("the push option -" + c))
                flags.add("-" + c)
        else:
            positional.append(a)
        i += 1
    remote = positional[0] if positional else None
    return flags, remote, positional[1:]


def recursing_submodules(repo):
    """The key=value that makes git push also push unpublished submodule commits, which the
    scan never sees (it reads only the gitlink), or None. git reads push.recurseSubmodules
    and submodule.recurse in config order and the last one decides: submodule.recurse=true
    means on-demand, whatever an earlier push.recurseSubmodules says. Only a false value, or
    check for push.recurseSubmodules, is taken as not recursing; an unreadable value is."""
    out = repo.run("config", "-z", "--get-regexp",
                   r"^(push\.recursesubmodules|submodule\.recurse)$") or ""
    decider = None
    for entry in out.split("\0"):
        if not entry:
            continue
        key, nl, value = entry.partition("\n")
        shown = value if nl else "true"                # a bare key is true
        off = nl and value.strip().lower() in ("false", "no", "off", "0", "")
        if key == "push.recursesubmodules":
            decider = None if off or value == "check" else "push.recurseSubmodules=" + shown
        else:
            decider = None if off else "submodule.recurse=" + shown
    return decider


def default_branch(repo, remote):
    head = repo.run("symbolic-ref", "--quiet", "--short", "refs/remotes/" + remote + "/HEAD")
    if head and head.strip().startswith(remote + "/"):
        return head.strip()[len(remote) + 1:]
    for ref in ("refs/remotes/" + remote + "/", "refs/heads/"):
        for name in ("main", "master"):
            if repo.has_ref(ref + name):
                return name
    return "main"


def delete_targets(flags, refspecs):
    """The branch names a delete-only push deletes, or None when the push also updates,
    prunes or force-pushes something, or deletes a ref that is not a plain branch."""
    if flags & NOT_DELETE_ONLY or not refspecs:
        return None
    deleting = "-d" in flags or "--delete" in flags
    names = []
    for spec in refspecs:
        if deleting:
            dst = spec
        elif spec.startswith(":"):
            dst = spec[1:]
        else:
            return None                                # it pushes something
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        if not dst or dst in ("HEAD", "@") or dst in CURRENT_BRANCH \
                or dst.startswith(DWIM_PREFIXES) or dst[0] in "+-:" or ":" in dst:
            return None
        names.append(dst)
    return names


def push_leases(args):
    """(ref, expected sha) for every --force-with-lease on the push: (None, None) for a bare
    one, (ref, None) for one without a sha. git matches a lease by refname and the first
    match wins, so every one counts, not only those that look like a pin."""
    leases = []
    for a in args:
        if a == "--force-with-lease":
            leases.append((None, None))
        elif a.startswith("--force-with-lease="):
            ref, colon, sha = a[len("--force-with-lease="):].partition(":")
            leases.append((ref, sha if colon else None))
    return leases


def plain_transport(url):
    """Whether url is a transport git runs without a helper program: a local path, file://,
    ssh:// (git+ssh:// and ssh+git:// too), https://, or the scp-like [user@]host:path."""
    if "::" in url:
        return False                                   # <helper>::<address>
    scheme, sep, _ = url.partition("://")
    if sep:
        return scheme in ("file", "ssh", "git+ssh", "ssh+git", "https")
    return True                                        # a path, or scp-like host:path (over ssh)


def other_checkout(root, session):
    """None when root, the toplevel of the repository a push runs in, is the toplevel of the
    session's cwd (the hook payload's); else root. A session cwd outside any repository makes
    every checkout another one, and so does a lookup that fails or times out: this only words
    a deny, so it must never raise and turn the deny into merged_delete's ask."""
    try:
        here = Repo(session, []).run("rev-parse", "--show-toplevel")
    except Deny:
        here = None
    return None if here is not None and here.strip() == root else root


def shell_word(word):
    """word quoted for the shell, as a deny reason prints it in a command: shlex.quote, and a
    word a shell option rewrites (SHELL_REWRITES: =x, x==y, a:=b, NAME=) is quoted too, since
    shlex counts = and : as safe."""
    quoted = shlex.quote(word)
    return "'" + word + "'" if quoted == word and SHELL_REWRITES.search(word) else quoted


def merged_delete(repo, remote, default, names, leases, root, session, plain=False, dry=False):
    """Whether a delete-only push of the branches in names goes without an ask: True when
    every one is merged and pinned; a deny reason naming the pinned command when every one
    is merged but a pin is missing or names another tip; None (an ask, as before) otherwise,
    a failed read of the remote included. A timeout anywhere in these checks asks as well:
    Repo.run raises it as a Deny, which here would turn today's ask into a deny. root is the
    toplevel the push runs in and session the payload's cwd: the pinned command is the plain
    git push form, and when root is not the session's checkout the reason names root. plain:
    the push is not canonical text, so the reason says a merged delete passes only when
    written in plain words. dry: the push carries a dry-run flag, so the printed command keeps
    -n; an agent that wanted a preview is never pointed at the real delete."""
    try:
        return check_merged_delete(repo, remote, default, names, leases, root, session, plain, dry)
    except Deny:
        return None


def check_merged_delete(repo, remote, default, names, leases, root, session, plain=False,
                        dry=False):
    """merged_delete without the timeout fallback.

    Merged: one ls-remote of the remote, whose single push URL is its fetch URL (evaluate
    refuses any other remote before this runs), shows its HEAD on the default branch and
    every branch present; the remote's default tip and every branch tip exist here; and
    each branch tip is an ancestor of both the remote's default tip and refs/heads/<default>,
    so its commits survive in both. A deleted head that is a symref on the remote asks.
    Pinned: every --force-with-lease on the push (bare and ref-only ones included) is
    exactly <branch>:<tip> or refs/heads/<branch>:<tip> for a deleted branch and the tip just
    read, and every deleted branch has one, so git refuses the delete if the branch moved
    after this read.

    This ls-remote is the guard's first network call and runs outside the sandbox, where git
    runs any command a config level names for it. A config file the sandbox can write could
    so run a command unsandboxed, just by a delete-shaped push. core.sshCommand, core.gitProxy
    and remote.<name>.vcs (which picks a git-remote-<vcs> helper whatever the URL says) ask
    instead, and so does a URL outside plain_transport, since a protocol.<name>.allow in
    config outranks the generic override and would let a git-remote-<name> helper run. The -c
    overrides below, which outrank every config file, drop the other protocols for the
    transports that remain, clear credential.helper and core.askPass, and pin protocol
    version 2, the only one whose ls-remote --symref shows the symref a non-HEAD head can be;
    --upload-pack overrides remote.<name>.uploadpack. The lookups after it (cat-file and
    merge-base) read only what is here, with lazy fetch off (LOCAL_ENV): a remote that config
    marks a promisor would otherwise have git fetch a missing tip from it, running its
    uploadpack, vcs and credential settings unsandboxed. A missing tip asks. They also ignore
    replacement objects, grafts and the commit-graph, which a write inside the sandbox could
    use to give an unmerged tip the default branch as a descendant."""
    if repo.config("core.sshCommand") is not None or repo.config("core.gitProxy") is not None \
            or repo.config("remote." + remote + ".vcs") is not None:
        return None
    url = repo.run("remote", "get-url", remote)
    if url is None or not plain_transport(url.strip()):
        return None
    heads = ["refs/heads/" + n for n in [default] + names]
    out = repo.run("-c", "protocol.version=2",
                   "-c", "protocol.allow=never", "-c", "protocol.ext.allow=never",
                   "-c", "protocol.file.allow=always", "-c", "protocol.ssh.allow=always",
                   "-c", "protocol.https.allow=always", "-c", "credential.helper=",
                   "-c", "core.askPass=",
                   "ls-remote", "--upload-pack=git-upload-pack", "--symref", remote, "HEAD", *heads,
                   env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
    if out is None:
        return None
    tips, remote_head = {}, None
    for line in out.splitlines():
        left, tab, ref = line.partition("\t")
        if not tab:
            continue
        if left.startswith("ref: "):
            if ref == "HEAD":
                remote_head = left[len("ref: "):].strip()
            elif ref in heads:
                return None                            # a symref: deleting it is not deleting a branch
        elif ref in heads:
            tips[ref] = left.strip()
    local_default = "refs/heads/" + default
    if remote_head != local_default or not repo.has_ref(local_default):
        return None
    if not all(SHA_RE.fullmatch(tips.get(h, "")) for h in heads):
        return None
    if any(repo.run(*LOCAL_OPTS, "cat-file", "-e", tips[h] + "^{commit}", env=LOCAL_ENV) is None
           for h in heads):
        return None
    for n in names:
        for target in (tips[local_default], local_default):
            if repo.run(*LOCAL_OPTS, "merge-base", "--is-ancestor", tips["refs/heads/" + n],
                        target, env=LOCAL_ENV) is None:
                return None

    def pin_of(n, lease):
        return lease in ((n, tips["refs/heads/" + n]), ("refs/heads/" + n, tips["refs/heads/" + n]))

    if all(any(pin_of(n, lease) for n in names) for lease in leases) \
            and all(any(pin_of(n, lease) for lease in leases) for n in names):
        return True
    # Quoted (shell_word): git allows ', ; $, backticks and a leading = in a branch name, and
    # this text is a command to run.
    pins = " ".join(shell_word("--force-with-lease={}:{}".format(n, tips["refs/heads/" + n]))
                    for n in names)
    command = "git push {}{} {} --delete {}".format(
        "-n " if dry else "", pins, shell_word(remote), " ".join(shell_word(n) for n in names))
    if dry:
        lead = DRY_REFUSED + " "
    elif plain:
        lead = "Push guard: a merged delete passes only when written in " + PLAIN_WORDS + ". "
    else:
        lead = "Push guard: "
    merged = "{}{} {} merged into {}, on {}".format(
        lead, ", ".join(names), "is" if len(names) == 1 else "are", default, remote)
    there = other_checkout(root, session)
    if dry:
        # A dry run: worded as one, and the printed command keeps -n.
        if there is None and canonical(command):
            return "{} and here. Run the dry run in plain words: {}".format(merged, command)
        if there is None:
            return ("{} and here. A name here needs quoting, which plain words cannot carry, so "
                    "Michael runs the dry run: {}").format(merged, command)
        if canonical(command):
            return ("{} and in {}, which is not this session's checkout. Run the plain dry run "
                    "from that repository: {}").format(merged, shell_word(there), command)
        return ("{} and in {}, which is not this session's checkout. A name here needs quoting, "
                "which plain words cannot carry, so Michael runs the dry run there: {}").format(
                    merged, shell_word(there), command)
    if there is None and not canonical(command):
        # A branch or remote name that needs quoting: no command for it is canonical, so none
        # passes.
        return ("{} and here. Pin the delete to the tip just read, so git refuses it if the "
                "branch has moved. A name here needs quoting, which plain words cannot carry, "
                "so Michael runs it: {}").format(merged, command)
    if there is None:
        return ("{} and here. Pin the delete to the tip just read, so git refuses it if the "
                "branch has moved, and it needs no ask: {}").format(merged, command)
    # No git -C form: the classifier rule names only the plain form.
    return ("{} and in {}, which is not this session's checkout. Pin the delete to the tip just "
            "read, so git refuses it if the branch has moved; the delete must run from that "
            "checkout, or Michael runs it: {}").format(merged, shell_word(there), command)


def dry_run_deny(asks, args, root, session):
    """The deny for a dry run outside canonical text whose real-push verdict is an ask (spec
    2026-10-28, section 2, Dry runs): a silent deny costs Michael no prompt. It says, in order:
    the dry run is refused because it is not in plain words; the plain -n form, where one can be
    printed (the canonical dry run in the session's checkout, or the plain -n form to run from
    the push's own repository); and that the push it previews needs Michael's confirmation, so
    the agent confirms with him rather than preview it this way. It never offers the real push:
    every push it previews is one the guard asks about (a delete, a default-branch push, a force
    push without a lease, or --all or --mirror), each needing Michael's confirmation. A printed
    command stands on a line of its own, so no sentence punctuation runs into it."""
    command = "git push " + " ".join(shell_word(a) for a in args)
    there = other_checkout(root, session)
    confirm = ("The push it previews needs Michael's confirmation before it runs, because {}: "
               "confirm it with him rather than preview it this way.").format("; ".join(asks))
    if there is None and canonical(command):
        return "{}\nRun it in plain words, from this checkout:\n  {}\n{}".format(
            DRY_REFUSED, command, confirm)
    if there is not None and canonical(command):
        return ("{}\nIt runs in {}, which is not this session's checkout. Run the plain -n form "
                "from that repository:\n  {}\n{}").format(DRY_REFUSED, shell_word(there), command,
                                                        confirm)
    return "{} {}".format(DRY_REFUSED, confirm)


# ------------------------------------------------------------------ the secret scan
def run_gitleaks(cmd, cwd, env):
    """(returncode, stdout, stderr) of gitleaks, within what is left of the budget. It runs
    in its own process group so a timeout takes gitleaks and the git it spawned down
    together: a survivor holding the pipes would keep this helper (and the hook) waiting."""
    remaining = BUDGET - (time.monotonic() - START)
    if remaining <= 0:
        raise Deny(TIMED_OUT)
    try:
        p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, encoding="utf-8", errors="replace",
                             start_new_session=True)
    except OSError as e:
        raise Deny("Push guard: gitleaks could not run ({}), so the push is refused.".format(e))
    try:
        out, err = p.communicate(timeout=remaining)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            p.kill()
        p.communicate()
        raise Deny("Push guard: the gitleaks scan did not finish within the push guard's time "
                   "budget, so the push is refused. Scan by hand (gitleaks git --redact) and "
                   "push by hand.")
    return p.returncode, out, err


def expected_commits(repo, remote, sources, env):
    """How many outgoing commits gitleaks must report scanning: those whose patch has a hunk
    (@@) in a file that is not deleted. gitleaks counts a commit for every file it reads a
    hunk from, a hunk that only removes lines included, and skips a deleted file; a file
    with no hunk (a pure rename, a mode change, an empty new file) gives it nothing. So an
    empty commit, a clean merge or a commit that only deletes files is not counted, and a
    commit that only removes lines is. It reads the same `git log -p` stream with the same
    options and pins gitleaks is given, so the two counts agree unless gitleaks lost
    something. Run through Repo.run, under the same budget as every git call.
    The listing is read as bytes and split at LF alone, as gitleaks splits it. Decoded text
    also breaks at CR, and --text puts a binary file's bytes in the patch: a GIF, PNG or font
    holding CR before the 0x01 marker or @@ gave phantom commits and hunks, so 598 expected
    where gitleaks rightly scanned all 573 outgoing commits."""
    out = repo.run("log", "-p", "-U0", "--no-color", "--format=%x01%H", *PATCH_OPTS,
                   *(list(sources) + ["--not", "--remotes=" + remote]), env=env, long=True,
                   raw=True)
    if out is None:
        raise Deny("Push guard: git could not list the outgoing commits ({}), so the secret "
                   "scan cannot show it covered them and the push is refused. Push by hand."
                   .format(" ".join(sources)))
    # A hunk line never starts with \x01, "diff ", "deleted file mode" or @@: every line of
    # a hunk starts with +, -, a space or a backslash.
    count, scanned, deleted = 0, False, False
    for line in out.split(b"\n"):
        if line.startswith(b"\x01"):
            count += 1 if scanned else 0
            scanned, deleted = False, False
        elif line.startswith(b"diff "):
            deleted = False                            # a file header: a new file
        elif line.startswith(b"deleted file mode "):
            deleted = True
        elif line.startswith(b"@@") and not deleted:
            scanned = True
    return count + (1 if scanned else 0)


def scan(root, remote, sources):
    """gitleaks over the commits this push would send. Returns on a clean scan and
    raises Deny otherwise; a scan that cannot run, or cannot prove it covered the commits,
    is a deny, never a pass.
    The scan runs gitleaks' default rules only: a gitleaks config file (.gitleaks.<ext>, in
    any letter case) in the working tree or committed on a pushed ref is an unsupported
    configuration, and the push is refused naming it.
    --ignore-gitleaks-allow: the only exception is a reviewed .gitleaksignore entry, never
    an inline comment. gitleaks reads .gitleaksignore from the working
    tree, so a copy that is not byte-identical to the one committed on HEAD and on every
    pushed ref (untracked, ignored, modified, hidden by skip-worktree or
    status.showUntrackedFiles, or committed on another branch) is refused: commit it first,
    and the exception is reviewed like any other change. A push by pattern (--tags, --all,
    --mirror) names no refs to compare, so with an exception file present it is refused and
    the refs must be pushed by name. Every git call here runs with
    replace refs off (GIT_NO_REPLACE_OBJECTS), since a push sends the real objects. GITLEAKS_*
    variables are dropped from the environment for the same reason. Lazy fetch is off
    for every git call and for gitleaks (GIT_NO_LAZY_FETCH): the repository's configuration
    stays agent-writable, so a promisor remote is never trusted. A genuine blob-filtered
    partial clone is denied with the "Push by hand" message. Commit and
    annotated-tag messages are not scanned (gitleaks git mode scans patches only)."""
    exe = shutil.which("gitleaks")
    if not exe:
        raise Deny("Push guard: gitleaks is not installed, so the outgoing commits cannot be "
                   "scanned for secrets and the push is refused. Install it with: "
                   "brew bundle --file ~/.config/homebrew/Brewfile")
    repo = Repo(root, [])
    env = {k: v for k, v in os.environ.items() if not k.startswith("GITLEAKS_")}
    # A replace ref swaps an object for another in git log, but pack-objects sends the real
    # one: the scan must read what will be sent, in every git call it makes.
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    env["GIT_NO_LAZY_FETCH"] = "1"
    env["GIT_CONFIG_COUNT"] = str(len(GIT_LOG_DEFAULTS))
    for i, (key, value) in enumerate(GIT_LOG_DEFAULTS):
        env["GIT_CONFIG_KEY_%d" % i] = key
        env["GIT_CONFIG_VALUE_%d" % i] = value
    outgoing = repo.run("rev-list", *(list(sources) + ["--not", "--remotes=" + remote]),
                        env=env)
    if outgoing is None:
        raise Deny("Push guard: git could not list the outgoing commits ({}), so the secret "
                   "scan cannot show it covered them and the push is refused. Push by hand."
                   .format(" ".join(sources)))
    if not outgoing.strip():
        return                                         # nothing leaves: nothing to scan
    # A gitleaks config in the working tree would steer this scan, and one committed on a
    # pushed ref is a configuration this scan does not honour.
    try:
        names = sorted(os.listdir(root))
    except OSError as e:
        raise Deny("Push guard: cannot list {} ({}), so the guard cannot rule out a gitleaks "
                   "config there and the push is refused. Push by hand.".format(root, e))
    for name in names:
        if GITLEAKS_CONFIG_RE.fullmatch(name):
            raise Deny(UNSUPPORTED.format("the gitleaks config file " + name + " in the working tree"))
    for source in sources:
        trees = repo.run("log", "--no-walk", "--format=%T", source, "--", env=env)
        listed = [repo.run("ls-tree", "-z", "--name-only", tree, env=env)
                  for tree in sorted(set((trees or "").split()))]
        if trees is None or None in listed:
            raise Deny("Push guard: git could not list the files of {}, so the guard cannot rule "
                       "out a gitleaks config committed there and the push is refused. Push by "
                       "hand.".format(source))
        for name in "\0".join(listed).split("\0"):
            if GITLEAKS_CONFIG_RE.fullmatch(name):
                raise Deny(UNSUPPORTED.format(
                    "the gitleaks config file " + name + " committed on " + source))
    # The worktree copy is what gitleaks reads, so it must be the committed one on HEAD and on
    # every ref pushed: an exception committed on another branch reviews nothing here.
    present = [n for n in EXCEPTION_FILES if os.path.lexists(os.path.join(root, n))]
    # A pseudo-source (--tags, --branches, --all) stands for refs this check does not list,
    # so none of them could be compared: with an exception in play, only named refs go.
    if present and any(x.startswith("-") for x in sources):
        raise Deny("Push guard: this push sends refs by pattern (--tags, --all or --mirror) and "
                   "the working tree holds {}, so the guard cannot show that exception is "
                   "committed on every ref it sends. Push the branches and tags by name "
                   "(git push {} <branch-or-tag> ...), so each one is checked."
                   .format(" and ".join(present), remote))
    refs = ["HEAD"] + [x for x in sources if x != "HEAD"]
    for name in present:
        worktree = repo.run("hash-object", "--no-filters", "--", name, env=env)
        for ref in refs:
            committed = repo.run("rev-parse", "--verify", "--quiet", ref + ":" + name, env=env)
            if worktree is None or committed is None or worktree.strip() != committed.strip():
                raise Deny("Push guard: {0} differs from {1}:{0} (or {1} has none), so it "
                           "cannot decide what the secret scan skips. Commit the exception "
                           "first, on the ref being pushed (a fingerprint in "
                           ".gitleaksignore), then push.".format(name, ref))
    # Never skipped on an expected count of 0: that count is only as good as git's view of
    # the patches, and gitleaks must agree with it.
    expected = expected_commits(repo, remote, sources, env)
    log_opts = " ".join(list(sources) + PATCH_OPTS + ["--not", "--remotes=" + remote])
    fd, report = tempfile.mkstemp(prefix="push-guard-", suffix=".json")
    os.close(fd)
    try:
        code, out, err = run_gitleaks(
            [exe, "git", "--no-banner", "--no-color", "--redact", "--ignore-gitleaks-allow",
             "--exit-code", str(GITLEAKS_LEAKS_EXIT),
             "--report-format", "json", "--report-path", report,
             "--log-opts=" + log_opts, root], root, env)
        if code == GITLEAKS_LEAKS_EXIT:
            raise Deny(leak_reason(report, remote))
        tail = "\n".join((err or out or "").strip().splitlines()[-5:])
        if code != 0:
            raise Deny("Push guard: gitleaks failed (exit {}), so the push is refused:\n{}"
                       .format(code, tail))
        # A clean exit proves nothing on its own: gitleaks reports "no leaks found" and exits
        # 0 when its own git log fails or is misparsed (color.diff=always once gave 0
        # commits scanned). Only a scan of every commit with a hunk counts as clean.
        seen = SCANNED_RE.findall(err or "")
        if ERR_RE.search(err or ""):
            raise Deny("Push guard: gitleaks logged an error while scanning, so the push is "
                       "refused:\n{}".format(tail))
        if not seen or int(seen[-1]) != expected:
            raise Deny("Push guard: gitleaks scanned {} commit(s) but this push carries {} "
                       "with changes to scan, so the scan is not trusted and the push is "
                       "refused. Check the git log configuration, or scan by hand "
                       "(gitleaks git --redact) and push by hand.".format(
                           seen[-1] if seen else "an unknown number of", expected))
    finally:
        try:
            os.unlink(report)
        except OSError:
            pass


def leak_reason(report, remote):
    try:
        with open(report, encoding="utf-8") as fh:
            findings = json.load(fh)
    except (OSError, ValueError):
        findings = []
    lines = ["- rule {} in {} at commit {} (fingerprint {})".format(
        f.get("RuleID", "?"), f.get("File", "?"), str(f.get("Commit", "?"))[:12],
        f.get("Fingerprint", "?")) for f in findings[:10]]
    if len(findings) > 10:
        lines.append("- and {} more".format(len(findings) - 10))
    return ("Push guard: gitleaks found {} secret(s) in the commits this push would send to {}:\n"
            "{}\n\n"
            "Take the secret out of those commits (rewrite the branch), and rotate it if it is "
            "real. If a finding is a false positive, add its fingerprint as a line in the "
            "repository's tracked .gitleaksignore and commit that, so the exception is "
            "reviewed like any other change.").format(
                len(findings) or "one or more", remote,
                "\n".join(lines) or "- (the gitleaks report could not be read)")


# ------------------------------------------------------------------ one push
def evaluate(cwd, assigns, repo_opts, config_opts, args, session, bare=False):
    """None to allow, a reason string to ask; raises Deny to deny. session is the hook
    payload's cwd, for the deny reasons that print a corrected push. bare: the raw command
    is canonical text (canonical); only a bare delete-only push of merged, pinned branches
    passes silently."""
    flags, remote_arg, refspecs = parse_push(args)
    # A dry run returns early, never scanned and never asked, only when the raw command is
    # canonical text and git reads it as a dry run (spec 2026-10-28, section 2, Dry runs).
    # parse_push has refused every word git could read otherwise: every negation it does not
    # allow (all but --no-verify, so --no-dry-run and its abbreviations --no-dry and --no-dr),
    # every abbreviation such as --dry, --, and a -o value outside the allowed ones (-on is a
    # push option in git). So -n, bundled or not, or --dry-run in flags is git's own
    # reading (measured against git 2.56). Any other dry run is judged as a real push: its
    # words may reach git as others, as a glob that expands to --no-dry-run does. Where that
    # verdict is an ask, the dry run gets a silent deny instead (dry_run_deny): no prompt.
    if ("-n" in flags or "--dry-run" in flags) and bare:
        return None                                    # never scanned, never asked
    if config_opts:
        raise Deny(UNSUPPORTED.format("a " + config_opts[0] + " option on the push invocation"))
    for opt in repo_opts:
        name = opt.split("=", 1)[0]
        if name.startswith("--"):
            # Only -C resolves the way the scan needs; --git-dir and --work-tree would
            # leave it reading the wrong tree.
            raise Deny(UNSUPPORTED.format(name + " on the push invocation"))
    for name in assigns:
        if GIT_ENV_UNSUPPORTED.match(name):
            raise Deny(UNSUPPORTED.format(name + " set on the push invocation"))

    repo = Repo(cwd, repo_opts)
    root = repo.run("rev-parse", "--show-toplevel")
    if not root or not root.strip():
        raise Deny("Push guard: cannot resolve the repository this push runs in ({}). Run it "
                   "from inside the repository, or as git -C <path> push.".format(cwd))
    root = root.strip()

    push_default = repo.config("push.default")
    if push_default not in (None, "simple", "current"):
        raise Deny(UNSUPPORTED.format("push.default=" + push_default))
    if repo.config("remote.pushDefault") is not None:
        raise Deny(UNSUPPORTED.format("remote.pushDefault"))
    # git sends these when the command line names no push option.
    for value in (repo.run("config", "-z", "--get-all", "push.pushOption") or "").split("\0"):
        if value:
            push_option(value, " (from push.pushOption)")
    # --recurse-submodules is not a modelled option, so parse_push already refuses it.
    recursing = recursing_submodules(repo)
    if recursing:
        raise Deny(UNSUPPORTED.format(recursing + ", which also pushes submodule commits"))
    branch = repo.run("symbolic-ref", "--quiet", "--short", "HEAD")
    branch = branch.strip() if branch else None
    if branch and repo.config("branch." + branch + ".pushRemote") is not None:
        raise Deny(UNSUPPORTED.format("branch." + branch + ".pushRemote"))
    remote = remote_arg or (branch and repo.config("branch." + branch + ".remote")) or "origin"
    if remote not in (repo.run("remote") or "").split():
        raise Deny(UNSUPPORTED.format("a push to " + remote + ", which is not a configured remote"))
    for key in ("remote." + remote + ".push", "remote." + remote + ".mirror"):
        if repo.config(key) is not None:
            raise Deny(UNSUPPORTED.format(key))
    push_urls = (repo.run("remote", "get-url", "--push", "--all", remote) or "").split("\n")
    push_urls = [u for u in push_urls if u.strip()]
    fetch_url = (repo.run("remote", "get-url", remote) or "").strip()
    if len(push_urls) != 1 or push_urls[0].strip() != fetch_url:
        raise Deny(UNSUPPORTED.format(
            "remote." + remote + " pushes somewhere other than it fetches from "
            "(pushurl, a second url, or pushInsteadOf)"))

    default = default_branch(repo, remote)
    asks, sources, dests = [], [], []
    deleting = "-d" in flags or "--delete" in flags
    if "--mirror" in flags or "--all" in flags:
        asks.append("it pushes every ref (--mirror or --all)")
    if deleting or "--prune" in flags:
        asks.append("it deletes remote refs (--delete, -d or --prune)")
    if "-f" in flags or "--force" in flags:
        asks.append("it force-pushes without a lease (--force or -f)")
    for spec in refspecs:
        s = "HEAD" if spec in CURRENT_BRANCH else spec
        if s.startswith("+"):
            asks.append("the refspec " + spec + " force-pushes without a lease")
            s = s[1:]
        if "*" in s:
            # Denied, not asked: a wildcard names no branches, so there is nothing to scan,
            # and an approved ask would publish whatever it matched unscanned.
            raise Deny("Push guard: the wildcard refspec " + spec + " can update any branch, "
                       "the default branch included, and names no commits to scan. Push the "
                       "branches by name, or push by hand.")
        src, colon, dst = s.partition(":")
        if colon and not dst:
            # `:` and `+:` push every matching branch; `x:` names no destination.
            raise Deny(UNSUPPORTED.format("the refspec " + spec + ", which names no single "
                                          "destination (: pushes every matching branch)"))
        if colon and not src:
            asks.append("the refspec " + spec + " deletes " + dst + " on " + remote)
            continue
        if deleting:
            continue                                   # these name refs to delete
        if src.startswith("-"):
            raise Deny("Push guard: cannot read the refspec " + spec + ".")
        if src in ("HEAD", "@"):
            src = "HEAD"
            if not colon:
                if not branch:
                    raise Deny("Push guard: HEAD is detached, so " + spec + " names no branch. "
                               "Name the destination: git push " + remote + " HEAD:<branch>.")
                dst = branch
        elif not colon:
            dst = src
        if (colon or src != "HEAD") and not dst.startswith("refs/heads/") \
                and dst.startswith(DWIM_PREFIXES):
            # git resolves heads/main, tags/x and refs/... to the ref of that name, so
            # feat:heads/main updates main while looking like a branch called heads/main.
            # Only refs/heads/<name> is read; a plain name with a slash (feat/x) is fine.
            raise Deny(UNSUPPORTED.format(
                "the destination " + dst + ", which git resolves as a ref path; name the "
                "branch (main) or write refs/heads/<branch>"))
        sources.append(src)
        dests.append(dst)
    if not refspecs and not (deleting or flags & {"--tags", "--all", "--mirror"}):
        if not branch:
            raise Deny("Push guard: HEAD is detached, so a push without a refspec has no branch "
                       "to push. Name the destination: git push " + remote + " HEAD:<branch>.")
        sources.append("HEAD")
        dests.append(branch)
    for dst in dests:
        name = dst[len("refs/heads/"):] if dst.startswith("refs/heads/") else dst
        if not name.startswith("refs/") and name == default:
            asks.append("it updates " + default + ", the default branch of " + remote)

    # The scan runs before any ask is returned: a push Michael approves must already be
    # clean, and a secret is a deny, which beats an ask.
    scan_sources = list(sources)
    if "--tags" in flags:
        scan_sources.append("--tags")
    if "--all" in flags:
        scan_sources.append("--branches")
    if "--mirror" in flags:
        scan_sources.append("--all")
    if scan_sources:
        scan(root, remote, scan_sources)

    # A delete-only push of merged branches, each pinned to the tip read here and written
    # bare (canonical text, nothing before git or between git and push), needs no ask; merged
    # but unpinned, or not bare, is a silent deny naming the plain pinned command. The
    # classifier rule trusts this pass, so the words verified must be the words the shell
    # runs. delete_targets admits no flag or refspec that adds any other ask, so the asks it
    # replaces are delete asks.
    targets = delete_targets(flags, refspecs)
    if asks and targets is not None and default not in targets:
        # Not bare: no lease counts, so a merged delete cannot come back True; the deny names
        # the bare pinned command instead.
        leases = push_leases(args) if bare else []
        verdict = merged_delete(repo, remote, default, targets, leases, root, session,
                                plain=not bare, dry="-n" in flags or "--dry-run" in flags)
        if verdict is True:
            return None
        if verdict:
            raise Deny(verdict)

    if asks:
        if "-n" in flags or "--dry-run" in flags:
            raise Deny(dry_run_deny(asks, args, root, session))
        return "Push guard: this push needs Michael, because " + "; ".join(asks) + "."
    return None


def literal_trigger():
    """True when the guard's fast path saw the push as written; false when only a hidden spelling started us."""
    return os.environ.get("PUSH_GUARD_LITERAL") == "1"


def raw_checks_enabled():
    """Main's raw checks run unless the fast path said, with a flag of exactly 0, that no push
    was written: a lost or unset flag is the strictest reading (the raw checks run and an ask
    becomes a deny), never a looser one."""
    return os.environ.get("PUSH_GUARD_LITERAL") != "0"


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = payload.get("tool_input", {}).get("command") or ""
        cwd = payload.get("cwd") or os.getcwd()
    except (ValueError, AttributeError):
        return
    if not cmd:
        return
    shape = None
    try:
        try:
            tokens = tokenize(cmd)
        except ValueError:
            tokens = None                              # unbalanced quotes: not plain
        if tokens is not None and not outside_grammar(cmd):
            shape = parse_plain(tokens, cwd)
        elif tokens is not None:
            # Outside the grammar: could_push first, which is cheap and denies most; the probe
            # runs the full judge, so it runs only when could_push did not already deny. A
            # deny from either is the plain-push deny, and so is a could_push that fails. The
            # probe is main's own refusal: it runs only when the fast path saw a push as
            # written, so under PUSH_GUARD_LITERAL=0 only a hidden spelling can deny here.
            try:
                hit = could_push(cmd, tokens, cwd)
            except Exception:
                hit = True
            if hit or (raw_checks_enabled() and probe_refuses(tokens, cmd, cwd)):
                raise Deny(PLAIN)
            return
        if shape is None:
            if could_push(cmd, tokens, cwd):           # the raw text: a superset, never trimmed
                raise Deny(PLAIN)
            return
        reason = judge(shape, cwd, canonical(cmd))
    except Deny as d:
        print(decision("deny", str(d)))
        return
    except Exception as e:                             # a bug here must not open the gate
        # A plain git command may be an alias push (git pom): it fails closed as well.
        if shape is not None or PUSH_SHAPE.search(cmd):
            print(decision("deny", "Push guard: internal error ({}: {}), so the push is "
                                   "refused. Push by hand.".format(type(e).__name__, e)))
        elif not literal_trigger():
            print(decision("deny", PLAIN))
        return
    if reason:
        if not literal_trigger():
            print(decision("deny", PLAIN))
            return
        print(decision("ask", reason))


if __name__ == "__main__":
    main()
