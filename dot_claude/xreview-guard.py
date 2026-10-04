#!/usr/bin/python3
# The pre-merge gate: its command grammar and its checks. xreview-guard.sh beside this file
# runs it for a payload that mentions create, new, merge, accept, pulls, graphql or revert (or
# mr with for) and one of glab, gh or git. Design:
# docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md, section 3.6.
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
# glab mr for (new-for, create-for) and gh pr revert are gated too, and always denied: each
# proposes a branch the forge makes itself, which no review can have seen.
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
REORDERED = ("Pre-merge gate: {0} takes a subcommand's options before its name and between its "
             "words, so this could run {0} {1}, which the gate checks only in its own order. Write "
             "it as {2}, with every other option after it.")
NO_BRANCH = ("Pre-merge gate: the current branch of {} cannot be read, so whether this merge "
             "lands on the default branch is unknown and it is refused. Retry it.")
TIMED_OUT = "Pre-merge gate: the check did not finish in time, so the command is refused. Retry it."
LITERAL = "Pre-merge gate: {} must be a literal value the gate can read, not {}."
NO_REPO = "Pre-merge gate: {} is not inside a git repository, so the change cannot be checked."
ONE_REF = "Pre-merge gate: merge one named ref at a time: git merge <ref>."
FETCH_HEADS = ("Pre-merge gate: git merge FETCH_HEAD merges every head the last fetch marked for "
               "merge, all in one merge, and the gate reads only one, so it allows FETCH_HEAD only "
               "while it holds exactly one ({}). Merge the one you mean by name: git merge "
               "origin/<branch>.")
ONCE = "Pre-merge gate: name {} once."
NO_ORIGIN = ("Pre-merge gate: {} has no origin remote, so the forge project cannot be checked. "
             "Run the command from the project's own checkout.")
OTHER_PROJECT = ("Pre-merge gate: the command acts on the project {} (named by -R, or by GH_REPO or "
                 "GITLAB_REPO in the environment), but this checkout's origin is {}. Run it from "
                 "that project's checkout.")
OTHER_HOST = ("Pre-merge gate: this call goes to {0}, but this checkout's origin is on {1}. Send "
              "it to origin's host, --hostname {1}, from that project's checkout.")
SEVERAL_HOSTS = ("Pre-merge gate: without --hostname, glab api picks its host from this "
                 "checkout's remotes, and some are on another host than origin's ({0}). Name "
                 "origin's host: --hostname {1}.")
DEFAULT_HOST = ("Pre-merge gate: {0} names no host, so the CLI sends this to its default host, "
                "{1}, but this checkout's origin is on {2}. Name origin's host: {3}.")
API_HOST_VAR = ("Pre-merge gate: GITLAB_API_HOST sends glab's API requests to {0}, not to "
                "origin's host {1}, so the gate cannot check what this command does. Run it "
                "without GITLAB_API_HOST.")
UNREADABLE = ("Pre-merge gate: {0} cannot be read, so the host this call goes to is unknown. "
              "Name origin's host: {1}.")
SEVERAL_REMOTES = ("Pre-merge gate: this checkout has remotes besides origin ({}), so the CLI "
                   "could pick another project. Name origin's project explicitly: -R {}.")
FORK = ("Pre-merge gate: {} proposes from another repository. Merge requests from forks are not "
        "checked by the gate; propose from the checkout's origin.")
DETACHED = "Pre-merge gate: HEAD is detached in {}, so the source branch is unknown. Name it with {}."
NEED_DEST = ("Pre-merge gate: name the destination explicitly with {}. The CLI could otherwise "
             "take an implicit base from per-branch configuration, which the gate does not read.")
NOT_ON_ORIGIN = ("Pre-merge gate: the branch {} is not on origin, so the change the forge would "
                 "propose cannot be read. Publish the branch to origin first, then retry.")
LS_REMOTE = ("Pre-merge gate: cannot read origin's head of {} (git ls-remote failed), so the "
             "command is refused.")
DEFERRED = ("Pre-merge gate: {} is a deferred merge (auto-merge, or merge when the pipeline "
            "succeeds), which the gate never allows: the MR/PR could be retargeted while it "
            "waits. Wait for the pipeline, then merge immediately and pinned: {}.")
LOOKUP = ("Pre-merge gate: the forge lookup of {} failed, so its destination is unknown and the "
          "merge is refused. Check that it exists and that the CLI is signed in, then retry.")
CREATE_FLAG = ("Pre-merge gate: {0} is not among the flags the gate allows for {1}: it could "
               "change what the MR/PR proposes, or where, in a way the gate does not read. Run "
               "the command without it.")
PUSHES = ("Pre-merge gate: {0} makes glab push this checkout's HEAD ({1}) to {2}, but origin's "
          "{2} is {3}, so the MR would propose a head that was never reviewed. Push the branch "
          "to origin first (git push), then retry; or create the MR without {0}.")
NEED_HEAD = ("Pre-merge gate: name the source branch explicitly with --head <branch>. gh could "
             "otherwise take it from push configuration (pushRemote, @{push}), which the gate "
             "does not read.")
RESOLVED = ("Pre-merge gate: {0} is {1}, so a {2} command that names no project acts on {1}, not "
            "on origin's {3}. Name origin's project with -R {4}, or remove that setting.")
RESOLVED_UNREADABLE = ("Pre-merge gate: the git configuration of {} cannot be read (git config "
                       "failed or timed out), so the project a command naming none acts on is "
                       "unknown. Retry it, or name origin's project with -R.")
API_REPO = ("Pre-merge gate: -R/--repo ({1}) on {0} api picks the project the call acts on, which "
            "the gate does not check. Run it without -R, from the project's own checkout.")
API_DEFAULT_HOST = ("Pre-merge gate: without --hostname, glab api falls back to its default host "
                    "{0} when it has no login for origin's host {1}, so the call may go there. "
                    "Name origin's host: --hostname {1}.")
BRANCH_LOOKUP = ("Pre-merge gate: the current branch of {} cannot be read (the lookup failed or "
                 "timed out), so the source branch is unknown. Retry it, or name it with {}.")
UNRESOLVED_API = ("Pre-merge gate: this {} api call writes to an MR/PR path whose source, head or "
                  "destination the gate cannot read. Use the CLI (glab mr ..., gh pr ...) or the "
                  "REST create and merge endpoints with literal fields.")
UNPINNED = ("Pre-merge gate: a forge merge must pin the head it merges. Its head is now {}. Once "
            "a pre-merge review of that head approves it, merge with: {}.")
FULL_SHA = "Pre-merge gate: pin the head with a full commit id, not {}."
NOT_ONE = "Pre-merge gate: {} open merge requests come from {}; name the one to merge by number."
ONE_TARGET = "Pre-merge gate: name one {} to merge."
GRAPHQL = ("Pre-merge gate: this GraphQL call creates, updates, reverts, merges or enqueues an "
           "MR/PR, merges a branch, enables auto-merge, or carries a query the gate cannot read. "
           "Use the forms the gate checks: glab mr create|merge, gh pr create|merge, or the REST "
           "merge_requests/pulls endpoints; edit an MR/PR with glab mr update or gh pr edit.")
OTHER_URL = ("Pre-merge gate: the {} {} is not on this checkout's origin ({}/{}). Run the merge "
             "from that project's checkout, or name the MR/PR by number.")
