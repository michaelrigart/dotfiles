#!/usr/bin/python3
# The pre-merge gate: its command grammar and its checks. xreview-guard.sh beside this file
# runs it for a payload that mentions create, new, merge, accept, pulls or graphql and one of
# glab, gh or git. Design: docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md,
# section 3.6.
#
# Reads the PreToolUse payload on stdin. Prints ONE hookSpecificOutput deny object, or
# nothing. It never asks, and it never allows on doubt: a gated shape it cannot complete is
# denied with a reason the agent can act on. A command holding no gated verb is allowed.
#
# A gated verb counts only in command position, and it must be a plain command:
#
#   [cd <literal path> &&] [sudo] git [-C <path>]... merge [options] <ref>   (onto the default branch)
#   [cd <literal path> &&] [sudo] glab mr create|new|merge|accept [options]
#   [cd <literal path> &&] [sudo] gh pr create|new|merge [options]
#   [cd <literal path> &&] [sudo] glab|gh api [options] <endpoint>   (an MR/PR write, or graphql)
#
# Any other command holding a gated verb in command position (a chain, a pipe, a newline, a
# subshell, an assignment, env, sudo with an option, or another wrapper) is denied, asking for
# the plain form. So is any command whose substitutions run one: a $( ) or backtick body,
# unquoted or inside double quotes, or inside a here-document whose delimiter is unquoted.
# A comment, a redirection, single-quoted text and the rest of a here-document body are read
# past, wherever they stand. --help or -h right after the verb, and a merge's lone --abort,
# --quit or --continue, are never gated.
#
# Threat model: the commands an agent plausibly writes. A verb assembled from variables, eval,
# a script file or an alias passes; the auto-mode classifier covers those.
#
# Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
import importlib.util
import json
import os
import re
import shlex
import signal
import subprocess
import sys
from urllib.parse import parse_qsl, quote, unquote, urlsplit

# Claude Code treats a hook that outruns its timeout (60 s in the settings) as non-blocking,
# so the gate gives up first, and a give-up is a deny. XREVIEW_GUARD_BUDGET exists only so
# the test suite can shorten it.
try:
    BUDGET = max(1, int(os.environ.get("XREVIEW_GUARD_BUDGET", "40")))
except ValueError:
    BUDGET = 40
CALL_TIMEOUT = 8.0
HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER_PATH = os.environ.get("XREVIEW_LEDGER") or os.path.join(HERE, "xreview-ledger.py")

TAIL = ("\n\nDo not bypass this on your own judgement. Only if Michael has asked, in this "
        "conversation, for this to go ahead without a review: re-run with XREVIEW_GUARD=off in "
        "the command (an assignment on the command line is read, a trailing "
        "# XREVIEW_GUARD=off works too), and say so in the MR.")
PLAIN = ("Pre-merge gate: this command proposes or merges a change in a shape the gate does not "
         "check. Run the verb as a plain command of its own - [cd <path> &&] git [-C <path>] "
         "merge <ref>, glab mr ..., gh pr ..., or glab|gh api ... - with no chain, pipe, "
         "newline, subshell, environment assignment or env wrapper. If the command only "
         "mentions the verb, keep it out of command position (quote it).")
UNPARSEABLE = ("Pre-merge gate: this command cannot be parsed (unbalanced quotes), and it may "
               "propose or merge a change. Fix the quoting, and run the verb as a plain command.")
TIMED_OUT = "Pre-merge gate: the check did not finish in time, so the command is refused. Retry it."
LITERAL = "Pre-merge gate: {} must be a literal value the gate can read, not {}."
NO_REPO = "Pre-merge gate: {} is not inside a git repository, so the change cannot be checked."
ONE_REF = "Pre-merge gate: merge one named ref at a time: git merge <ref>."
NOT_MODELLED = "Pre-merge gate: the gate does not check this forge command yet, so it is refused."


class Deny(Exception):
    """A gated command that must be refused, carrying the reason the agent reads."""


def decision(reason):
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason + TAIL,
    }}, separators=(",", ":"))


# ------------------------------------------------------------------ tokens
PUNCT = ";&|()<>\n"
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# A here-document operator, << or <<- (not the here-string <<<); its delimiter word follows.
HEREDOC_START = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*")
METACHARS = " \t\n;&|()<>"
WRAPPERS = {"command", "env", "sudo", "time", "nohup", "xargs", "exec", "nice", "builtin"}
RESERVED = {"if", "then", "elif", "else", "do", "while", "until", "!", "{"}
MAX_NESTING = 8


