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
# Secrets: a push that would ask is scanned by secret-scan (dot_config/git/hooks, deployed to
# ~/.config/git/hooks) before the ask is returned, so a secret is a deny, which beats an ask.
# Every push is scanned by the global pre-push hook too, so a push that passes here silently is
# scanned here only when the hook may not see it (hook_will_run): --no-verify, an assignment or
# wrapper that could move git's configuration, or a core.hooksPath that is not the deployed
# hooks directory. The verdict for a scanned push is main's.
#
# Fail direction: a push this cannot resolve is DENIED with a reason the agent can act on.
# It never asks on doubt (an ask costs Michael a prompt) and never allows on doubt (a push
# is the one irreversible outward path).
#
# Rule 4 judges the plain push an agent is told to write, and refuses a literal push it cannot
# parse: git and push in one segment of its text (outside the arguments of inert commands), git
# and a push alias, or git-push by name. Anything else is not its job. A push spelled to hide
# (quotes, escapes, globs, a word built at run time) is left to the forge, which refuses what
# matters on a protected default branch, and to the classifier; the Residual section of
# docs/superpowers/specs/2026-11-12-forge-push-protection-design.md names the remotes the forge
# does not cover.
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
# Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

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
GIT_WORD_RE = re.compile(r"\bgit\b")
PUSH_WORD_RE = re.compile(r"\bpush\b")
SEGMENT_SPLIT = re.compile(r"[;&|\n]")


def git_tails(text):
    """(segment, end of its first git word) for each segment of text (a maximal run of characters
    other than ; & | and a newline) that holds a git word. The old pattern, a git word then
    anything but ; & | and a newline, then WORD, matches exactly when some git word has WORD after
    it in its segment, and the first git word of a segment is the best one (any later git word's
    tail is a part of its tail), so one search for WORD from the end of the first git word
    decides a segment. The old pattern started a scan at every git word and was quadratic on a
    long line of them. The word boundaries see the real neighbours, a segment edge being a
    separator."""
    out = []
    for seg in SEGMENT_SPLIT.split(text):
        m = GIT_WORD_RE.search(seg)
        if m:
            out.append((seg, m.end()))
    return out


def tails_match(tails, regex):
    """Does regex match after the first git word of some segment of git_tails?"""
    return any(regex.search(seg, pos) is not None for seg, pos in tails)


def push_shape(text):
    """PUSH_SHAPE.search(text) is not None, in linear time."""
    return tails_match(git_tails(text), PUSH_WORD_RE)


def alias_text_hit(text, names):
    """Does git, then one of the alias names as a word, stand in one segment of text (the old
    pattern, per name)?"""
    tails = git_tails(text)
    return any(tails_match(tails, re.compile(r"\b" + re.escape(a) + r"\b")) for a in names)
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
PLAIN = ("Push guard: this command may run git push in a shape the guard does not check. Run "
         "the push as a plain command of its own: git push [options] <remote> <branch> "
         "(for another repository: git -C <path> push [options] <remote> <branch>; piped only "
         "to tail or head). If the command does not push, keep git and push apart in its text "
         "with a bracket, for example rg 'git pu[s]h'.")


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
def tokenize(cmd):
    """Shell words and operator tokens. Raises ValueError on unbalanced quotes."""
    lx = shlex.shlex(cmd.replace("\\\n", " "), posix=True, punctuation_chars=PUNCT)
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
    wrapped = i < n and t[i] in ("command", "sudo", "env")
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
    return {"cwd": cwd, "cd_used": cd_used, "assigns": assigns, "wrapped": wrapped,
            "repo_opts": repo_opts, "config_opts": config_opts, "unknown": unknown, "sub": sub,
            "args": args}


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
# Shell reserved words: the word after one is still in command position.
RESERVED = {"if", "then", "elif", "else", "do", "while", "until", "!", "{"}