QUEUED = ("Pre-merge gate: this merge would go through {}: it would be enqueued, or set to merge "
          "once checks pass - a deferred merge, which the gate never allows, since nothing can pin "
          "what finally lands. A merge through a queue or a train is Michael's to run.")
MERGE_FLAG = ("Pre-merge gate: {0} is not among the flags the gate allows for {1}: it could "
              "merge past the forge's own checks, or defer or change the merge, in a way the "
              "gate does not read. Run the command without it.")
BRANCH_MERGE = ("Pre-merge gate: this {} api call writes to a merges endpoint, which merges one "
                "branch into another with no MR/PR, so no review can bind it. Propose the branch "
                "as an MR/PR, and merge that pinned once its pre-merge review approves it.")
QUERY_STRING = ("Pre-merge gate: this gh api write carries a query string ({}). gh sends -f/-F "
                "fields in the request body, and GitHub may not read a write's query string, so "
                "the gate reads only the body. Pass each field with -f instead.")
FORGE_MADE = ("Pre-merge gate: {0} creates an MR/PR from a branch the forge makes itself, which "
              "no review can have seen, so the gate never allows it. Make the branch, push it, "
              "and once its pre-merge review approves it, propose it with {1}.")


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


def funsub(cmd, i):
    """Does cmd[i] start bash 5.3's ${ cmd; } or ${| cmd; }: ${ followed by a blank, a newline
    or |? A parameter expansion (${x}, ${x:-y}, ${#x}) never is."""
    return cmd.startswith("${", i) and cmd[i + 2:i + 3] in (" ", "\t", "\n", "|")


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


def command_position(out, in_case=False):
    """Does the next word start a command: after an operator, a newline or a (, after the ) that
    ends a pattern of an open case statement (in_case), or after a keyword that a command
    follows (then, do, else, {, !, time, time -p, ...) - however it touches a ( before it,
    as in $({ or $(time - or right after bash 5.3's ${ ?"""
    t = tail(out).rstrip(" \t")
    if not t or t[-1] in ";&|(\n" or t.endswith("${") or (in_case and t[-1] == ")"):
        return True
    words = [w for w in re.split(r"[ \t\n()]+", t) if w]
    if len(words) > 1 and words[-2:] == ["time", "-p"]:
        words.pop()
    return bool(words) and words[-1] in COMMAND_KEYWORDS


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