def heredoc_word(line, i):
    """(delimiter, quoted) of the here-document word starting at line[i], read as the shell
    reads it: up to a metacharacter, a '...' or "..." part taken whole whatever it holds, and a
    backslash escaping the next character. Any quoting or escaping makes it quoted: the body
    then does not expand. None when there is no word or a quote never closes."""
    out, quoted, n = [], False, len(line)
    while i < n and line[i] not in METACHARS:
        c = line[i]
        if c == "\\" and i + 1 < n:
            out.append(line[i + 1])
            quoted, i = True, i + 2
        elif c in "'\"":
            j = line.find(c, i + 1)
            if j < 0:
                return None
            out.append(line[i + 1:j])
            quoted, i = True, j + 1
        else:
            out.append(c)
            i += 1
    return ("".join(out), quoted) if out else None


def split_heredocs(cmd):
    """(cmd without the bodies of its here-documents, the bodies that expand). A body is data,
    never a command; but when its delimiter is unquoted the shell still runs the $( ) and
    backtick substitutions in it, so those bodies are kept for scanning. A body ends at the
    line that is exactly its unquoted delimiter (after leading tabs, for <<-). A marker whose
    terminator line never comes is left alone, so no text is dropped on a guess."""
    lines, out, expanding, i = cmd.split("\n"), [], [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC_START.finditer(line):
            word = heredoc_word(line, m.end())
            if word is None:
                continue
            delimiter, quoted = word
            j = i
            while j < len(lines) and (lines[j].lstrip("\t") if m.group(1) else lines[j]) != delimiter:
                j += 1
            if j < len(lines):
                if not quoted:
                    expanding.append("\n".join(lines[i:j]))
                i = j + 1
    return "\n".join(out), expanding


def closing_paren(text, i):
    """The index of the ) that closes a $( opened just before i: nested parentheses and quotes
    inside it are tracked. len(text) when it never closes."""
    depth, quoting, n = 1, None, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and quoting != "'" and i + 1 < n:
            i += 2
            continue
        if quoting:
            if c == quoting:
                quoting = None
        elif c in "'\"":
            quoting = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def substitutions(text, shell=True):
    """The bodies of the command substitutions, $( ) and backticks, that run when text does.
    In shell text (shell=True) single quotes keep them inert, double quotes do not. In an
    expanding here-document body (shell=False) quotes are plain characters; only a
    backslash keeps a $ or a backtick literal."""
    out, i, n, quoting = [], 0, len(text), None
    while i < n:
        c = text[i]
        if c == "\\" and quoting != "'" and i + 1 < n:
            i += 2
            continue
        if shell and quoting is None and c in "'\"":
            quoting = c
        elif shell and c == quoting:
            quoting = None
        elif quoting != "'" and text.startswith("$(", i):
            j = closing_paren(text, i + 2)
            out.append(text[i + 2:j])
            i = j + 1
            continue
        elif quoting != "'" and c == "`":
            j = i + 1
            while j < n and text[j] != "`":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i + 1:j])
            i = j + 1
            continue
        i += 1
    return out


def substituted_commands(cmd):
    """The command texts cmd runs through substitution: every $( ) and backtick body outside
    single quotes and comments, and each one in a here-document body whose delimiter is
    unquoted. Nested ones are found when each body is read in turn."""
    main, expanding = split_heredocs(cmd)
    bodies = substitutions(strip_comments(main.replace("\\\n", " ")))
    for body in expanding:
        bodies.extend(substitutions(body, shell=False))
    return bodies


def gated_in_substitution(cmd, depth=0):
    """Does a command substitution in cmd, at any depth, run a gated verb?"""
    for body in substituted_commands(cmd):
        if depth >= MAX_NESTING:
            return True
        try:
            tokens = tokenize(body)
        except ValueError:
            if CRUDE.search(body):
                return True
            continue
        if any(gated_verb(segment(tokens, k)) for k in command_words(tokens)):
            return True
        if gated_in_substitution(body, depth + 1):
            return True
    return False


def strip_comments(cmd):
    """cmd without its comments: an unquoted # that starts a word, to the end of its line.
    Quotes and backslashes are tracked as the shell does, so a quoted '#12 fix' stays."""
    out, i, n, quoting = [], 0, len(cmd), None
    while i < n:
        c = cmd[i]
        if quoting is None and c == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|()"):
            j = cmd.find("\n", i)
            if j < 0:
                break
            i = j
            continue
        out.append(c)
        if c == "\\" and quoting != "'" and i + 1 < n:
            out.append(cmd[i + 1])
            i += 2
            continue
        if quoting is None and c in "'\"":
            quoting = c
        elif c == quoting:
            quoting = None
        i += 1
    return "".join(out)