def starts_command(tok):
    """An operator after which a new command begins (not a redirect)."""
    return is_operator(tok) and "<" not in tok and ">" not in tok


def command_words(tokens):
    """Indexes of the words in command position: at the start, after an operator, after
    VAR=value assignments, and after a wrapper (command, env, sudo, time, xargs, ...)."""
    out, i, n, at = [], 0, len(tokens), True
    while i < n:
        t = tokens[i]
        if starts_command(t):
            at = True
        elif not is_operator(t) and at:
            if ASSIGN_RE.match(t) or t in RESERVED:
                pass
            elif os.path.basename(t) in WRAPPERS:
                while i + 1 < n and not is_operator(tokens[i + 1]) and (
                        tokens[i + 1].startswith("-") or ASSIGN_RE.match(tokens[i + 1])):
                    i += 1
            else:
                out.append(i)
                at = False
        i += 1
    return out


def dash_push_word(tokens):
    """A command word that is git-push, git-send-pack or git-http-push by name (the dash form,
    also behind a path)."""
    return any(os.path.basename(tokens[k]) in DASH_PUSH for k in command_words(tokens))


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
    """For a command outside the grammar: could it run git push? git and push in one segment
    of its text, git and a push alias (from cwd, or a repository a -C, --git-dir or GIT_DIR in
    it names), git-push by name, or git under a GIT_CONFIG override. The text is cmd without
    the arguments of provably inert commands (inert_text); no shape is parsed."""
    text = inert_text(cmd, tokens)
    if push_shape(text):
        return True
    if tokens and dash_push_word(tokens):
        return True
    if not re.search(r"\bgit\b", cmd):
        return False
    if "GIT_CONFIG" in cmd:
        return True
    selectors = {()}                                   # a set: each one costs a git call
    for k, tok in enumerate(tokens or []):
        if tok in ("-C", "--git-dir") and k + 1 < len(tokens):
            selectors.add((tok, os.path.expanduser(tokens[k + 1])))
        elif tok.startswith("--git-dir="):
            selectors.add((tok,))
        elif tok.startswith("GIT_DIR="):
            selectors.add(("--git-dir=" + tok.split("=", 1)[1],))
    names = set()
    for sel in sorted(selectors):
        try:
            names |= push_aliases(cwd, list(sel))
        except Deny:
            raise
        except Exception:
            return True                     # a listing that fails cannot rule a push out
    return alias_text_hit(text, names)


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
                    text, s["wrapped"])


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
# One deployed copy, beside the global pre-push hook (dot_config/git/hooks/secret-scan). The
# guard trusts that path, which sandboxed sessions cannot write; PUSH_GUARD_SCAN exists only so
# the test suite can point at the source copy or at a missing file.
SCAN = os.environ.get("PUSH_GUARD_SCAN") or os.path.join(
    os.path.expanduser("~"), ".config", "git", "hooks", "secret-scan")


def run_scan(root, remote, destination, sources):
    """secret-scan over the commits a push that would ask sends. Returns on a clean scan and
    raises Deny otherwise, with the scan's own reason: a scan that cannot run is a deny, never
    a pass. The scan gets what is left of the budget less a second, so its own timeout reason
    comes first. The scan runs in its own session, and at the budget its process group is
    killed: the scan itself and the git calls it makes. That kill does not reach gitleaks:
    secret-scan starts gitleaks in a session of its own, so a gitleaks the scan has not yet
    reaped can outlive this kill. In normal operation it never comes to that: the scan's own
    budget is a second shorter, so the scan ends first and kills its gitleaks itself. A
    survivor holds none of this helper's pipes, so it cannot keep this helper waiting."""
    remaining = BUDGET - (time.monotonic() - START)
    if remaining <= 0:
        raise Deny(TIMED_OUT)
    cmd = [sys.executable, "-I", SCAN, "--repo", root, "--remote", remote,
           "--destination", destination, "--budget", str(max(remaining - 1, 0.1)),
           "--"] + list(sources)
    could_not = ("Push guard: the secret scan ({}) could not run ({}), so the push is refused. "
                 "Restore it with chezmoi apply, or push by hand.")
    if not os.path.isfile(SCAN):
        raise Deny(could_not.format(SCAN, "no such file"))
    try:
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, encoding="utf-8", errors="replace",
                             start_new_session=True)
    except OSError as e:
        raise Deny(could_not.format(SCAN, e))
    try:
        out, err = p.communicate(timeout=remaining)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            p.kill()
        p.communicate()
        raise Deny(TIMED_OUT)
    if p.returncode != 0:
        raise Deny((err or "").strip() or
                   "Push guard: the secret scan ({}) refused the push (exit {}) without a "
                   "reason, so the push is refused. Push by hand.".format(SCAN, p.returncode))