def lex(cmd, body=False, everywhere=False):
    """Read cmd as the shell reads it before it runs anything. Returns (text, substitutions,
    expanding). text is cmd with each line continuation (an unescaped backslash-newline),
    comment and here-document body removed, each $'...' string rewritten in single quotes,
    and the body of each substitution taken out ($( ), <( ), >( ) and `` stay, empty), so the
    text holds no quoting nested inside one. substitutions are the bodies of the outermost
    command and process substitutions, each to be read in turn - a backtick body with its \\`,
    \\\\ and \\$ undone. expanding are the bodies of the here-documents whose delimiter is
    unquoted.
    Quoting nests as the shell's does: a $( ) inside double quotes is shell text again, so the
    here-document of "$(cat <<'EOF' ... EOF)" is found, while a << or a # inside quotes or
    arithmetic is text, and so is a # that a closing ) or ` joins to its word. body=True reads
    an expanding here-document body: no quote is special in it, and a backslash escapes only
    $, a backtick, a backslash or a newline. A case statement's pattern ) does not end a
    substitution: case counts where a command starts, or, with everywhere=True, wherever the
    word stands, and esac counts only where a command starts. Counting case too often, or
    missing an esac, can only end a substitution late, never early, so the second reading's
    bodies hold everything the substitutions run (scan reads both). Inside a ${...} parameter
    expansion a ( or ) is text and case is a word ($(echo ${x//)/}) runs one command); an
    unmatched ${ keeps the substitution open."""
    out, subs, expanding, pending = [], [], [], []
    # Each frame: [kind, where its body starts in out, open parentheses, open case statements,
    # and for a $( frame open ${ parameter expansions].
    stack = [["body" if body else "sh", 0, 0, 0]]
    glued = -1                      # len(out) right after a substitution closed: no word break

    def close():
        frame = stack.pop()
        if not any(f[0] in ("$(", "${", "`") for f in stack):
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
                stack.append(["$(", len(out), 1, 0, 0])
                i += 2
            elif funsub(cmd, i):
                out.append("${")
                stack.append(["${", len(out), 1, 0, 0])
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
        if funsub(cmd, i):
            # bash 5.3's ${ cmd; } and ${| cmd; } run cmd in the current shell; } ends them
            # where it starts a command, as it ends a { group.
            out.append("${")
            stack.append(["${", len(out), 1, 0, 0])
            i += 2
            continue
        if kind == "${" and at_word and command_position(out) and (
                c == "}" or (c == "{" and cmd[i + 1:i + 2] in (" ", "\t", "\n"))):
            frame[2] += 1 if c == "{" else -1
            if frame[2] == 0:
                close()
                out.append(c)
                glued = len(out)
                i += 1
                continue
        if cmd.startswith("$(", i) or (c in "<>" and cmd.startswith("(", i + 1)):
            # A command substitution, or a process substitution <( ) or >( ): both run their
            # body, and both glue their closing ) to the word that follows.
            out.append(cmd[i:i + 2])
            stack.append(["$(", len(out), 1, 0, 0])
            i += 2
            continue
        if cmd.startswith("((", i) and at_word and arithmetic(cmd, i + 2):
            out.append("((")
            stack.append(["((", len(out), 2, 0])
            i += 2
            continue
        if kind == "$(":
            if cmd.startswith("${", i):
                frame[4] += 1
            elif c == "}" and frame[4]:
                frame[4] -= 1
            elif frame[4]:
                pass                            # inside ${...}: a ( or ) is text, case a word
            elif c == "(":
                frame[2] += 1
            elif c == ")" and not (frame[3] and frame[2] == 1):   # not a case pattern's )
                frame[2] -= 1
                if frame[2] == 0:
                    close()
                    out.append(c)
                    glued = len(out)
                    i += 1
                    continue
            elif c in "ce" and at_word and word_at(cmd, i) in ("case", "esac"):
                # Over-counting case, or missing an esac, only ends a substitution late.
                start = command_position(out, frame[3] > 0)
                if word_at(cmd, i) == "case" and (everywhere or start):
                    frame[3] += 1
                elif word_at(cmd, i) == "esac" and start:
                    frame[3] = max(0, frame[3] - 1)
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
        if frame[0] in ("$(", "${", "`"):
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
    The substitutions are read twice: as the command-start reading of case finds them, and as
    the reading that counts case everywhere finds them, so no command start the first one
    misses can end a substitution early and hide the rest of it. The tokens come from the
    first. Nesting deeper than MAX_NESTING counts as hidden. Raises ValueError when cmd has
    unbalanced quotes."""
    text, nested, expanding = lex(cmd)
    nested.extend(b for b in lex(cmd, everywhere=True)[1] if b not in nested)
    for body in expanding:
        for flag in (False, True):
            nested.extend(b for b in lex(body, body=True, everywhere=flag)[1] if b not in nested)
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
    ("glab", "mr", "for"): "forge-made", ("glab", "mr", "new-for"): "forge-made",
    ("glab", "mr", "create-for"): "forge-made",
    ("gh", "pr", "create"): "create", ("gh", "pr", "new"): "create",
    ("gh", "pr", "merge"): "merge", ("gh", "pr", "revert"): "forge-made",
}
# The GraphQL mutations that create, update, revert, merge or enqueue an MR/PR, merge a branch
# with no PR, or turn auto-merge on. An update can retarget, from arguments a variable may
# carry, so it is denied by name. Every other mutation (review threads, comments) is allowed.
MUTATIONS = re.compile(r"\b(mergeRequestCreate|mergeRequestUpdate|mergeRequestAccept|"
                       r"mergeRequestSetAutoMerge|createPullRequest|updatePullRequest|"
                       r"revertPullRequest|mergePullRequest|enqueuePullRequest|"
                       r"enablePullRequestAutoMerge|mergeBranch)\b")
NAMES_MR_PATH = re.compile(r"(^|/)(merge_requests|pulls|merges)(/|$)")
API_VALUE = {"-X", "--method", "-f", "--raw-field", "-F", "--field", "--form", "-H", "--header",
             "--input", "--hostname", "-q", "--jq", "-t", "--template", "--cache", "-p",
             "--preview", "--output", "-R", "--repo"}
API_FIELD = {"-f": False, "--raw-field": False, "-F": True, "--field": True, "--form": True}


def skip_options(words, i, value_opts):
    while i < len(words) and words[i].startswith("-") and words[i] != "-":
        i += 2 if words[i] in value_opts else 1
    return i


def parse_api(args):
    """The parts of a glab/gh api call the gate reads: endpoint, method (the CLIs' default:
    POST once a field or a body is given, GET otherwise), fields (name -> last value), body
    (True when the body or a typed field comes from a file or stdin), hostname and repo (an
    -R/--repo, wherever it stands: glab takes it before api, after it and after the endpoint)."""
    call = {"endpoint": None, "method": None, "fields": {}, "body": False, "hostname": None,
            "repo": None}
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
        elif name in ("-R", "--repo"):
            call["repo"] = value
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
    """graphql, or an absolute URL whose path ends in /graphql, percent-escapes decoded."""
    return unquote(endpoint_parts(endpoint)[0]).split("/")[-1] == "graphql"


def api_gated(call):
    """A GraphQL call carrying one of MUTATIONS, or a query the gate cannot read; or a POST,
    PUT or PATCH to a path naming merge_requests, pulls or merges (a branch merged with no
    PR). The path is read with its percent-escapes decoded, as a forge's router may read it:
    m%65rge_requests names merge_requests."""
    endpoint = call["endpoint"] or ""
    if is_graphql(endpoint):
        return call["body"] or bool(MUTATIONS.search(" ".join(call["fields"].values())))
    path, _ = endpoint_parts(endpoint)
    return call["method"] in ("POST", "PUT", "PATCH") and bool(NAMES_MR_PATH.search(unquote(path)))


def only_options(words):
    """Could cobra read words as options alone: each word an option, or the value of the
    option before it?"""
    after_option = False
    for w in words:
        if w.startswith("-") and w != "-":
            after_option = True
        elif after_option:
            after_option = False
        else:
            return False
    return True


def only_repo(words):
    """Are words nothing but -R/--repo options with their values?"""
    i = 0
    while i < len(words):
        w = words[i]
        if w in FORGE_VALUE_OPTS:
            i += 2
        elif w.startswith("--repo=") or (w.startswith("-R") and len(w) > 2):
            i += 1
        else:
            return False
    return True


def reordered(tool, rest):
    """The gated verb cobra could find in rest written out of the gate's order, as (noun, verb),
    or None. cobra takes a subcommand's options before its name and between noun and verb, and
    which options take a value cannot be read from the text, so every word after options alone
    may be the noun, and every word after the noun and options alone may be the verb."""
    noun = "mr" if tool == "glab" else "pr"
    for k, word in enumerate(rest):
        if word.startswith("-") or not only_options(rest[:k]):
            continue
        if word == "api" and api_gated(parse_api(rest[:k] + rest[k + 1:])):
            return "api", ""
        if word != noun:
            continue
        for j in range(k + 1, len(rest)):
            if (not rest[j].startswith("-") and only_options(rest[k + 1:j])
                    and (tool, noun, rest[j]) in CLI_VERBS):
                return noun, rest[j]
    return None


def gated_verb(words):
    """The gated verb that words (a command word and its arguments) spell, as {tool, kind,
    args}, or None. kind is merge-local (git merge), create, forge-made, merge or api; args
    are the words after the verb, with an option written before the noun (glab -R x mr ...,
    glab -R x api ...) kept in front.
    Help is exempt only as the first word after the verb, and a merge's --abort, --quit or
    --continue only as its sole argument: anywhere else either may be an option's value. The
    gate checks glab and gh only in its own order - [-R <project>] noun verb, or api right
    after the tool; a gated verb cobra could find in another order is kind reordered."""
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
    canonical = only_repo(rest[:i])
    if canonical and i + 1 < len(rest) and (tool, rest[i], rest[i + 1]) in CLI_VERBS:
        if rest[i + 2:i + 3] and rest[i + 2] in HELP:
            return None
        return {"tool": tool, "kind": CLI_VERBS[(tool, rest[i], rest[i + 1])],
                "args": rest[:i] + rest[i + 2:]}
    if i == 0 and rest[:1] == ["api"]:
        if rest[1:2] and rest[1] in HELP:
            return None
        if api_gated(parse_api(rest[1:])):
            return {"tool": tool, "kind": "api", "args": rest[1:]}
        return None
    found = reordered(tool, rest)
    if found is not None:
        return {"tool": tool, "kind": "reordered", "args": rest, "verb": found}
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
    if verb is not None and verb["kind"] == "reordered":
        noun, name = verb["verb"]
        tool = verb["tool"]
        form = ("{} api [options] <endpoint>".format(tool) if noun == "api"
                else "{} [-R <project>] {} {} [options]".format(tool, noun, name))
        raise Deny(REORDERED.format(tool, (noun + " " + name).strip(), form))
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
                if a[j + 1:j + 2] == "=":               # -f=false: pflag's value form
                    flags.setdefault(name, []).append(a[j + 2:])
                    break
                flags.setdefault(name, []).append(None)
                j += 1
        else:
            pos.append(a)
        i += 1
    return flags, pos


def one(flags, names, label):
    """The single literal value of an option spelt any of names; None when it is absent."""
    values = [v for name in names for v in flags.get(name, [])]
    if len(values) > 1:
        raise Deny(ONCE.format(label))
    if not values:
        return None
    if values[0] is None or not values[0] or not literal(values[0]):
        raise Deny(LITERAL.format(label, values[0] or "an empty value"))
    return values[0]


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


def fetch_heads(top):
    """How many heads git merge FETCH_HEAD merges: the lines of this worktree's FETCH_HEAD not
    marked not-for-merge. None when it cannot be read. Each worktree has its own FETCH_HEAD,
    so git names the file (--git-path)."""
    path = run(["git", "-C", top, "rev-parse", "--git-path", "FETCH_HEAD"])
    if not path or not path.strip():
        return None
    try:
        with open(os.path.join(top, path.strip())) as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    return sum(1 for line in lines if line.strip() and line.split("\t")[1:2] != ["not-for-merge"])


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
    # Syncing with origin's own default branch lands work that is already there. The ref must
    # name it, as git resolves the name (origin/main, refs/remotes/origin/main, @{u}): another
    # ref at the same commit is still a change of its own.
    full = run(["git", "-C", top, "rev-parse", "--symbolic-full-name", ref])
    if (full or "").strip() == "refs/remotes/origin/" + dest:
        return
    if ref == "FETCH_HEAD":
        heads = fetch_heads(top)
        if heads != 1:
            raise Deny(FETCH_HEADS.format("it cannot be read" if heads is None
                                          else "it holds {}".format(heads)))
    source = ref[len("origin/"):] if ref.startswith("origin/") else ref
    check(ledger, top, source, dest, "HEAD", ref, "{}...{}".format(dest, ref), None)


# ------------------------------------------------------------------ the forge project
SCP_RE = re.compile(r"^(?:[^/@:]+@)?[^/:]+:(?!/)")


def split_url(url):
    """(host, project path) of a remote URL or a project reference: lowercased host, path as
    written, .git dropped."""
    u = url.strip()
    if "://" in u:
        parts = urlsplit(u)
        host, path = parts.hostname or "", parts.path
    elif SCP_RE.match(u):
        head, path = u.split(":", 1)
        host = head.split("@")[-1]
    else:
        host, path = "", u
    path = path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    return host.lower(), path


def same_project(named, host, path, tool):
    """Does a project the command names equal origin's (host, path)? A URL or an scp-style
    address names its host. Otherwise glab reads the whole value as a project path
    (GROUP/SUB/REPO, on its default host), and gh reads [HOST/]OWNER/REPO."""
    want = path.lower()
    if "://" in named or SCP_RE.match(named):
        h, p = split_url(named)
        return p.lower() == want and h == host
    v = named.strip("/").lower()
    if v.endswith(".git"):
        v = v[:-4]
    return v == want or (tool == "gh" and bool(host) and v == host + "/" + want)


def explicit_repo(tool, host, path):
    """The -R value that names origin's project with its host, as each CLI reads it."""
    return ("https://{}/{}" if tool == "glab" else "{}/{}").format(host or "<host>", path)


