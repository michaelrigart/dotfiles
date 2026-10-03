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
# A gated verb must be a plain command:
#
#   [cd <literal path> &&] [sudo] git [-C <path>]... merge [options] <ref>   (onto the default branch)
#   [cd <literal path> &&] [sudo] glab mr create|new|merge|accept [options]
#   [cd <literal path> &&] [sudo] gh pr create|new|merge [options]
#   [cd <literal path> &&] [sudo] glab|gh api [options] <endpoint>   (an MR/PR write, or graphql)
#
# Any word may be a command word: one after a wrapper (timeout 30, caffeinate -i, xcrun,
# find -exec, xargs, sudo -u root), a zsh precommand modifier (noglob, repeat 1), a keyword
# (coproc, function f {) or an assignment (A+=1). So every unquoted word naming git, glab or
# gh is read as one, and a gated verb anywhere but in the plain form above is denied, asking
# for the plain form; an unquoted mention (echo git merge x) is denied with it, and quoting
# the mention keeps it out. So is any command whose substitutions run one - a $( ) or
# backtick body, unquoted or inside double quotes, or inside a here-document whose delimiter
# is unquoted - and any command that hands one to another shell: sh, bash, zsh, dash or ksh
# -c '...', or env -S '...'. A comment, a redirection, single-quoted text ($'...' included)
# and the rest of a here-document body are read past, wherever they stand, and a line
# continuation is joined first, as the shell joins it. --help or -h right after the verb, and
# a merge's lone --abort, --quit or --continue, are never gated.
#
# The grammar is bash's and zsh's: the Bash tool runs its commands under zsh here, and scripts
# run under bash. Threat model: the commands an agent plausibly writes. Out of scope, as spec
# section 7 says: an alias (git -c alias.m=merge m included), eval, a script file or a script
# fed to a shell on stdin, a verb assembled from variables, and any other deliberately
# obfuscated spelling; the auto-mode classifier covers those.
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
         "newline, subshell, environment assignment, wrapper or nested shell. If the command "
         "only mentions the verb, quote the mention.")
UNPARSEABLE = ("Pre-merge gate: this command cannot be parsed (unbalanced quotes), and it may "
               "propose or merge a change. Fix the quoting, and run the verb as a plain command.")
MALFORMED = ("Pre-merge gate: the hook's payload is not valid JSON, and its text may propose or "
             "merge a change, so the command is refused. Retry it.")
NO_BRANCH = ("Pre-merge gate: the current branch of {} cannot be read, so whether this merge "
             "lands on the default branch is unknown and it is refused. Retry it.")
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
# A here-document operator, << or <<- (not the here-string <<<); its delimiter word follows.
HEREDOC_START = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*")
METACHARS = " \t\n;&|()<>"
TOOLS = {"git", "glab", "gh"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
MAX_NESTING = 8
# The words after which a command starts, as after an operator.
COMMAND_KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "{", "!", "time"}
# The escapes of an ANSI-C $'...' string, as bash and zsh decode them.
ANSI_C = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r",
          "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}
ANSI_NUMBER = re.compile(r"[0-7]{1,3}|x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|U[0-9A-Fa-f]{1,8}")


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


def ansi_c(cmd, i):
    """(value, end) of the $'...' string whose text starts at cmd[i]: its escapes decoded, and
    the index past its closing quote. end is None when the string never closes."""
    out, n = [], len(cmd)
    while i < n:
        c = cmd[i]
        if c == "'":
            return "".join(out), i + 1
        if c == "\\" and i + 1 < n:
            e, m = cmd[i + 1], ANSI_NUMBER.match(cmd, i + 1)
            if e in ANSI_C:
                out.append(ANSI_C[e])
                i += 2
            elif e == "c" and i + 2 < n:
                out.append(chr(ord(cmd[i + 2]) & 0x1f))
                i += 3
            elif m:
                code = m.group(0)
                value = int(code, 8) if code[0] in "01234567" else int(code[1:], 16)
                out.append(chr(min(value, 0x10FFFF)))
                i = m.end()
            else:
                out.append(cmd[i:i + 2])
                i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out), None


def word_at(cmd, i):
    j = i
    while j < len(cmd) and cmd[j] not in METACHARS:
        j += 1
    return cmd[i:j]


def tail(out, n=40):
    """The last n characters lex has emitted."""
    text, k = "", len(out)
    while k and len(text) < n:
        k -= 1
        text = out[k] + text
    return text[-n:]


