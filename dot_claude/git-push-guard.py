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
# outside the grammar). could_push always reads the raw command text. A single git command of the same shape that does not push is left alone. Any
# other command that could run git push (git and push in its text, or git and a push
# alias) is a silent deny asking for the push as a plain command. Nothing else is parsed:
# no control structures, subshells, heredocs, evaluators or chains.
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
# Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
import fnmatch
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

PUNCT =";&|()<>\n"
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

# Subcommands that push without being git push: always refused. Any other subcommand that
# is not a builtin and is given the word push (subtree, lfs, ...) is refused as well.
PUSHING_SUBCOMMANDS = {"send-pack", "http-push"}
# A refspec destination that git resolves as a ref path rather than a branch name.
DWIM_PREFIXES = ("heads/", "tags/", "remotes/", "refs/")

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
                    # past this size git prints "Binary files differ" for a text file
                    ("core.bigFileThreshold", "2g")]
# The scan reads a merge as the diff against what git would merge by itself (remerge), so a
# secret added while committing a merge is seen; git log -p shows a merge with no diff.
MERGE_DIFF = "--diff-merges=remerge"
# Options that make `git log -p` show every added line: a root commit, a file marked binary
# or -diff by .gitattributes or .git/info/attributes, a textconv or external diff driver.
PATCH_OPTS = ["--root", "--text", "--no-textconv", "--no-ext-diff", MERGE_DIFF]
# Files that change what gitleaks reports. Only a committed one is a reviewed exception.
GITLEAKS_CONFIG_FILES = [".gitleaksignore", ".gitleaks.toml"]
# What a committed .gitleaks.toml may set under [extend]. extend.path loads another config
# file (and extend.url would, once gitleaks implements it), which is not reviewed with the push.
EXTEND_KEYS = {("extend", "usedefault"), ("extend", "disabledrules")}
# A TOML key: bare, "basic" or 'literal'. A basic key holding an escape is not matched, so a
# config that spells a key with one is refused as unreadable rather than misread.
TOML_KEY = r"""(?:[a-z0-9_-]+|"[^"\\\n]*"|'[^'\n]*')"""
TOML_DOTTED = TOML_KEY + r"(?:[ \t]*\.[ \t]*" + TOML_KEY + r")*"
TOML_HEADER_RE = re.compile(r"\[\[?[ \t]*(" + TOML_DOTTED + r")[ \t]*\]\]?")
TOML_ASSIGN_RE = re.compile(r"(" + TOML_DOTTED + r")[ \t]*=")
SCANNED_RE = re.compile(r"\b(\d+) commits? scanned\b")
ERR_RE = re.compile(r"^\S+\s+ERR\b", re.M)
PLAIN = ("Push guard: this command may run git push in a shape the guard does not check. Run "
         "the push as a plain command of its own: git push [options] <remote> <branch> "
         "(for another repository: git -C <path> push [options] <remote> <branch>; piped only "
         "to tail or head). If the command does not push, keep git and push apart in its text, "
         "for example rg 'git pu[s]h'.")


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

    def run(self, *args, env=None, long=False):
        """stdout of a git query, or None when git fails. env replaces the environment; long
        lifts the per-call limit to what is left of the budget (a patch listing of a large
        push). Output is decoded leniently: a patch can carry any bytes."""
        remaining = BUDGET - (time.monotonic() - START)
        if remaining <= 0:
            raise Deny(TIMED_OUT)
        try:
            p = subprocess.run(self.base + list(args), capture_output=True, env=env,
                               encoding="utf-8", errors="replace",
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
# A word of glob syntax alone (*, ?, [...]) with no literal outside a bracket: the *) of a
# case arm, or a markdown bullet (* item) in a here-document. It spells no command name.
GLOB_ONLY = re.compile(r"(?:[*?]|\[[!^]?\]?[^\]]*\])+")


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


def odd_command_word(tokens):
    """A command word that could be git push under another spelling: git-push,
    git-send-pack or git-http-push by name (the dash form, also behind a path), or a glob
    that matches git or one of those names (gi?, g[i]t). A glob with no literal in it (*)
    and a case pattern (g*)) are not spellings of a command."""
    for k in command_words(tokens):
        base = os.path.basename(tokens[k])
        if base in DASH_PUSH:
            return True
        # Only the last path component decides: $HOME/bin/helm is helm, and $DOCKER is not
        # a git spelling. A glob there is refused when it can match git or a git-* name.
        if not any(c in base for c in "?[*") or GLOB_ONLY.fullmatch(base) \
                or case_pattern(tokens, k):
            continue
        if any(fnmatch.fnmatchcase(g, base) for g in GIT_NAMES):
            return True
    return False


def dynamic_git_word(tokens):
    """Is a git word followed by a global option or a subcommand the shell rewrites (git
    ${X:-push} ...)? Such a word can name any subcommand, so the text cannot rule out a
    push. Only a git in command position counts: rg git -g '*.sh' names git as an argument."""
    n = len(tokens)
    for k in command_words(tokens):
        if os.path.basename(tokens[k]) != "git":
            continue
        j = k + 1
        while j < n and not is_operator(tokens[j]):
            w = tokens[j]
            name = w.split("=", 1)[0]
            if w in ("-C", "-c") or (name in GIT_LONG_OPTS_WITH_VALUE and "=" not in w):
                if dynamic(w) or (j + 1 < n and dynamic(tokens[j + 1], dollar=(w != "-C"))):
                    return True
                j += 2
            elif w.startswith("-"):
                if dynamic(w):
                    return True
                j += 1
            else:
                if dynamic(w):
                    return True
                break
    return False


def could_push(cmd, tokens, cwd):
    """For a command outside the grammar: could it run git push? git and push in its text,
    git and a push alias (from cwd, or a repository a -C, --git-dir or GIT_DIR in it names),
    git under a GIT_CONFIG override, or git followed by a subcommand the shell computes.
    Text only; no shape is parsed."""
    if PUSH_SHAPE.search(cmd):
        return True
    if tokens and (dynamic_git_word(tokens) or odd_command_word(tokens)):
        return True
    if not re.search(r"\bgit\b", cmd):
        return False
    if "GIT_CONFIG" in cmd:
        return True
    selectors = [[]]
    for k, tok in enumerate(tokens or []):
        if tok in ("-C", "--git-dir") and k + 1 < len(tokens):
            selectors.append([tok, os.path.expanduser(tokens[k + 1])])
        elif tok.startswith("--git-dir="):
            selectors.append([tok])
        elif tok.startswith("GIT_DIR="):
            selectors.append(["--git-dir=" + tok.split("=", 1)[1]])
    names = set()
    for sel in selectors:
        names |= push_aliases(cwd, sel)
    return any(re.search(r"\bgit\b[^;&|\n]*\b" + re.escape(a) + r"\b", cmd) for a in names)


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


def judge(s):
    """None to allow, a reason to ask; raises Deny. s is a plain command from parse_plain."""
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
    return evaluate(s["cwd"], s["assigns"], s["repo_opts"], s["config_opts"], args)


def parse_push(args):
    """Split git push arguments into (flags, remote or None, refspecs). Raises Deny for an
    option outside the modelled set, and for the -- separator."""
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
            name, eq, _ = a.partition("=")
            if name not in PUSH_LONG or (eq and name not in PUSH_LONG_WITH_VALUE):
                raise Deny(UNSUPPORTED.format("the push option " + a))
            if name == "--push-option" and not eq:
                i += 1                   # its value is the next word
            flags.add(name)
        elif a.startswith("-") and len(a) > 1:
            for j, c in enumerate(a[1:], start=1):
                if c == "o":             # -o <option> or -o<option>: the rest is its value
                    if j == len(a) - 1:
                        i += 1
                    break
                if c not in PUSH_SHORT:
                    raise Deny(UNSUPPORTED.format("the push option -" + c))
                flags.add("-" + c)
        else:
            positional.append(a)
        i += 1
    remote = positional[0] if positional else None
    return flags, remote, positional[1:]


def default_branch(repo, remote):
    head = repo.run("symbolic-ref", "--quiet", "--short", "refs/remotes/" + remote + "/HEAD")
    if head and head.strip().startswith(remote + "/"):
        return head.strip()[len(remote) + 1:]
    for ref in ("refs/remotes/" + remote + "/", "refs/heads/"):
        for name in ("main", "master"):
            if repo.has_ref(ref + name):
                return name
    return "main"


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
    something. Run through Repo.run, under the same budget as every git call."""
    out = repo.run("log", "-p", "-U0", "--no-color", "--format=%x01%H", *PATCH_OPTS,
                   *(list(sources) + ["--not", "--remotes=" + remote]), env=env, long=True)
    if out is None:
        raise Deny("Push guard: git could not list the outgoing commits ({}), so the secret "
                   "scan cannot show it covered them and the push is refused. Push by hand."
                   .format(" ".join(sources)))
    # A hunk line never starts with "deleted file mode": every line of a hunk starts with
    # +, -, a space or a backslash.
    count, scanned, deleted = 0, False, False
    for line in out.split("\n"):
        if line.startswith("\x01"):
            count += 1 if scanned else 0
            scanned, deleted = False, False
        elif line.startswith("diff "):
            deleted = False                            # a file header: a new file
        elif line.startswith("deleted file mode "):
            deleted = True
        elif line.startswith("@@") and not deleted:
            scanned = True
    return count + (1 if scanned else 0)


def toml_statements(text):
    """The statements of a TOML document, lowercased (viper reads keys without case): each
    table header and each key = value, comments dropped. A value that runs over several
    lines (an array, a multi-line string) stays inside its statement, so no line of it is
    read as a header or a key. Raises ValueError on a string left open."""
    stmts, cur, depth, i, n = [], [], 0, 0, len(text)
    while i < n:
        c = text[i]
        if c == "#":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c in "\"'":
            q = c * 3 if text.startswith(c * 3, i) else c
            j = i + len(q)
            while not text.startswith(q, j):
                if j >= n or (len(q) == 1 and text[j] == "\n"):
                    raise ValueError("a string is not closed")
                j += 2 if c == '"' and text[j] == "\\" else 1
            j += len(q)
            extra = 0                  # up to two more quotes are content: '''a'''' holds a'
            while len(q) == 3 and extra < 2 and j < n and text[j] == c:
                j, extra = j + 1, extra + 1
            cur.append(text[i:j])
            i = j
            continue
        if c == "\n" and depth <= 0:
            stmts.append("".join(cur).strip().lower())
            cur, depth = [], 0
        else:
            depth += (c in "[{") - (c in "]}")
            cur.append(c)
        i += 1
    stmts.append("".join(cur).strip().lower())
    return [s for s in stmts if s]


def toml_path(dotted):
    """The key path viper makes of a TOML key. viper splits every key on dots, so
    extend.path, "extend.path" and extend . path all name path under extend."""
    parts = []
    for tok in re.findall(TOML_KEY, dotted):
        if tok[0] in "\"'":
            tok = tok[1:-1]
        parts.extend(p.strip() for p in tok.split("."))
    return tuple(parts)


def config_extension(path):
    """What this gitleaks config sets under extend beyond useDefault and disabledRules
    (extend.path, which loads another config file), or None. Raises ValueError (or OSError)
    where it cannot tell: a statement that is not a plain header or key, an escaped key, a
    string left open, a file that is not UTF-8."""
    with open(path, "rb") as fh:
        text = fh.read().decode("utf-8-sig")
    table = ()
    for s in toml_statements(text):
        m = TOML_HEADER_RE.fullmatch(s)
        if m:
            table = toml_path(m.group(1))
            if table[:1] == ("extend",) and len(table) > 1:
                return "[" + ".".join(table) + "]"
            continue
        m = TOML_ASSIGN_RE.match(s)
        if not m:
            raise ValueError("the statement starting {!r} is not one it reads".format(
                s.split("\n")[0][:40]))
        keys = table + toml_path(m.group(1))
        if keys == ("extend",):
            return "extend = { ... }"
        if keys[:1] == ("extend",) and keys not in EXTEND_KEYS:
            return ".".join(keys)
    return None


def scan(root, remote, sources):
    """gitleaks over the commits this push would send. Returns on a clean scan and
    raises Deny otherwise; a scan that cannot run, or cannot prove it covered the commits,
    is a deny, never a pass.
    --ignore-gitleaks-allow: the only exception is a reviewed .gitleaksignore entry, never
    an inline comment. gitleaks reads .gitleaksignore and .gitleaks.toml from the working
    tree, so a copy that is not byte-identical to the one committed on HEAD and on every
    pushed ref (untracked, ignored, modified, hidden by skip-worktree or
    status.showUntrackedFiles, or committed on another branch) is refused: commit it first,
    and the exception is reviewed like any other change. A push by pattern (--tags, --all,
    --mirror) names no refs to compare, so with an exception file present it is refused and
    the refs must be pushed by name. The committed .gitleaks.toml is passed by name, since
    gitleaks' own search prefers any .gitleaks.json beside it; one that extends another
    config (extend.path) is refused, because the file it loads is not reviewed with the
    push. Every git call here runs with
    replace refs off (GIT_NO_REPLACE_OBJECTS), since a push sends the real objects. GITLEAKS_*
    variables are dropped from the environment for the same reason. Commit and
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
    # The worktree copy is what gitleaks reads, so it must be the committed one on HEAD and on
    # every ref pushed: an exception committed on another branch reviews nothing here.
    present = [n for n in GITLEAKS_CONFIG_FILES if os.path.lexists(os.path.join(root, n))]
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
                           ".gitleaksignore, or a .gitleaks.toml), then push.".format(name, ref))
    # gitleaks checks only that .gitleaks.toml exists, then lets viper search the source for
    # .gitleaks.*, which finds an untracked .gitleaks.json first. Naming the committed file
    # turns the search off. Without one, gitleaks reads its default config and no other file.
    config = []
    if ".gitleaks.toml" in present:
        path = os.path.join(root, ".gitleaks.toml")
        try:
            extension = config_extension(path)
        except (OSError, ValueError) as e:
            raise Deny("Push guard: the guard cannot read .gitleaks.toml ({}), so it cannot rule "
                       "out an [extend] path that loads a gitleaks config not reviewed with this "
                       "push, and the push is refused. Write it with plain keys (no escapes), or "
                       "push by hand.".format(e))
        if extension:
            raise Deny("Push guard: .gitleaks.toml sets {}, so the scan may follow a gitleaks "
                       "config that is not reviewed with this push. Extended gitleaks configs "
                       "are not supported by the push guard; inline the rules in .gitleaks.toml "
                       "([extend] may keep useDefault and disabledRules), commit it, and push "
                       "again.".format(extension))
        config = ["--config", path]
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
             "--report-format", "json", "--report-path", report]
            + config + ["--log-opts=" + log_opts, root], root, env)
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
def evaluate(cwd, assigns, repo_opts, config_opts, args):
    """None to allow, a reason string to ask; raises Deny to deny."""
    flags, remote_arg, refspecs = parse_push(args)
    if "-n" in flags or "--dry-run" in flags:
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
    branch = repo.run("symbolic-ref", "--quiet", "--short", "HEAD")
    branch = branch.strip() if branch else None
    if branch and repo.config("branch." + branch + ".pushRemote") is not None:
        raise Deny(UNSUPPORTED.format("branch." + branch + ".pushRemote"))
    if remote_arg and dynamic(remote_arg):
        raise Deny("Push guard: the remote " + remote_arg + " is a shell value the guard cannot "
                   "know. Name the remote literally.")
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
        if any(c in s for c in "$`{}?["):
            # A variable, a substitution, a brace list or a glob: bash rewrites the word
            # before git sees it, so the literal text is not where the push goes.
            raise Deny("Push guard: the refspec " + spec + " is a shell value the guard cannot "
                       "know, so it cannot tell where the push goes. Name the branch literally "
                       "(git push origin <branch>, or HEAD for the current one).")
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

    if asks:
        return "Push guard: this push needs Michael, because " + "; ".join(asks) + "."
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
        if tokens is not None:
            shape = parse_plain(tokens, cwd)
        if shape is None:
            if could_push(cmd, tokens, cwd):           # the raw text: a superset, never trimmed
                raise Deny(PLAIN)
            return
        reason = judge(shape)
    except Deny as d:
        print(decision("deny", str(d)))
        return
    except Exception as e:                             # a bug here must not open the gate
        # A plain git command may be an alias push (git pom): it fails closed as well.
        if shape is not None or PUSH_SHAPE.search(cmd):
            print(decision("deny", "Push guard: internal error ({}: {}), so the push is "
                                   "refused. Push by hand.".format(type(e).__name__, e)))
        return
    if reason:
        print(decision("ask", reason))


if __name__ == "__main__":
    main()