def hook_will_run(repo, root, flags, assigns, wrapped):
    """True only when the deployed global pre-push hook is certain to scan this push: no
    --no-verify (git runs the hook for a dry run too); no environment assignment (HOME,
    XDG_CONFIG_HOME, PATH and the rest could move git's configuration or the hook it finds)
    and no wrapper (sudo changes HOME) on the command; and the repository's effective
    core.hooksPath, read as git reads it, is the directory that holds the scan this helper
    would run, with an executable pre-push beside it. Anything that cannot be shown is False:
    a push the hook may not see is scanned here."""
    if wrapped or assigns or "--no-verify" in flags:
        return False
    configured = repo.run("config", "--type=path", "--get", "core.hooksPath")
    if not configured or not configured.strip():
        return False
    hooks = os.path.realpath(os.path.join(root, configured.strip()))
    hook = os.path.join(hooks, "pre-push")
    return (hooks == os.path.realpath(os.path.dirname(SCAN)) and os.path.isfile(SCAN)
            and os.path.isfile(hook) and os.access(hook, os.X_OK))


# ------------------------------------------------------------------ one push
def evaluate(cwd, assigns, repo_opts, config_opts, args, session, bare=False, wrapped=True):
    """None to allow, a reason string to ask; raises Deny to deny. session is the hook
    payload's cwd, for the deny reasons that print a corrected push. bare: the raw command
    is canonical text (canonical); only a bare delete-only push of merged, pinned branches
    passes silently. wrapped: the command runs git through command, env or sudo; a caller
    that does not say is read as wrapped, the reading that scans."""
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

    # An asking push is scanned by secret-scan before the ask is returned: a push Michael
    # approves must already be clean, and a secret is a deny, which beats an ask. A push that
    # passes silently is scanned here too unless the global pre-push hook is certain to run
    # for it (hook_will_run), so no push goes unscanned that main would have scanned.
    scan_sources = list(sources)
    if "--tags" in flags:
        scan_sources.append("--tags")
    if "--all" in flags:
        scan_sources.append("--branches")
    if "--mirror" in flags:
        scan_sources.append("--all")

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
        if scan_sources:
            run_scan(root, remote, fetch_url, scan_sources)
        return "Push guard: this push needs Michael, because " + "; ".join(asks) + "."
    # A source git cannot resolve is the scan's to refuse, as on main: git would stop that
    # push before the hook, but the verdict stays a deny.
    if scan_sources and not (hook_will_run(repo, root, flags, assigns, wrapped)
                             and repo.run("rev-list", "--no-walk", *scan_sources) is not None):
        run_scan(root, remote, fetch_url, scan_sources)
    return None


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
            # deny from either is the plain-push deny.
            if could_push(cmd, tokens, cwd) or probe_refuses(tokens, cmd, cwd):
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
        if shape is not None or push_shape(cmd):
            print(decision("deny", "Push guard: internal error ({}: {}), so the push is "
                                   "refused. Push by hand.".format(type(e).__name__, e)))
        return
    if reason:
        print(decision("ask", reason))


if __name__ == "__main__":
    main()