def forge_context(cwd, named, tool):
    """(toplevel, origin host, origin path) of the repository a glab or gh verb runs in. named
    is the project the command names, or None; then origin must be the only remote, because
    the CLI could otherwise pick another one."""
    top = toplevel(cwd)
    url = run(["git", "-C", top, "config", "--get", "remote.origin.url"])
    if not url or not url.strip():
        raise Deny(NO_ORIGIN.format(top))
    host, path = split_url(url)
    if named is not None:
        if not literal(named):
            raise Deny(LITERAL.format("the project", named))
        if not same_project(named, host, path, tool):
            raise Deny(OTHER_PROJECT.format(named, path))
    else:
        remotes = (run(["git", "-C", top, "remote"]) or "").split()
        if remotes != ["origin"]:
            raise Deny(SEVERAL_REMOTES.format(", ".join(r for r in remotes if r != "origin"),
                                              explicit_repo(tool, host, path)))
        check_resolved(top, host, path)
    return top, host, path


def check_resolved(top, host, path):
    """gh and glab remember a base project per remote - remote.<name>.gh-resolved (gh repo
    set-default writes it) and remote.<name>.glab-resolved - and a command naming no project
    acts on it. Each must be base or origin's project. git config exits 1 when there is no
    such setting; any other failure, or a timeout, is a deny."""
    try:
        p = subprocess.run(["git", "-C", top, "config", "--get-regexp",
                            r"^remote\..*\.(gh|glab)-resolved$"], capture_output=True,
                           timeout=CALL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        raise Deny(RESOLVED_UNREADABLE.format(top))
    if p.returncode == 1:
        return
    if p.returncode != 0:
        raise Deny(RESOLVED_UNREADABLE.format(top))
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        key, _, value = line.partition(" ")
        cli = "gh" if key.endswith(".gh-resolved") else "glab"
        value = value.strip()
        if value and value != "base" and not same_project(value, host, path, cli):
            raise Deny(RESOLVED.format(key, value, cli, path, explicit_repo(cli, host, path)))


def remote_head(top, branch):
    """origin's head of branch, as git ls-remote reads it: what the forge would propose."""
    if not literal(branch) or branch.startswith("-"):
        raise Deny(LITERAL.format("the source branch", branch))
    out = run(["git", "-C", top, "ls-remote", "origin", "refs/heads/" + branch])
    if out is None:
        raise Deny(LS_REMOTE.format(branch))
    for line in out.splitlines():
        sha, _, ref = line.partition("\t")
        if ref.strip() == "refs/heads/" + branch and FULL_ID.fullmatch(sha):
            return sha
    raise Deny(NOT_ON_ORIGIN.format(branch))


# ------------------------------------------------------------------ creating an MR/PR
GLAB_CREATE_VALUE = {"-s", "--source-branch", "-b", "--target-branch", "-R", "--repo", "-H",
                     "--head", "-t", "--title", "-d", "--description", "--description-file",
                     "-a", "--assignee", "-l", "--label", "-m", "--milestone", "--reviewer",
                     "-i", "--related-issue", "--template", "--attach"}
GH_CREATE_VALUE = {"-B", "--base", "-H", "--head", "-R", "--repo", "-a", "--assignee",
                   "--attach", "-b", "--body", "-F", "--body-file", "-l", "--label", "-m",
                   "--milestone", "-p", "--project", "--recover", "-r", "--reviewer", "-T",
                   "--template", "-t", "--title"}
# The flags creation allows, per CLI (glab 1.120, gh 2.102); any other is denied by name. Denied
# on purpose: --recover (replays options from a file), -w/--web (the browser finishes the
# creation), glab's -i/--related-issue (the issue can supply the branch) and
# --create-source-branch (only acts on a branch origin lacks, which the gate denies anyway).
# glab's -H/--head is a fork (FORK). --fill and --push are glab's pushing flags (see below).
GLAB_CREATE_ALLOWED = {"-s", "--source-branch", "-b", "--target-branch", "-R", "--repo", "-t",
                       "--title", "-d", "--description", "--description-file", "-a",
                       "--assignee", "-l", "--label", "-m", "--milestone", "--reviewer",
                       "--template", "--attach", "--allow-collaboration", "--auto-merge",
                       "--copy-issue-labels", "--draft", "--wip", "-f", "--fill",
                       "--fill-commit-body", "--no-editor", "--push", "--remove-source-branch",
                       "--signoff", "--squash-before-merge", "-y", "--yes"}
GH_CREATE_ALLOWED = {"-B", "--base", "-H", "--head", "-R", "--repo", "-a", "--assignee", "--attach",
                     "-b", "--body", "-F", "--body-file", "-l", "--label", "-m", "--milestone",
                     "-p", "--project", "-r", "--reviewer", "-T", "--template", "-t", "--title",
                     "-d", "--draft", "--dry-run", "-e", "--editor", "-f", "--fill",
                     "--fill-first", "--fill-verbose", "--no-maintainer-edit"}
GLAB_PUSHING = ("-f", "--fill", "--push")
FALSE = ("false", "0", "f")
FULL_ID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


def flag_on(values):
    """A boolean CLI flag as the CLI reads it: on when given bare or with a value other than
    false."""
    return bool(values) and (values[-1] is None or values[-1].lower() not in FALSE)


def current_source(ledger, top, name):
    """The current branch, the source when none is named. A detached HEAD has none; a lookup
    that failed or timed out says nothing. Both are denied, each with its own reason."""
    branch = ledger.current_branch(top)
    if branch is None:
        if (ledger.git(top, "rev-parse", "--abbrev-ref", "HEAD") or "") == "HEAD":
            raise Deny(DETACHED.format(top, name))
        raise Deny(BRANCH_LOOKUP.format(top, name))
    return branch


def judge_create_cli(shape, ledger):
    """glab mr create|new, gh pr create|new: the source is --source-branch/--head or the
    current branch, as origin has it; the destination must be named. Only the flags in
    GLAB_CREATE_ALLOWED and GH_CREATE_ALLOWED may be given. gh must name --head, because gh
    would otherwise take the head from push configuration. glab's --fill and --push push this
    checkout's HEAD to the source branch, so they are allowed only when that push changes
    nothing: HEAD is already origin's head of the source."""
    tool = shape["tool"]
    flags, _ = parse_flags(shape["args"], GLAB_CREATE_VALUE if tool == "glab" else GH_CREATE_VALUE)
    named = one(flags, ("-R", "--repo"), "-R/--repo") or env_repo(tool)
    top, host, path = forge_context(shape["cwd"], named, tool)
    check_cli_host(tool, top, host, path, named)
    if tool == "glab":
        if flags.get("-H") or flags.get("--head"):
            raise Deny(FORK.format("--head"))
        if flag_on(flags.get("--auto-merge")):
            raise Deny(DEFERRED.format("glab mr create --auto-merge",
                                       "glab mr merge <n> --sha <head> --auto-merge=false"))
    allowed = GLAB_CREATE_ALLOWED if tool == "glab" else GH_CREATE_ALLOWED
    for name in flags:
        if name not in allowed:
            raise Deny(CREATE_FLAG.format(name, "glab mr create" if tool == "glab" else "gh pr create"))
    if tool == "glab":
        source = one(flags, ("-s", "--source-branch"), "--source-branch")
        dest = one(flags, ("-b", "--target-branch"), "--target-branch")
        if dest is None:
            raise Deny(NEED_DEST.format("--target-branch <branch>"))
    else:
        source = one(flags, ("-H", "--head"), "--head")
        dest = one(flags, ("-B", "--base"), "--base")
        if dest is None:
            raise Deny(NEED_DEST.format("--base <branch>"))
        if source is None:
            raise Deny(NEED_HEAD)
        if ":" in source:
            owner, _, source = source.partition(":")
            if owner.lower() != path.split("/")[0].lower():
                raise Deny(FORK.format("--head " + owner + ":" + source))
    if source is None:
        source = current_source(ledger, top, "--source-branch")
    head = remote_head(top, source)
    pushing = [n for n in GLAB_PUSHING if tool == "glab" and flag_on(flags.get(n))]
    if pushing:
        local = (run(["git", "-C", top, "rev-parse", "HEAD"]) or "").strip()
        if local != head:
            raise Deny(PUSHES.format(pushing[0], local or "unknown", source, head))
    check(ledger, top, source, dest, "refs/remotes/origin/" + dest, head,
          "origin/{}...{}".format(dest, source), None)


GITLAB_MR = re.compile(r"^projects/([^/]+)/merge_requests(?:/(\d+)(/merge)?)?$")
GITHUB_PR = re.compile(r"^repos/([^/]+)/([^/]+)/pulls(?:/(\d+)(/merge)?)?$")
BRANCH_PLACEHOLDERS = (":branch", "{branch}")


def field(fields, name, top, ledger):
    """An api field's literal value, the current-branch placeholder resolved; None when the
    field is absent."""
    if name not in fields:
        return None
    value = fields[name]
    if value in BRANCH_PLACEHOLDERS:
        value = current_source(ledger, top, "the field " + name)
    if not value or not literal(value):
        raise Deny(LITERAL.format("the field " + name, value or "an empty value"))
    return value


def lookup_json(argv, top, what):
    value = None
    out = run(argv, top)
    try:
        value = json.loads(out) if out else None
    except ValueError:
        value = None
    if value is None:
        raise Deny(LOOKUP.format(what))
    return value


def origin_host(cwd):
    top = toplevel(cwd)
    url = run(["git", "-C", top, "config", "--get", "remote.origin.url"])
    if not url or not url.strip():
        raise Deny(NO_ORIGIN.format(top))
    return split_url(url)[0]


def host_of(value):
    """The lowercased host of a hostname, a host:port or a URL."""
    v = value.strip()
    return (urlsplit(v if "://" in v else "//" + v).hostname or "").lower()


GLAB_HOST_VARS = ("GITLAB_HOST", "GITLAB_URI", "GL_HOST", "GITLAB_URL")
GLAB_HOST_KEYS = ("host", "gitlab_host", "gitlab_uri", "gl_host")


def set_values(names):
    """The values of those environment variables that are set and not empty."""
    return [os.environ[k] for k in names if os.environ.get(k)]


def config_dir(variable, name):
    return os.environ.get(variable) or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), name)