# A redirection operator: >, >>, >|, <, <>, <&, >&, &>, &>>, a here-string or a here-document
# marker, anywhere in an unquoted word; at the start of a word it may carry a descriptor
# number (2>, 2>&1). Not a process substitution, <( ) or >( ), which runs a command.
REDIRECT_OP = r"(?:&>>|&>|>>|>&|>\||<>|<&|<<<|<<-|<<|>|<)(?!\()"
REDIRECT_RE = re.compile(r"\d*" + REDIRECT_OP)
REDIRECT_MID_RE = re.compile(REDIRECT_OP)
WORD_END = " \t\n;&|()<>"


def skip_word(cmd, i):
    """The index just past the shell word that starts at i, quotes and backslashes included."""
    n, quoting = len(cmd), None
    while i < n:
        c = cmd[i]
        if quoting is None and c in WORD_END:
            break
        if c == "\\" and quoting != "'" and i + 1 < n:
            i += 2
            continue
        if quoting is None and c in "'\"":
            quoting = c
        elif c == quoting:
            quoting = None
        i += 1
    return i


def strip_redirections(cmd):
    """cmd without its redirections: an unquoted operator (>f, > f, 2>f, &>f, <f, N>&M, <>f,
    >|f, <<<, a here-document marker) and its operand, split off the word it touches
    (git>log merge is git, then merge). A redirection changes where input and output go,
    never what runs, so the gate reads past it wherever it stands, before the command word
    and between arguments alike. Quoted text is left alone."""
    out, i, n, quoting = [], 0, len(cmd), None
    while i < n:
        c = cmd[i]
        if quoting is None:
            starts_word = i == 0 or cmd[i - 1] in " \t\n;&|()"
            m = (REDIRECT_RE if starts_word else REDIRECT_MID_RE).match(cmd, i)
            if m:
                j = m.end()
                while j < n and cmd[j] in " \t":
                    j += 1
                out.append(" ")
                i = skip_word(cmd, j)
                continue
        out.append(c)
        if c == "\\" and quoting != "'" and i + 1 < n:
            out.append(cmd[i + 1])
            i += 2
            continue
        if quoting is None and c in "'\"":
            quoting = c
        elif c == quoting:
            quoting = None
        i += 1
    return "".join(out)


def tokenize(cmd):
    """Shell words and operator tokens, with here-document bodies, comments and redirections
    dropped. Raises ValueError on unbalanced quotes."""
    text = strip_redirections(strip_comments(split_heredocs(cmd)[0].replace("\\\n", " ")))
    lx = shlex.shlex(text, posix=True, punctuation_chars=PUNCT)
    lx.whitespace = " \t\r"          # a newline separates commands; it is not a blank
    lx.whitespace_split = True
    lx.commenters = ""
    return list(lx)


def is_operator(tok):
    return bool(tok) and all(c in PUNCT for c in tok)


def starts_command(tok):
    """An operator after which a new command begins: a separator, a pipe, a subshell or a
    process substitution."""
    return is_operator(tok) and ("(" in tok or ("<" not in tok and ">" not in tok))


def command_words(tokens):
    """Indexes of the words that may run as a command: the first word of each simple command,
    after VAR=value assignments and reserved words, and - after a wrapper (command, env, sudo,
    time, xargs, ...) - every later word of that command. A wrapper's options can take an
    argument (sudo -u root git merge ...), so which word it runs cannot be read from the text."""
    out, i, n, at = [], 0, len(tokens), True
    while i < n:
        t = tokens[i]
        if starts_command(t):
            at = True
        elif not is_operator(t) and at:
            if ASSIGN_RE.match(t) or t in RESERVED:
                pass
            elif os.path.basename(t) in WRAPPERS:
                j = i + 1
                while j < n and not is_operator(tokens[j]):
                    out.append(j)
                    j += 1
                at = False
                i = j
                continue
            else:
                out.append(i)
                at = False
        i += 1
    return out


def segment(tokens, k):
    """The words of the simple command whose command word is at k."""
    end = k
    while end < len(tokens) and not is_operator(tokens[end]):
        end += 1
    return tokens[k:end]


def literal(word):
    """Is this word what the program receives: no variable and no command substitution?"""
    return word is not None and "$" not in word and "`" not in word


