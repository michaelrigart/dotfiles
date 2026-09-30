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
# Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
import json
import os
import re
import shlex
import subprocess
import sys

PUNCT = ";&|()<>\n"
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Could this text run git push? git, then push (or a push alias), within one command.
PUSH_SHAPE = re.compile(r"\bgit\b[^;&|\n]*\bpush\b")
TAILS = {"tail", "head"}
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

UNSUPPORTED = ("unsupported push configuration for the push guard: {}; "
               "push by hand or simplify the configuration")
PLAIN = ("Push guard: this command may run git push in a shape the guard does not check. Run "
         "the push as a plain command of its own: git push [options] <remote> <branch> "
         "(optionally after one cd <path> &&, and piped only to tail or head). If the command "
         "does not push, keep git and push apart in its text, for example rg 'git pu[s]h'.")


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
            opt, i = [w, t[i + 1]], i + 2
        elif name in GIT_LONG_OPTS_WITH_VALUE:
            opt, i = [w], i + 1
        else:
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

    def run(self, *args):
        """stdout of a git query, or None when git fails."""
        try:
            p = subprocess.run(self.base + list(args), capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
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
        if re.search(r"\bpush\b", value):
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
        if value.startswith("push") or (value.startswith("!") and re.search(r"\bpush\b", value)):
            names.add(name[len("alias."):])
    return names


def could_push(cmd, tokens, cwd):
    """For a command outside the grammar: could it run git push? git and push in its text,
    git and a push alias (from cwd, or a repository a -C, --git-dir or GIT_DIR in it names),
    or git under a GIT_CONFIG override. Text only; no shape is parsed."""
    if PUSH_SHAPE.search(cmd):
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


def judge(s):
    """None to allow, a reason to ask; raises Deny. s is a plain command from parse_plain."""
    sub, args = s["sub"], s["args"]
    if sub != "push" and sub not in GIT_BUILTINS:
        if s["unknown"] or [a for a in s["assigns"] if GIT_ENV_UNSUPPORTED.match(a)]:
            raise Deny(PLAIN)                          # an alias under an override
        # -c options go into the lookup too: `git -c alias.x=push x` defines the alias on
        # the command line itself.
        sub, args = expand_alias(Repo(s["cwd"], s["repo_opts"] + s["config_opts"]), sub, args)
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
    if remote_arg and ("$" in remote_arg or "`" in remote_arg):
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
        if "$" in s or "`" in s:
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