def top_level(path):
    """(key, value) of each top-level line of a YAML config file; [] when there is no such
    file, None when it cannot be read. Indented lines (a host's token among them) are skipped
    unread. A value is unquoted, or loses an inline # comment."""
    found = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line[:1] in ("", " ", "\t", "#", "\n", "-") or ":" not in line:
                    continue
                key, _, value = line.partition(":")
                value = value.strip()
                if value[:1] in ("'", '"') and value.find(value[0], 1) > 0:
                    value = value[1:value.find(value[0], 1)]
                else:
                    value = re.split(r"\s#", value, maxsplit=1)[0].strip()
                found.append((key.strip().strip("'\""), value))
    except FileNotFoundError:
        return []
    except (OSError, UnicodeDecodeError):
        return None
    return found


def gh_default_host():
    """The host gh goes to when nothing names one (gh api without --hostname, -R OWNER/REPO):
    GH_HOST, else the one host gh's hosts.yml lists when it lists exactly one, else github.com.
    None when hosts.yml cannot be read."""
    if os.environ.get("GH_HOST"):
        return host_of(os.environ["GH_HOST"])
    hosts = top_level(os.path.join(config_dir("GH_CONFIG_DIR", "gh"), "hosts.yml"))
    if hosts is None:
        return None
    return host_of(hosts[0][0]) if len(hosts) == 1 else "github.com"


def glab_default_hosts(top):
    """The hosts glab may take for a project named without one: every set GITLAB_HOST,
    GITLAB_URI, GL_HOST and GITLAB_URL, else the host keys of its config.yml - the global one
    and the repository's own .git/glab-cli/config.yml - else gitlab.com. None when a config
    file cannot be read."""
    env = set_values(GLAB_HOST_VARS)
    if env:
        return env
    files = [os.path.join(config_dir("GLAB_CONFIG_DIR", "glab-cli"), "config.yml")]
    for flag in ("--absolute-git-dir", "--git-common-dir"):
        out = run(["git", "-C", top, "rev-parse", flag])
        if out is None or not out.strip():
            return None
        files.append(os.path.join(top, out.strip(), "glab-cli", "config.yml"))
    hosts = []
    for path in files:
        found = top_level(path)
        if found is None:
            return None
        hosts.extend(value for key, value in found if key in GLAB_HOST_KEYS and value)
    return hosts or ["gitlab.com"]