# ------------------------------------------------------------------ the gated verbs
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
                  "--super-prefix"}
FORGE_VALUE_OPTS = {"-R", "--repo"}
HELP = {"--help", "-h"}
MERGE_CONTROL = {"--abort", "--quit", "--continue"}
CLI_VERBS = {
    ("glab", "mr", "create"): "create", ("glab", "mr", "new"): "create",
    ("glab", "mr", "merge"): "merge", ("glab", "mr", "accept"): "merge",
    ("gh", "pr", "create"): "create", ("gh", "pr", "new"): "create",
    ("gh", "pr", "merge"): "merge",
}
MUTATIONS = re.compile(r"\b(mergeRequestCreate|mergeRequestAccept|mergeRequestSetAutoMerge|"
                       r"createPullRequest|mergePullRequest|enablePullRequestAutoMerge)\b")
NAMES_MR_PATH = re.compile(r"(^|/)(merge_requests|pulls)(/|$)")
API_VALUE = {"-X", "--method", "-f", "--raw-field", "-F", "--field", "--form", "-H", "--header",
             "--input", "--hostname", "-q", "--jq", "-t", "--template", "--cache", "-p",
             "--preview", "--output"}
API_FIELD = {"-f": False, "--raw-field": False, "-F": True, "--field": True, "--form": True}


def skip_options(words, i, value_opts):
    while i < len(words) and words[i].startswith("-") and words[i] != "-":
        i += 2 if words[i] in value_opts else 1
    return i


def parse_api(args):
    """The parts of a glab/gh api call the gate reads: endpoint, method (the CLIs' default:
    POST once a field or a body is given, GET otherwise), fields (name -> last value), body
    (True when the body or a typed field comes from a file or stdin) and hostname."""
    call = {"endpoint": None, "method": None, "fields": {}, "body": False, "hostname": None}
    i, n = 0, len(args)
    while i < n:
        a, name, value = args[i], None, None
        if a.startswith("--") and len(a) > 2:
            name, eq, value = a.partition("=")
            if name in API_VALUE and not eq:
                i += 1
                value = args[i] if i < n else ""
        elif a.startswith("-") and len(a) > 1:
            name = a[:2]
            if name in API_VALUE:
                if len(a) > 2:
                    value = a[2:]
                else:
                    i += 1
                    value = args[i] if i < n else ""
        elif call["endpoint"] is None:
            call["endpoint"] = a
        if name in ("-X", "--method"):
            call["method"] = (value or "").upper()
        elif name in API_FIELD:
            key, _, val = (value or "").partition("=")
            if API_FIELD[name] and val.startswith("@"):
                call["body"] = True
            call["fields"][key] = val
        elif name == "--input":
            call["body"] = True
        elif name == "--hostname":
            call["hostname"] = value
        i += 1
    if call["method"] is None:
        call["method"] = "POST" if call["fields"] or call["body"] else "GET"
    return call


def endpoint_parts(endpoint):
    """(path, query fields) of an api endpoint, a scheme and host and an api/v3 or api/v4
    prefix dropped."""
    if "://" in endpoint:
        parts = urlsplit(endpoint)
        path, query = parts.path, parts.query
    else:
        path, _, query = endpoint.partition("?")
    path = re.sub(r"^api/v[34]/", "", path.strip("/"))
    return path, dict(parse_qsl(query, keep_blank_values=True))


def is_graphql(endpoint):
    """graphql, or an absolute URL whose path ends in /graphql."""
    return endpoint_parts(endpoint)[0].split("/")[-1] == "graphql"


def api_gated(call):
    """A GraphQL call carrying an MR/PR create, merge or auto-merge mutation, or a query the
    gate cannot read; or a POST, PUT or PATCH to a path naming merge_requests or pulls."""
    endpoint = call["endpoint"] or ""
    if is_graphql(endpoint):
        return call["body"] or bool(MUTATIONS.search(" ".join(call["fields"].values())))
    path, _ = endpoint_parts(endpoint)
    return call["method"] in ("POST", "PUT", "PATCH") and bool(NAMES_MR_PATH.search(path))