def command_position(out):
    """Does the next word start a command: after an operator, a newline or a ( - or a keyword
    that a command follows (then, do, else, ...)?"""
    t = tail(out).rstrip(" \t")
    return not t or t[-1] in ";&|(\n" or t.split()[-1] in COMMAND_KEYWORDS


def arithmetic(cmd, j):
    """Is the (( that ends just before cmd[j] arithmetic - do its parentheses close as )) - or
    a subshell's ( after a ( or a $(, as in $((cmd) | tr)? The shells decide it so too."""
    depth, n, quoting = 2, len(cmd), None
    while j < n:
        c = cmd[j]
        if c == "\\" and quoting != "'":
            j += 2
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
            if depth == 1:
                return j + 1 < n and cmd[j + 1] == ")"
        j += 1
    return False


def here_bodies(cmd, i, pending, expanding):
    """Read the bodies of the pending here-documents, in order, from cmd[i] - the line after
    their operators; returns the index past the last one read. A body ends at the line that is
    exactly its unquoted delimiter (after leading tabs, for <<-); under an unquoted delimiter a
    line continuation joins two lines first, as the shell joins them. An expanding body (its
    delimiter unquoted) is kept in expanding. A body whose delimiter line never comes is left
    in place, so no text is dropped on a guess."""
    n = len(cmd)
    for delimiter, quoted, strip in pending:
        j = i
        while True:
            start, line = j, ""
            while True:
                e = cmd.find("\n", j)
                piece = cmd[j:n if e < 0 else e]
                if not quoted and e >= 0 and (len(piece) - len(piece.rstrip("\\"))) % 2:
                    line, j = line + piece[:-1], e + 1
                    continue
                line += piece
                break
            if (line.lstrip("\t") if strip else line) == delimiter:
                if not quoted:
                    expanding.append(cmd[i:start])
                i = n if e < 0 else e + 1
                break
            if e < 0:
                return i
            j = e + 1
    return i