def check_api_host_var(host):
    """GITLAB_API_HOST, when set, sends every glab API request to its host: it must be origin's."""
    for value in set_values(("GITLAB_API_HOST",)):
        if host_of(value) != host:
            raise Deny(API_HOST_VAR.format(host_of(value) or value, host or "a local path"))


def remote_hosts(top):
    """The hosts of every remote URL, fetch and push, as git rewrites them; None when git
    cannot list them. A local-path remote has no host and is left out."""
    out = run(["git", "-C", top, "remote", "-v"])
    if out is None:
        return None
    hosts = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and split_url(parts[1])[0]:
            hosts.add(split_url(parts[1])[0])
    return hosts


def check_api_host(cwd, tool, call):
    """An api call must go to origin's host. An absolute endpoint names its host (a GitHub one
    may name origin's api. host); so does --hostname. Without either the CLI picks the host:
    gh from GH_HOST, else from its hosts.yml, else github.com; glab from GITLAB_HOST,
    GITLAB_URI, GL_HOST or GITLAB_URL, else from a remote on a host it is signed in to, so
    every remote must then be on origin's host. The guard reads its own environment: the
    command cannot set one, because an assignment or an env wrapper is not a plain command.
    Without --hostname glab also needs its configured default host to be origin's. An -R/--repo
    on the call is denied. Returns origin's host: every lookup the command needs is sent there,
    with --hostname or a host-qualified -R, never left to the environment."""
    if call["repo"] is not None:
        raise Deny(API_REPO.format(tool, call["repo"]))
    top = toplevel(cwd)
    host = origin_host(top)
    where = host or "a local path"
    if tool == "glab":
        check_api_host_var(host)
    endpoint = call["endpoint"] or ""
    chosen = []
    if call["hostname"] is not None:
        chosen = [call["hostname"]]
    elif "://" in endpoint:
        pass
    elif tool == "gh":
        picked = gh_default_host()
        if picked is None:
            raise Deny(UNREADABLE.format("gh's hosts.yml", "--hostname " + where))
        chosen = [picked]
    else:
        chosen = set_values(GLAB_HOST_VARS)
        if not chosen:
            hosts = remote_hosts(top)
            if hosts is None or hosts - {host}:
                raise Deny(SEVERAL_HOSTS.format(
                    ", ".join(sorted(hosts - {host})) if hosts else "unreadable", where))
            # With no login for origin's host, glab falls back to its configured default host.
            defaults = glab_default_hosts(top)
            if defaults is None:
                raise Deny(UNREADABLE.format("glab's config.yml", "--hostname " + where))
            for value in defaults:
                if host_of(value) != host:
                    raise Deny(API_DEFAULT_HOST.format(host_of(value) or value, where))
    for value in chosen:
        if host_of(value) != host:
            raise Deny(OTHER_HOST.format(host_of(value) or value, where))
    if "://" in endpoint:
        named = host_of(endpoint)
        if named not in (host, "api." + host):
            raise Deny(OTHER_HOST.format(named, where))
    return host


def env_repo(tool):
    """The project the environment names for a CLI verb given no -R: GITLAB_REPO for glab,
    GH_REPO for gh. It also fills the :id and {owner}/{repo} placeholders of an api call."""
    return os.environ.get("GITLAB_REPO" if tool == "glab" else "GH_REPO") or None


def check_cli_host(tool, top, host, path, named):
    """A glab or gh verb must reach origin's host too. A project named with its host (a URL,
    or gh's HOST/OWNER/REPO) has had it checked by forge_context. One named by its path alone
    goes to the CLI's default host: gh_default_host() for gh, glab_default_hosts() for glab.
    With no project named, the CLI takes the checkout's one remote, origin, and fails when a
    host variable names another host. Returns origin's host, where every lookup is then
    sent."""
    where = host or "a local path"
    if tool == "glab":
        check_api_host_var(host)
    if named is None or "://" in named or SCP_RE.match(named):
        return host
    bare = named.strip("/").lower()
    if bare.endswith(".git"):
        bare = bare[:-4]
    if bare != path.lower():
        return host
    fix = "-R " + explicit_repo(tool, host, path)
    if tool == "gh":
        picked = gh_default_host()
        if picked is None:
            raise Deny(UNREADABLE.format("gh's hosts.yml", fix))
        chosen = [picked]
    else:
        chosen = glab_default_hosts(top)
        if chosen is None:
            raise Deny(UNREADABLE.format("glab's config.yml", fix))
    for value in chosen:
        if host_of(value) != host:
            raise Deny(DEFAULT_HOST.format(named, host_of(value) or value, where, fix))
    return host


def gitlab_project(cwd, segment, hostname):
    """The repository context of a GitLab project segment - an encoded path, a numeric id
    (looked up on hostname), or the :id / :fullpath placeholder - checked against origin."""
    if segment in (":id", ":fullpath"):
        return forge_context(cwd, env_repo("glab"), "glab")
    if segment.isdigit():
        found = lookup_json(["glab", "api", "--hostname", hostname, "projects/" + segment],
                            toplevel(cwd), "project " + segment)
        named = found.get("path_with_namespace") if isinstance(found, dict) else None
        if not isinstance(named, str) or not named:
            raise Deny(LOOKUP.format("project " + segment))
        return forge_context(cwd, named, "glab")
    return forge_context(cwd, unquote(segment), "glab")


def github_project(cwd, owner, repo):
    if (owner, repo) == ("{owner}", "{repo}"):
        return forge_context(cwd, env_repo("gh"), "gh")
    return forge_context(cwd, owner + "/" + repo, "gh")


def judge_create_gitlab_api(shape, ledger, segment, fields, host):
    top, host, path = gitlab_project(shape["cwd"], segment, host)
    if "target_project_id" in fields:
        raise Deny(FORK.format("target_project_id"))
    source = field(fields, "source_branch", top, ledger)
    dest = field(fields, "target_branch", top, ledger)
    if source is None or dest is None:
        raise Deny(UNRESOLVED_API.format("glab"))
    check(ledger, top, source, dest, "refs/remotes/origin/" + dest, remote_head(top, source),
          "origin/{}...{}".format(dest, source), None)


def judge_create_github_api(shape, ledger, owner, repo, fields):
    top, host, path = github_project(shape["cwd"], owner, repo)
    if "head_repo" in fields:
        raise Deny(FORK.format("head_repo"))
    source = field(fields, "head", top, ledger)
    dest = field(fields, "base", top, ledger)
    if source is None or dest is None:
        raise Deny(UNRESOLVED_API.format("gh"))
    if ":" in source:
        who, _, source = source.partition(":")
        if who.lower() != path.split("/")[0].lower():
            raise Deny(FORK.format("head " + who + ":" + source))
    check(ledger, top, source, dest, "refs/remotes/origin/" + dest, remote_head(top, source),
          "origin/{}...{}".format(dest, source), None)


# ------------------------------------------------------------------ merging an MR/PR
GLAB_MERGE_VALUE = {"-m", "--message", "--sha", "--squash-message", "-R", "--repo"}
GH_MERGE_VALUE = {"-A", "--author-email", "-b", "--body", "-F", "--body-file",
                  "--match-head-commit", "-t", "--subject", "-R", "--repo"}