def gated_verb(words):
    """The gated verb that words (a command word and its arguments) spell, as {tool, kind,
    args}, or None. kind is merge-local (git merge), create, merge or api; args are the words
    after the verb, with an option written before the noun (glab -R x mr ...) kept in front.
    Help is exempt only as the first word after the verb, and a merge's --abort, --quit or
    --continue only as its sole argument: anywhere else either may be an option's value."""
    if not words:
        return None
    tool, rest = os.path.basename(words[0]), words[1:]
    if tool not in ("git", "glab", "gh"):
        return None
    if tool == "git":
        i = skip_options(rest, 0, GIT_VALUE_OPTS)
        if i < len(rest) and rest[i] == "merge":
            after = rest[i + 1:]
            if after[:1] and after[0] in HELP or len(after) == 1 and after[0] in MERGE_CONTROL:
                return None
            return {"tool": "git", "kind": "merge-local", "args": rest}
        return None
    i = skip_options(rest, 0, FORGE_VALUE_OPTS)
    if i + 1 < len(rest) and (tool, rest[i], rest[i + 1]) in CLI_VERBS:
        if rest[i + 2:i + 3] and rest[i + 2] in HELP:
            return None
        return {"tool": tool, "kind": CLI_VERBS[(tool, rest[i], rest[i + 1])],
                "args": rest[:i] + rest[i + 2:]}
    if i < len(rest) and rest[i] == "api":
        if rest[i + 1:i + 2] and rest[i + 1] in HELP:
            return None
        if api_gated(parse_api(rest[i + 1:])):
            return {"tool": tool, "kind": "api", "args": rest[i + 1:]}
    return None


# ------------------------------------------------------------------ the plain command
def parse_plain(tokens, cwd):
    """The gated verb of a plain command - [cd <literal path> &&] [sudo] <verb> - with the
    directory it runs in; None when the command is anything else."""
    t = list(tokens)
    while t and t[-1] == "\n":
        t.pop()
    while t and t[0] == "\n":
        t.pop(0)
    i = 0
    if len(t) >= 3 and t[0] == "cd" and t[2] == "&&" and not is_operator(t[1]):
        target = os.path.expanduser(t[1])
        if not literal(target) or target == "-":
            return None
        cwd, i = os.path.normpath(os.path.join(cwd, target)), 3
    if i < len(t) and t[i] == "sudo":
        i += 1
    words = t[i:]
    if not words or any(is_operator(w) for w in words):
        return None
    verb = gated_verb(words)
    if verb is not None:
        verb["cwd"] = cwd
    return verb


def parse_flags(args, takes_value):
    """(flags, positionals) of a CLI's arguments. flags maps each option as written (--name or
    -x) to the list of its values: its value when it is in takes_value, else the =value or
    None. A short bundle (-yd) is split, a value-taking short option ending it (-ys feature,
    -sfeature) included. -- ends the options."""
    flags, pos, i, n = {}, [], 0, len(args)
    while i < n:
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a.startswith("--"):
            name, eq, value = a.partition("=")
            if name in takes_value and not eq:
                i += 1
                value = args[i] if i < n else None
            elif not eq:
                value = None
            flags.setdefault(name, []).append(value)
        elif a.startswith("-") and len(a) > 1:
            j = 1
            while j < len(a):
                name = "-" + a[j]
                if name in takes_value:
                    rest = a[j + 1:]
                    rest = rest[1:] if rest.startswith("=") else rest
                    if not rest:
                        i += 1
                        rest = args[i] if i < n else None
                    flags.setdefault(name, []).append(rest)
                    break
                flags.setdefault(name, []).append(None)
                j += 1
        else:
            pos.append(a)
        i += 1
    return flags, pos


# ------------------------------------------------------------------ the repository
def run(argv, cwd=None):
    """stdout of a command, or None when it fails or cannot start."""
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=CALL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return p.stdout.decode("utf-8", "replace")


def toplevel(cwd):
    out = run(["git", "-C", cwd, "rev-parse", "--show-toplevel"])
    if not out or not out.strip():
        raise Deny(NO_REPO.format(cwd))
    return out.strip()


# ------------------------------------------------------------------ the decision
def listing(items):
    return "; ".join(items) if items else "nothing"