def lex(cmd, body=False):
    """Read cmd as the shell reads it before it runs anything. Returns (text, substitutions,
    expanding). text is cmd with each line continuation (an unescaped backslash-newline),
    comment and here-document body removed, each $'...' string rewritten in single quotes,
    and the body of each substitution taken out ($( ) and `` stay, empty), so the text holds
    no quoting nested inside one. substitutions are the bodies of the outermost $( ) and
    backtick substitutions, each to be read in turn - a backtick body with its \\`, \\\\ and
    \\$ undone. expanding are the bodies of the here-documents whose delimiter is unquoted.
    Quoting nests as the shell's does: a $( ) inside double quotes is shell text again, so the
    here-document of "$(cat <<'EOF' ... EOF)" is found, while a << or a # inside quotes or
    arithmetic is text, and so is a # that a closing ) or ` joins to its word. body=True reads
    an expanding here-document body: no quote is special in it, and a backslash escapes only
    $, a backtick, a backslash or a newline."""
    out, subs, expanding, pending = [], [], [], []
    # Each frame: [kind, where its body starts in out, open parentheses, open case statements].
    stack = [["body" if body else "sh", 0, 0, 0]]
    glued = -1                      # len(out) right after a substitution closed: no word break

    def close():
        frame = stack.pop()
        if not any(f[0] in ("$(", "`") for f in stack):
            text = "".join(out[frame[1]:])
            if frame[0] == "`":
                text = re.sub(r"\\([`\\$])", r"\1", text)
            subs.append(text)
            del out[frame[1]:]

    i, n = 0, len(cmd)
    while i < n:
        frame = stack[-1]
        kind, c = frame[0], cmd[i]
        if kind == "'":
            out.append(c)
            if c == "'":
                stack.pop()
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            nxt = cmd[i + 1]
            if nxt == "\n":
                i += 2
            elif (kind == '"' and nxt not in '$`"\\') or (kind == "body" and nxt not in "$`\\"):
                out.append(c)
                i += 1
            else:
                out.append(cmd[i:i + 2])
                i += 2
            continue
        if kind == "`":
            if c == "`":
                close()
                glued = len(out) + 1
            out.append(c)
            i += 1
            continue
        if cmd.startswith("$((", i) and arithmetic(cmd, i + 3):
            out.append("$((")
            stack.append(["((", len(out), 2, 0])
            i += 3
            continue
        if kind == "((":
            if c == "(":
                frame[2] += 1
            elif c == ")":
                frame[2] -= 1
                if frame[2] == 0:
                    stack.pop()
                    glued = len(out) + 1
            elif cmd.startswith("$(", i) or c in "'\"`":
                kind = "sh"                     # open the substitution or quote below
            if kind == "((":
                out.append(c)
                i += 1
                continue
        if kind in ('"', "body"):
            if c == '"' and kind == '"':
                stack.pop()
                out.append(c)
                i += 1
            elif cmd.startswith("$(", i):
                out.append("$(")
                stack.append(["$(", len(out), 1, 0])
                i += 2
            else:
                if c == "`":
                    stack.append(["`", len(out) + 1, 0, 0])
                out.append(c)
                i += 1
            continue
        # Shell text: the command line itself, or the inside of a $( ).
        prev = out[-1][-1] if out else "\n"
        at_word = prev in METACHARS and len(out) != glued
        if c == "#" and at_word:
            j = cmd.find("\n", i)
            i = n if j < 0 else j
            continue
        if cmd.startswith("$'", i):
            value, end = ansi_c(cmd, i + 2)
            if end is None:
                out.append(cmd[i:])
                i = n
            else:
                out.append("'" + value.replace("'", "'\"'\"'") + "'")
                i = end
            continue
        if c in "'\"`":
            stack.append([c, len(out) + 1, 0, 0])
            out.append(c)
            i += 1
            continue
        if cmd.startswith("$(", i):
            out.append("$(")
            stack.append(["$(", len(out), 1, 0])
            i += 2
            continue
        if cmd.startswith("((", i) and at_word and arithmetic(cmd, i + 2):
            out.append("((")
            stack.append(["((", len(out), 2, 0])
            i += 2
            continue
        if kind == "$(":
            if c == "(":
                frame[2] += 1
            elif c == ")" and not (frame[3] and frame[2] == 1):   # not a case pattern's )
                frame[2] -= 1
                if frame[2] == 0:
                    close()
                    out.append(c)
                    glued = len(out)
                    i += 1
                    continue
            elif c in "ce" and at_word and command_position(out) and word_at(cmd, i) in ("case", "esac"):
                frame[3] = max(0, frame[3] + (1 if word_at(cmd, i) == "case" else -1))
        m = HEREDOC_START.match(cmd, i) if c == "<" else None
        if m:
            word = heredoc_word(cmd, m.end())
            if word is not None:
                pending.append((word[0], word[1], m.group(1) == "-"))
            out.append(cmd[i:m.end()])
            i = m.end()
            continue
        out.append(c)
        i += 1
        if c == "\n" and pending:
            i = here_bodies(cmd, i, pending, expanding)
            pending = []
    for frame in stack:
        if frame[0] in ("$(", "`"):
            subs.append("".join(out[frame[1]:]))
            del out[frame[1]:]
            break
    return "".join(out), subs, expanding


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
    and between arguments alike. Quoted text is left alone. cmd has been through lex, so the
    only quotes left are '...' and "..."."""
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


def tokenize(text):
    """The words and operator tokens of lexed text, its redirections dropped. Raises
    ValueError on unbalanced quotes."""
    lx = shlex.shlex(strip_redirections(text), posix=True, punctuation_chars=PUNCT)
    lx.whitespace = " \t\r"          # a newline separates commands; it is not a blank
    lx.whitespace_split = True
    lx.commenters = ""
    return list(lx)


def is_operator(tok):
    return bool(tok) and all(c in PUNCT for c in tok)


def command_name(word):
    """The program a word names: its basename, and for zsh's =name (name's path) the name."""
    return os.path.basename(word[1:] if word.startswith("=") else word)


def candidates(tokens):
    """Each word naming git, glab or gh, with the words after it in its simple command. Any
    word may be a command word - after a wrapper (timeout 30, caffeinate -i, find -exec,
    xargs), a zsh precommand modifier (noglob, repeat 1), a keyword (coproc, function f {) or
    an assignment (A+=1) - so the gate never tries to tell which word runs. Whether the command
    is plain is parse_plain's question."""
    out, end = [], len(tokens)
    for k in range(len(tokens) - 1, -1, -1):
        if is_operator(tokens[k]):
            end = k
        elif command_name(tokens[k]) in TOOLS:
            out.append(tokens[k:end])
    return out[::-1]


def shell_strings(tokens):
    """The command strings a word hands to another shell: every word after an option cluster
    holding c given to sh, bash, zsh, dash or ksh (its -c string, and the words after it), and
    the string of env -S or --split-string."""
    out, n = [], len(tokens)
    for k, word in enumerate(tokens):
        name, j, rest = command_name(word), k + 1, False
        while (name in SHELLS or name == "env") and j < n and not is_operator(tokens[j]):
            w, after = tokens[j], tokens[j + 1] if j + 1 < n else ""
            if rest:
                out.append(w)
            elif name == "env" and w.startswith("--split-string"):
                out.append(w.partition("=")[2] if "=" in w else after)
            elif name == "env" and w.startswith("-") and not w.startswith("--") and "S" in w:
                out.append(w[w.index("S") + 1:] or after)
            elif name in SHELLS and w[:1] in ("-", "+") and w[1:2] != "-" and "c" in w[1:]:
                rest = True
            j += 1
    return out


def scan(cmd, depth=0):
    """(tokens, hidden): cmd's words and operators, and whether a command that cmd runs some
    other way holds a gated verb, at any depth - a $( ) or backtick substitution (outside
    single quotes, or in an expanding here-document), a shell's -c string, env -S's string.
    Nesting deeper than MAX_NESTING counts as hidden. Raises ValueError when cmd has unbalanced
    quotes."""
    text, nested, expanding = lex(cmd)
    for body in expanding:
        nested.extend(lex(body, body=True)[1])
    tokens = tokenize(text)
    nested.extend(shell_strings(tokens))
    for inner in nested:
        if depth >= MAX_NESTING:
            return tokens, True
        try:
            inner_tokens, inner_hidden = scan(inner, depth + 1)
        except ValueError:
            if crude(inner):
                return tokens, True
            continue
        if inner_hidden or gated_anywhere(inner_tokens):
            return tokens, True
    return tokens, False


def literal(word):
    """Is this word what the program receives: no variable and no command substitution?"""
    return word is not None and "$" not in word and "`" not in word


# ------------------------------------------------------------------ the gated verbs
# git's global options that take their value as the next word (git 2.56: --list-cmds and
# --exec-path take one only after =; --super-prefix is from older releases).
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
                  "--attr-source", "--super-prefix"}
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
    tool, rest = command_name(words[0]), words[1:]
    if tool not in TOOLS:
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