# The flags a merge allows, per CLI (glab 1.120, gh 2.102); any other is denied by name. Denied
# on purpose: gh's --admin (it merges past required reviews and checks) and glab's hidden
# --when-pipeline-succeeds. glab's --auto-merge is read by the deferred-merge check, which
# allows it only when it is off.
GLAB_MERGE_ALLOWED = {"--sha", "--auto-merge", "-m", "--message", "-s", "--squash",
                      "--squash-message", "-r", "--rebase", "-d", "--remove-source-branch", "-y",
                      "--yes", "-R", "--repo"}
GH_MERGE_ALLOWED = {"--match-head-commit", "-m", "--merge", "-r", "--rebase", "-s", "--squash",
                    "-t", "--subject", "-b", "--body", "-F", "--body-file", "-A", "--author-email",
                    "-d", "--delete-branch", "-R", "--repo"}
GH_VIEW_FIELDS = ("baseRefName,headRefName,headRefOid,isCrossRepository,headRepository,"
                  "headRepositoryOwner")
# The CLIs' own patterns for the path of a PR/MR URL (gh 2.102's and glab 1.120's, read from
# their binaries): each takes the number before any trailing path (/files, /diffs, /commits),
# and glab takes the /-/ as optional.
PR_URL = re.compile(r"^/([^/]+/[^/]+)/pull/(\d+)(.*$)")
MR_URL = re.compile(r"^(/(?:[^-][^/]+/){2,})+(?:-/)?merge_requests/(\d+)(?:/.*)?$")
MERGE_QUEUE = ("query($owner:String!,$name:String!,$branch:String!){repository(owner:$owner,"
               "name:$name){mergeQueue(branch:$branch){id}}}")
BRANCH_MERGES = re.compile(r"(^|/)merges(/|$)")
FORGE_MADE_FORMS = {
    "glab": ("glab mr for", "glab mr create --source-branch <branch> --target-branch <dest>"),
    "gh": ("gh pr revert", "gh pr create --head <branch> --base <dest>"),
}


def explicitly_off(values):
    return bool(values) and values[-1] is not None and values[-1].lower() in FALSE


def on_value(value):
    """An api field that switches something on: present with any value but false."""
    return value is not None and value.lower() not in FALSE


def url_number(target, host, path, pattern, what):
    """The number of the MR/PR a URL argument names, once its host and project are origin's:
    a URL can name any repository on any forge."""
    parts = urlsplit(target)
    m = pattern.match(parts.path)
    if (not m or (parts.hostname or "").lower() != host
            or m.group(1).strip("/").lower() != path.lower()):
        raise Deny(OTHER_URL.format(what, target, host, path))
    return m.group(2)


def gitlab_mr(top, project, number, branch, hostname):
    """(source, target, head, iid) of a GitLab MR on hostname - by number, or the one open MR
    from branch. Its source and target project must be the project it was looked up in: a
    fork's MR is denied."""
    base = ["glab", "api", "--hostname", hostname]
    if number is not None:
        mr = lookup_json(base + ["projects/{}/merge_requests/{}".format(project, number)], top,
                         "MR !" + number)
    else:
        found = lookup_json(base + ["projects/{}/merge_requests?source_branch={}&state=opened"
                                    .format(project, quote(branch, safe=""))], top,
                            "the MR from " + branch)
        if not isinstance(found, list) or len(found) != 1:
            raise Deny(NOT_ONE.format(len(found) if isinstance(found, list) else "no", branch))
        mr = found[0]
    if not isinstance(mr, dict) or not all(isinstance(mr.get(k), str) and mr.get(k)
                                           for k in ("source_branch", "target_branch", "sha")):
        raise Deny(LOOKUP.format("MR " + (number or branch)))
    ids = [mr.get(k) for k in ("project_id", "source_project_id", "target_project_id")]
    if not all(isinstance(i, int) for i in ids) or len(set(ids)) != 1:
        raise Deny(FORK.format("MR !" + str(mr.get("iid") or number or branch)))
    return mr["source_branch"], mr["target_branch"], mr["sha"], str(mr.get("iid") or number or "")


def gitlab_merge_train(top, project, hostname):
    """Deny when the project on hostname merges through a merge train: the merge would join
    the train, a deferred merge. A failed lookup is a deny too; a project without the setting
    has no train."""
    found = lookup_json(["glab", "api", "--hostname", hostname, "projects/" + project], top,
                        "project " + unquote(project))
    if not isinstance(found, dict):
        raise Deny(LOOKUP.format("project " + unquote(project)))
    if found.get("merge_trains_enabled") is True:
        raise Deny(QUEUED.format("the merge train of " + unquote(project)))


def github_pr(top, target, repo, owner, name):
    """(source, base, head) of a GitHub PR, as gh pr view resolves target in repo, a
    host-qualified HOST/OWNER/NAME. With no target, gh needs no -R: it takes the current
    branch's PR where the merge itself would. A cross-repository PR, or one whose head lives
    anywhere but origin's project, is denied."""
    what = "PR " + (target or "of the current branch")
    pr = lookup_json(["gh", "pr", "view"] + ([target, "-R", repo] if target else [])
                     + ["--json", GH_VIEW_FIELDS], top, what)
    if not isinstance(pr, dict):
        raise Deny(LOOKUP.format(what))
    values = [pr.get(k) for k in ("headRefName", "baseRefName", "headRefOid")]
    if not all(isinstance(v, str) and v for v in values):
        raise Deny(LOOKUP.format(what))
    head_repo = pr.get("headRepository") if isinstance(pr.get("headRepository"), dict) else {}
    head_owner = (pr.get("headRepositoryOwner")
                  if isinstance(pr.get("headRepositoryOwner"), dict) else {})
    if (pr.get("isCrossRepository") is not False
            or str(head_owner.get("login", "")).lower() != owner.lower()
            or str(head_repo.get("name", "")).lower() != name.lower()):
        raise Deny(FORK.format(what))
    return values[0], values[1], values[2]


def github_merge_queue(top, host, owner, name, dest):
    """Deny when dest merges through a merge queue: gh pr merge would then enable auto-merge
    or enqueue the PR, a deferred merge. A failed lookup is a deny too."""
    what = "the merge queue of " + dest
    found = lookup_json(["gh", "api", "graphql", "--hostname", host,
                         "-f", "query=" + MERGE_QUEUE, "-f", "owner=" + owner,
                         "-f", "name=" + name, "-f", "branch=" + dest], top, what)
    try:
        queue = found["data"]["repository"]["mergeQueue"]
    except (KeyError, TypeError):
        raise Deny(LOOKUP.format(what))
    if queue is not None:
        raise Deny(QUEUED.format(what))


def merge_pinned(ledger, top, source, dest, head, pin, hint):
    """A forge merge pinned to pin; hint is the immediate pinned merge, {} for the head."""
    if pin is None:
        raise Deny(UNPINNED.format(head, hint.format(head)))
    if not FULL_ID.fullmatch(pin):
        raise Deny(FULL_SHA.format(pin))
    check(ledger, top, source, dest, "refs/remotes/origin/" + dest, pin,
          "origin/{}...{}".format(dest, source), hint.format(pin))