def check(ledger, top, source, dest, dest_rev, tip, dispatch_range, merge_hint):
    """Allow (return) when the ledger approves tip landing on dest; deny otherwise, naming the
    change, what is on record, and the dispatch that opens the gate."""
    d = ledger.decide(top, dest, dest_rev, tip, branch=source)
    if d["allow"]:
        return
    text = ("Pre-merge gate: {reason}.\n\n"
            "The change: {repo}, {source} -> {dest}, tip {tip}, fingerprint {fp}.\n"
            "On record for this change: {change}.\n"
            "On record for branch {source}: {branch}.\n\n"
            "A change lands only when the latest full-range pre-merge review of exactly this "
            "change approves it: a newer pending review, a newer verdict of changes, a partial "
            "range, or a spec or plan review never opens the gate. Run the cross-review skill, "
            "or:\n\n"
            "    xreview dispatch --checkpoint pre-merge --diff {rng} <body-file>\n"
            "    xreview collect <nonce>").format(
                reason=d["reason"], repo=d["repo"] or "(no repository)", source=source,
                dest=dest, tip=d["tip"] or tip, fp=d["fingerprint"] or "(none)",
                change=listing(d["on_record"]), branch=listing(d["on_record_branch"]),
                rng=dispatch_range)
    if merge_hint:
        text += "\n\nThen merge it pinned and immediate: " + merge_hint
    raise Deny(text)


# ------------------------------------------------------------------ git merge
GIT_FLAGS = {"-p", "-P", "--paginate", "--no-pager", "--no-replace-objects",
             "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
             "--icase-pathspecs", "--no-optional-locks", "--no-advice", "--no-lazy-fetch"}
MERGE_VALUE = {"-m", "-F", "-s", "-X", "--message", "--file", "--strategy",
               "--strategy-option", "--into-name"}


def judge_git_merge(shape, ledger):
    """git [-C <path>]... merge <ref>: gated only while the repository's current branch is its
    default branch; the change is <ref>, landing on that branch's HEAD."""
    args, cwd, i = shape["args"], shape["cwd"], 0
    while i < len(args) and args[i] != "merge":
        if args[i] == "-C" and i + 1 < len(args):
            if not literal(args[i + 1]):
                raise Deny(LITERAL.format("the -C path", args[i + 1]))
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(args[i + 1])))
            i += 2
        elif args[i] in GIT_FLAGS:
            i += 1
        else:
            raise Deny(PLAIN)
    top = toplevel(cwd)
    dest = ledger.default_branch(top)
    if ledger.current_branch(top) != dest:
        return
    _, refs = parse_flags(args[i + 1:], MERGE_VALUE)
    if len(refs) != 1:
        raise Deny(ONE_REF)
    ref = refs[0]
    if not literal(ref) or ref.startswith("-"):
        raise Deny(LITERAL.format("the merged ref", ref))
    source = ref[len("origin/"):] if ref.startswith("origin/") else ref
    check(ledger, top, source, dest, "HEAD", ref, "{}...{}".format(dest, ref), None)


def judge(shape, ledger):
    if shape["kind"] == "merge-local":
        return judge_git_merge(shape, ledger)
    raise Deny(NOT_MODELLED)


# ------------------------------------------------------------------ main
CRUDE = re.compile(r"\b(glab|gh)\b[^\n]*\b(mr|pr|api)\b|\bgit\b[^\n]*\bmerge\b")


def on_alarm(signum, frame):
    raise Deny(TIMED_OUT)


def load_ledger():
    spec = importlib.util.spec_from_file_location("xreview_ledger", LEDGER_PATH)
    if spec is None or spec.loader is None:
        raise Deny("Pre-merge gate: the ledger helper {} cannot be loaded, so the command is "
                   "refused. Restore it (chezmoi apply).".format(LEDGER_PATH))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.CALL_TIMEOUT = CALL_TIMEOUT
    return module


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = payload.get("tool_input", {}).get("command") or ""
        cwd = payload.get("cwd") or os.getcwd()
    except (ValueError, AttributeError):
        return
    # The bypass is read from the command, the only place a model can write it.
    if not isinstance(cmd, str) or not cmd or "XREVIEW_GUARD=off" in cmd:
        return
    signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(BUDGET)
    gated = False
    try:
        try:
            tokens = tokenize(cmd)
        except ValueError:
            if CRUDE.search(cmd):
                raise Deny(UNPARSEABLE)
            return
        # A gated verb run by a substitution is never part of a plain command.
        hidden = gated_in_substitution(cmd)
        gated = hidden or any(gated_verb(segment(tokens, k)) for k in command_words(tokens))
        if not gated:
            return
        shape = None if hidden else parse_plain(tokens, cwd)
        if shape is None:
            raise Deny(PLAIN)
        judge(shape, load_ledger())
    except Deny as d:
        print(decision(str(d)))
    except Exception as e:                             # a bug here must not open the gate
        if gated or CRUDE.search(cmd):
            print(decision("Pre-merge gate: internal error ({}: {}), so the command is "
                           "refused.".format(type(e).__name__, e)))
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    main()