def gated_anywhere(tokens):
    return any(gated_verb(words) for words in candidates(tokens))


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
    branch = ledger.current_branch(top)
    if branch is None:
        # No branch: a detached HEAD, which is no branch at all, or a lookup that failed or
        # timed out, which says nothing and must not open the gate.
        if (ledger.git(top, "rev-parse", "--abbrev-ref", "HEAD") or "") != "HEAD":
            raise Deny(NO_BRANCH.format(top))
        return
    if branch != dest:
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


def crude(text):
    """The last resort, for text the grammar cannot read: glab or gh with mr, pr or api, or git
    with merge, with quotes and backslashes dropped (g''it is git). The text is read three
    ways: with every backslash-newline joined (mer\\<newline>ge is merge), as written (an
    escaped backslash does not continue its line), and as lex reads it ($'\\x67it' is git)."""
    def flat(t):
        return re.sub(r"[\\'\"]", "", t)
    try:
        lexed = lex(text)[0]
    except Exception:                                  # crude is the fallback; it never fails
        lexed = ""
    return any(CRUDE.search(flat(t)) for t in (text.replace("\\\n", ""), text, lexed))


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
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
        cmd = payload.get("tool_input", {}).get("command") or ""
        cwd = payload.get("cwd") or os.getcwd()
    except (ValueError, AttributeError):
        # A payload that is not JSON is read as text, its JSON escapes undone roughly.
        text = raw.replace("\\\\", "\0").replace("\\n", "\n").replace("\\t", "\t")
        if "XREVIEW_GUARD=off" not in raw and crude(text.replace("\0", "\\")):
            print(decision(MALFORMED))
        return
    # The bypass is read from the command, the only place a model can write it.
    if not isinstance(cmd, str) or not cmd or "XREVIEW_GUARD=off" in cmd:
        return
    signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(BUDGET)
    gated = False
    try:
        try:
            tokens, hidden = scan(cmd)
        except ValueError:
            if crude(cmd):
                raise Deny(UNPARSEABLE)
            return
        # A gated verb run some other way - a substitution, a nested shell - is never part of
        # a plain command.
        gated = hidden or gated_anywhere(tokens)
        if not gated:
            return
        shape = None if hidden else parse_plain(tokens, cwd)
        if shape is None:
            raise Deny(PLAIN)
        judge(shape, load_ledger())
    except Deny as d:
        print(decision(str(d)))
    except Exception as e:                             # a bug here must not open the gate
        if gated or crude(cmd):
            print(decision("Pre-merge gate: internal error ({}: {}), so the command is "
                           "refused.".format(type(e).__name__, e)))
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    main()