def judge_merge_cli(shape, ledger):
    """glab mr merge|accept [<n>|!<n>|<branch>|<url>], gh pr merge [<n>|<url>|<branch>]:
    pinned, immediate, from origin's own project, and the destination read from the forge.
    Only the flags in GLAB_MERGE_ALLOWED and GH_MERGE_ALLOWED may be given. gh pr merge
    --disable-auto, with no other flag but -R, turns auto-merge off and merges nothing."""
    tool = shape["tool"]
    flags, pos = parse_flags(shape["args"], GLAB_MERGE_VALUE if tool == "glab" else GH_MERGE_VALUE)
    if (tool == "gh" and flag_on(flags.get("--disable-auto"))
            and set(flags) <= {"--disable-auto", "-R", "--repo"}):
        return
    named = one(flags, ("-R", "--repo"), "-R/--repo") or env_repo(tool)
    top, host, path = forge_context(shape["cwd"], named, tool)
    check_cli_host(tool, top, host, path, named)
    if len(pos) > 1:
        raise Deny(ONE_TARGET.format("MR" if tool == "glab" else "PR"))
    target = pos[0] if pos else None
    if target is not None and not literal(target):
        raise Deny(LITERAL.format("the MR/PR", target))
    if tool == "glab":
        # glab turns auto-merge on by default while a pipeline runs: only an explicit
        # --auto-merge=false is an immediate merge.
        if not explicitly_off(flags.get("--auto-merge")) or flag_on(flags.get("--when-pipeline-succeeds")):
            raise Deny(DEFERRED.format("glab mr merge without --auto-merge=false",
                                       "glab mr merge <n> --sha <head> --auto-merge=false"))
    elif flag_on(flags.get("--auto")):
        raise Deny(DEFERRED.format("gh pr merge --auto", "gh pr merge <n> --merge --match-head-commit <head>"))
    allowed, verb = ((GLAB_MERGE_ALLOWED, "glab mr merge") if tool == "glab"
                     else (GH_MERGE_ALLOWED, "gh pr merge"))
    for flag in flags:
        if flag not in allowed:
            raise Deny(MERGE_FLAG.format(flag, verb))
    if tool == "glab":
        if target is not None and "://" in target:
            target = url_number(target, host, path, MR_URL, "MR")
        elif target is not None and re.fullmatch(r"![0-9]+", target):
            target = target[1:]                        # glab reads !7 as MR 7
        number = target if target and target.isdigit() else None
        branch = None if number else (target or current_source(ledger, top, "the MR number"))
        project = quote(path, safe="")
        source, dest, head, iid = gitlab_mr(top, project, number, branch, host)
        gitlab_merge_train(top, project, host)
        pin = one(flags, ("--sha",), "--sha")
        hint = "glab mr merge " + (iid or "<n>") + " --sha {} --auto-merge=false"
    else:
        if target is not None and "://" in target:
            target = url_number(target, host, path, PR_URL, "PR")
        owner, _, name = path.partition("/")
        source, dest, head = github_pr(top, target, host + "/" + path, owner, name)
        github_merge_queue(top, host, owner, name, dest)
        pin = one(flags, ("--match-head-commit",), "--match-head-commit")
        hint = "gh pr merge " + (target or "<n>") + " --merge --match-head-commit {}"
    merge_pinned(ledger, top, source, dest, head, pin, hint)


def judge_merge_gitlab_api(shape, ledger, segment, number, fields, host):
    """A REST merge: the MR and the project's merge train are read from origin's project on
    host, the host the call was checked to reach."""
    top, host, path = gitlab_project(shape["cwd"], segment, host)
    hint = "glab api -X PUT projects/{}/merge_requests/{}/merge -f sha={{}}".format(segment, number)
    if on_value(fields.get("merge_when_pipeline_succeeds")) or on_value(fields.get("auto_merge")):
        raise Deny(DEFERRED.format("merge_when_pipeline_succeeds/auto_merge", hint.format("<head>")))
    project = quote(path, safe="")
    source, dest, head, _ = gitlab_mr(top, project, number, None, host)
    gitlab_merge_train(top, project, host)
    merge_pinned(ledger, top, source, dest, head, field(fields, "sha", top, ledger), hint)


def judge_merge_github_api(shape, ledger, owner, repo, number, fields, host):
    """A REST merge: the PR and the merge queue are read from origin's project on host."""
    top, host, path = github_project(shape["cwd"], owner, repo)
    o, _, n = path.partition("/")
    source, dest, head = github_pr(top, number, host + "/" + path, o, n)
    github_merge_queue(top, host, o, n, dest)
    merge_pinned(ledger, top, source, dest, head, field(fields, "sha", top, ledger),
                 "gh api -X PUT repos/{}/{}/pulls/{}/merge -f sha={{}}".format(owner, repo, number))


def judge_api(shape, ledger):
    """The REST create and merge endpoints are checked; GraphQL, the merges endpoint and every
    other MR/PR write are denied. The call must reach origin's host. gh sends a write's fields
    in its body, and GitHub may not read a write's query string, so a gh write carrying one is
    denied; glab's query fields are read with its body fields, as GitLab reads both."""
    tool, call = shape["tool"], parse_api(shape["args"])
    endpoint = call["endpoint"] or ""
    if is_graphql(endpoint):
        raise Deny(GRAPHQL)
    if BRANCH_MERGES.search(unquote(endpoint_parts(endpoint)[0])):
        raise Deny(BRANCH_MERGE.format(tool))
    if not literal(endpoint):
        raise Deny(LITERAL.format("the api endpoint", endpoint))
    if call["body"]:
        raise Deny(UNRESOLVED_API.format(tool))
    if tool == "gh" and "?" in endpoint:
        raise Deny(QUERY_STRING.format(endpoint))
    host = check_api_host(shape["cwd"], tool, call)
    path, query = endpoint_parts(endpoint)
    fields = dict(query)
    fields.update(call["fields"])
    if tool == "glab":
        m = GITLAB_MR.match(path)
        if m and call["method"] == "POST" and m.group(2) is None:
            return judge_create_gitlab_api(shape, ledger, m.group(1), fields, host)
        if m and call["method"] == "PUT" and m.group(3):
            return judge_merge_gitlab_api(shape, ledger, m.group(1), m.group(2), fields, host)
    else:
        m = GITHUB_PR.match(path)
        if m and call["method"] == "POST" and m.group(3) is None:
            return judge_create_github_api(shape, ledger, m.group(1), m.group(2), fields)
        if m and call["method"] == "PUT" and m.group(4):
            return judge_merge_github_api(shape, ledger, m.group(1), m.group(2), m.group(3),
                                          fields, host)
    raise Deny(UNRESOLVED_API.format(tool))


def judge(shape, ledger):
    kind = shape["kind"]
    if kind == "merge-local":
        return judge_git_merge(shape, ledger)
    if kind == "create":
        return judge_create_cli(shape, ledger)
    if kind == "forge-made":
        raise Deny(FORGE_MADE.format(*FORGE_MADE_FORMS[shape["tool"]]))
    if kind == "merge":
        return judge_merge_cli(shape, ledger)
    return judge_api(shape, ledger)


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
    missing = Deny("Pre-merge gate: the ledger helper {} cannot be loaded, so the command is "
                   "refused. Restore it (chezmoi apply).".format(LEDGER_PATH))
    spec = importlib.util.spec_from_file_location("xreview_ledger", LEDGER_PATH)
    if spec is None or spec.loader is None:
        raise missing
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception:                                  # missing, unreadable or broken
        raise missing
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
