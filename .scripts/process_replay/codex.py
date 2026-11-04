"""One Codex pre-merge round of a replay run (spec 4.4, 7.1, 8).

The round is what xreview runs today for a pre-merge review: today's reviewer instructions, findings
schema and packet builder with today's switches (dot_config/xreview/packets.conf), through xreview-rpc
primitives on the replay's own Codex daemon, so no pane, ledger, gate or round counter is touched.

codex_round(a, run, case, branch, home) reads from the run state `run`:
  scratch    the scratch repository (its work tree), physically under a neutral path (Task 8 puts it under
             $XDG_STATE_HOME/review-work/scratch/<label>: Codex may resolve a symlinked cwd to its real path).
             It is the cwd and <scratch>/.git the target's repository; a path (or realpath) naming
             process-replay is refused, so no path a reviewer sees names the replay
  thread     the review thread so far (None before round 1)
  reviews    the reviews so far: this round is k = 1 + the Codex ones; `round` is not read
  rejected   identifiers of the findings judged not defects, accumulated over the run
  addressed  identifiers (`identifier`) of the findings matched in the previous review, set by the caller
             (the run state of the Shared records has no such key; absent reads as none)
  ledger     the run's ledger (prepare_ledger, called for every run at setup); codex_round raises Failed without it
  tokens     Codex tokens spent by this run so far
  case, label  the run's place under <state>/runs/<case>/<label>/
and from `a`: state, max_tokens, budget. It returns the review, which the caller appends to
run["reviews"] and whose `thread` it makes the run's thread:
  {kind: "codex", k, findings, verdict, tokens, turns: [[thread, turn]], model, effort, missing, decision, thread}
or one of
  {paused: str, resets_at: int, tokens?}  the weekly window is at WEEKLY_PAUSE percent or more; no further turn was started (every packet's turn asks)
  {stopped: str, tokens?}               the token stop was reached (spent_now: every completed turn of every run, in flight or charged, counts); no further turn was started
                                        With `tokens`, packets before the stop ran: they are charged to the run, the leak scan covered them (a leak
                                        returns {leak} as usual), and the round is no review, so the next command redoes it whole.
  {leak: [str], tokens, thread, turns}  a turn read or ran something that could give it the answers (forbidden()): the round is void
The token stop blocks only new turns, so the overshoot is bounded by one turn per job in flight. That holds because every completed turn is counted
at once in a tally shared by all rounds of the process (flight_add), and every turn start asks spent_now: the charged tokens of every run plus the
tally of the rounds in flight. The caller charges a round's outcome to its run inside settling(), which drops the round from the tally in the same
step, so no turn is counted twice or missed in between.
A round that fails raises RoundFailed (a Failed that carries the tokens its turns used, the thread, and `.leak`:
what the scan of whatever turns it ran found). The caller adds `tokens` of every outcome to the run's.

The leak scan (spec 7.1, 13) is one matcher for every reviewer: these Codex rounds (leaks), the final reviewer and its subagents
(final.py) and section 6's arms (xreview-replay.py leak_scan). Each caller passes its wall (forbidden(): the forbidden roots, among
them the live ~/.codex and ~/.claude whole, and the reviewer's allowed subtrees: its own, and the instructions every reviewer is given,
INSTRUCTIONS, except in a case of the chezmoi source, whose later state the deployed instructions are). A tool call is reduced to path-like tokens: the words of its shell commands (each simple command, looking through
wrappers, sh -c, $( ), backticks and heredoc bodies), the pieces of each word between quotes, spaces and : , = { } (so --git-dir=x,
NAME=x and a path inside an inline script count), a short option's glued value (-Cx), and its path fields (workdir, Read/Grep/Glob
paths). A search pattern is not a path: grep's, rg's, ag's, ack's or git grep's first operand or the value of the option that gives
it (-e, ag/ack -g, ack --match), rg's --replace, ag's -G, git log's (show, diff, ...) -S, -G and --grep values, and a Grep's pattern;
the substitutions inside one still run. Each token is resolved from the directory a left-to-right cd tracker holds (the call's
workdir, else the scratch; `cd X &&` and `;` move it, cd - goes back, a subshell's cd ends with it, a cd to a substitution goes to
a directory of that literal name), with ~, $HOME, $XDG_STATE_HOME, $XDG_DATA_HOME, $PWD (and $(pwd)) and, for Codex, $CODEX_HOME
expanded, then read two ways, ./.. collapsed first and symlinks first, each by its real path. A real path is forbidden when it lies
in a root at component boundaries (a glob component counts as whatever it can match; the original checkout's root also covers its wt
siblings <dir>-*), unless it lies literally in one of the allowed subtrees. Allowed subtrees are judged after resolution, so
<allowed>/../x is judged where it lands. A recursive search (rg, ag, ack, grep -r/-R, find, fd, tree, ls -R; the Grep and Glob
tools) also reads every root beneath its own root, which is resolved like any path, the working directory when it names none
(redirections and their targets are not operands); rg, ag, ack and grep in a pipe read the pipe. A repo-specific tool that reads
the checkout without naming it (TOOLS: chezmoi for the chezmoi source) is judged by the paths it names when it is run as a command (the
effective command of a simple command, looking through env, sudo, command, xargs, timeout, nice and `mise exec --`, sh -c, $( ) and backticks;
command -v, which, type and hash only look it up; a heredoc body is not run, but the $( ) and backticks of an unquoted one are): _chezmoi reads
`--version` and `help` as reading nothing, a call with no -S/--source as reading the original, and a call that gives a source (the flags may stand
before or after the subcommand) as reading its paths: each source and the destination (-D/--destination, default ~) is a search root, since chezmoi
walks them, and --config, --cache and --persistent-state are words judged as paths. No subcommand is exempt from the destination: with a
.chezmoiremove in the source (this repository's has one), managed and source-path read it too (R3; t_codex.py real_chezmoi_source_only). A source or
destination the scan cannot expand ($X, $(...)) and an unknown option followed by a source, destination or --version flag (which it may take as its
value) read the original.
Known limits, not chased further. Missed: an unknown variable ($DIR/x stays literal, and so does a cd to it), a path built at run
time (string concatenation in a script, a variable set in another call, or to a value that is not literal), ANSI-C quoting ($'...' escapes are not decoded), env -C DIR (the
command's directory is not moved), reads spread over separate calls (a cd in one call does not carry to the next), aliases or
functions defined earlier, a function's body run from another directory (it is read where it is defined), a loop body that runs a use again after a later assignment, brace expansion (~/.codex/{sessions,x}), a ** glob spanning several components, an unquoted substitution
glued to more text (`pwd`/x and $(pwd)/x split into two words, so ../ after it starts from /), a walk by any other command (cp -r,
rsync, tar, du, a script's os.walk), GNU grep -r with no operand in a pipe (it walks the working directory; it is taken to read the
pipe, as BSD grep does); for running a TOOLS word, a command assembled at run time ($(which chezmoi) diff, or a --source built that way), a heredoc fed to a shell
(sh <<EOF), find -exec, and a long xargs option with a separate value (--max-args 1); for chezmoi, an unknown option that takes a
value and swallows a word other than a source, destination or --version flag or a short cluster holding S or D (it is read as the subcommand or an operand); and, for
chezmoi, what the source's own templates (include, output, stat), run_ scripts and externals read at run time under a scratch -S/-D, which is judged by those paths only. Counted
though nothing is read: text that merely names a root (echo, a heredoc written to a file, a prose argument), a command bash rejects as
a syntax error (ls >#x cat ~/.codex/y, 2>#x), a search pattern inside
a script word other than sh -c's or a $( ) (eval '...', ssh host '...'), a grep option that takes a value but is missing from GREPS
(its value is taken for the pattern, the pattern for a path), a depth-limited walk above a root (find ~ -maxdepth 1, tree -L 1 ~:
the limit is not read), a glob * that matches a dot directory the shell would skip (~/* counts as naming ~/.codex), a function body
that never runs (it is read where it is defined, its assignments and cds included), and a command nested more than MAX_DEPTH levels
deep in sh -c, $( ), backticks and heredoc bodies (it is not followed: TOO_DEEP, which quotes its first EXCERPT characters). A
pipeline's cd is kept for what follows it (a subshell ends only at parentheses).

Codex homes are paths (codexhome.py): this module sets CODEX_HOME to the replay home for the rpc calls and the
rollout reads of a round, and drops an inherited XREVIEW_RPC_SOCK or XREVIEW_RPC_STDIO, which would aim a call
elsewhere. The environment is process-wide: rounds on one home may run together, a second home may not.
"""
import calendar
import collections
import contextlib
import fnmatch
import glob
import json
import os
import re
import shlex
import subprocess
import threading
import time

from . import common as C
from . import planreview
from .common import Failed, L, XP, XR, jload, jsave

WEEKLY_MINUTES = 10080
WEEKLY_PAUSE = 80          # percent of the weekly window at which runs wait for the reset (spec 8)
WEEKLY_SCAN = 8            # newest rollouts looked through for a weekly figure
IDENTIFIER_SUMMARY = 80
CALLS = (b'"custom_tool_call"', b'"function_call"', b'"local_shell_call"')
DROPPED = ("XREVIEW_RPC_SOCK", "XREVIEW_RPC_STDIO")


class RoundFailed(Failed):
    """A round that could not finish. `tokens` is what its turns used before it failed, `thread` the last
    thread it used (None before any)."""

    def __init__(self, message, tokens=0, thread=None):
        Failed.__init__(self, message)
        self.tokens = tokens
        self.thread = thread
        self.leak = []


# ------------------------------------------------------------------ the replay home in the environment
_ENV = {"home": None, "n": 0, "saved": None}
_ENV_LOCK = threading.Lock()


@contextlib.contextmanager
def homed(home):
    with _ENV_LOCK:
        if _ENV["n"] and _ENV["home"] != home:
            raise Failed("CODEX_HOME is already set to {}: rounds on two homes cannot share a process".format(_ENV["home"]))
        if not _ENV["n"]:
            _ENV["saved"] = dict((v, os.environ.get(v)) for v in ("CODEX_HOME",) + DROPPED)
            os.environ["CODEX_HOME"] = home
            for v in DROPPED:
                os.environ.pop(v, None)
        _ENV["home"] = home
        _ENV["n"] += 1
    try:
        yield
    finally:
        with _ENV_LOCK:
            _ENV["n"] -= 1
            if not _ENV["n"]:
                for v, old in _ENV["saved"].items():
                    if old is None:
                        os.environ.pop(v, None)
                    else:
                        os.environ[v] = old
                _ENV["home"] = None


_homed = homed          # the name t_codex.py uses


@contextlib.contextmanager
def _state_home(home):
    """L.state_home answers `home` for the calling thread while it builds a packet (as XR.prepare swaps it,
    which XP.build's ledger read needs); other threads still see the real one."""
    me = threading.get_ident()
    with XR.LOCK:
        old = L.state_home          # read under the lock: an overlapping swap would otherwise be restored as "real"
        L.state_home = lambda: home if threading.get_ident() == me else old()
        try:
            yield
        finally:
            L.state_home = old


# ------------------------------------------------------------------ text
def identifier(finding):
    """`<file>:<line> <first 80 chars of the summary>`: how a finding is named to the next round's reviewer."""
    summary = " ".join(str(finding.get("summary") or "").split())[:IDENTIFIER_SUMMARY]
    line = finding.get("line")
    return "{}{} {}".format(finding.get("file"), "" if line is None else ":{}".format(line), summary)


def _range(branch):
    return "{}...{}".format(branch.get("dest_ref") or branch["dest"], branch.get("branch") or "HEAD")


def body(branch, k, addressed, rejected):
    """The request's body. Round 1's is the body XR.prepare writes for the same target; later rounds add
    what a fix round's dispatch adds: the findings addressed since the last round and those judged not defects."""
    text = ("Pre-merge review of {} against {}: the change is {}. Review the change as it "
            "now stands. Your working directory is this repository at this round's tip: read files only there. Paths "
            "from earlier turns of this thread name other checkouts; ignore them.\n".format(
                branch.get("branch") or "the branch", branch["dest"], _range(branch)))
    if k >= 2:
        if addressed:
            text += "Addressed since the last round: {}.\n".format("; ".join(addressed))
        if rejected:
            text += "Judged not defects: {}.\n".format("; ".join(rejected))
    return text


# ------------------------------------------------------------------ the scratch ledger
def _entries(branch):
    """The receipts of the branch's repository, a nonce once (XR.ledgers: across its ledgers too), from every ledger that names it."""
    return [e for _repo, entries in XR.ledgers(only=branch["repo"]) for e in entries]


def _repo(a, run):
    """The scratch repository's git directory, as the packet builder and the ledger name it. The scratch path
    must be neutral: one naming process-replay (itself or its realpath) is refused."""
    scratch = run["scratch"].rstrip("/")
    for p in (scratch, os.path.realpath(scratch)):
        if "process-replay" in p:
            raise Failed("the scratch repository {} names the replay; it must live under a neutral path".format(p))
    return scratch + "/.git"


def prepare_ledger(a, run, case, branch):
    """The run's ledger, a state home for XP.build, written once under <state>/runs/<case>/<label>/ledger and
    recorded in run["ledger"]: the branch's entries up to its original round 1, as XR.enriched reads them, with
    the plan receipts rebound to the scratch repository (`targets[].repo`) and the plan_blobs of those the original
    cannot derive (a plan commit that survives only in the snapshot) read through the private view
    (planreview.Reader). It reads the ORIGINAL Codex home's rollouts for cleanliness, so call it for every run at
    setup, before any replay home is in the environment; codex_round only uses it."""
    if _ENV["n"]:
        raise Failed("the run's ledger reads the original Codex home; a replay home is set")
    repo = _repo(a, run)
    home = os.path.join(a.state, "runs", case["id"], run["label"], "ledger")
    first = branch["rounds"][0]
    entries = XR.enriched(_entries(branch), first["at"], first["thread"])
    reader = planreview.Reader(a.state, branch["repo"], a.snapshot_root)
    for e in entries:
        if e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "plan":
            for t in e.get("targets") or []:
                if not t.get("plan_blobs"):
                    t["plan_blobs"] = reader.plan_blobs(t["base"], t["tip"]) or {}
                t["repo"] = repo
    jsave(os.path.join(home, "xreview", "ledgers", L.ledger_key(repo), "reviews.jsonl"),
          "".join(json.dumps(e) + "\n" for e in entries))
    run["ledger"] = home
    return home


# ------------------------------------------------------------------ rollouts
def _lines(path):
    """The lines of a rollout, plain or zstd."""
    if path.endswith(".zst"):
        p = subprocess.run(["zstd", "-dc", "--", path], capture_output=True, timeout=300)
        return p.stdout.splitlines() if p.returncode == 0 else []
    with open(path, "rb") as f:
        return f.read().splitlines()


def _mtime(path):
    """A file's modification time, 0 for one that moved away since it was listed."""
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def _rollouts(home):
    found = []
    for sub in ("sessions", "archived_sessions"):
        base = glob.escape(os.path.join(home, sub))
        found += glob.glob(os.path.join(base, "**", "rollout-*.jsonl*"), recursive=True)
    found = [p for p in found if re.search(r"\.jsonl(\.zst)?\Z", p)]
    return sorted(found, key=_mtime, reverse=True)


def _live_home():
    """Michael's Codex home, whose rate limits are the account's: CODEX_HOME as the process had it before a round
    set the replay home, else ~/.codex. Read only."""
    with _ENV_LOCK:
        env = _ENV["saved"]["CODEX_HOME"] if _ENV["n"] else os.environ.get("CODEX_HOME")
    return env or os.path.join(os.path.expanduser("~"), ".codex")


def _epoch(stamp):
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?", stamp if isinstance(stamp, str) else "")
    return calendar.timegm(tuple(int(x) for x in m.groups()[:6]) + (0, 0, 0)) + float(m.group(7) or 0) if m else None


def weekly(home, live=None):
    """(used percent, resets_at epoch seconds or None) of the weekly window: the figure of the token_count record
    with the greatest timestamp (a record without one counts at its file's modification time) among the 8 newest
    rollouts of `home` and of the live home (`live`, default _live_home(); read only), because the limit is
    account-wide and the replay home's own figures go stale across an idle gap. None when no record reports one.
    The weekly window is whichever of `primary` and `secondary` has window_minutes == 10080; one that reports
    used_percent without resets_at counts, with resets_at None."""
    live = _live_home() if live is None else live
    homes = [home] + ([live] if live and os.path.realpath(live) != os.path.realpath(home) else [])
    best, best_key = None, None
    for h in homes:
        for path in _rollouts(h)[:WEEKLY_SCAN]:
            try:
                lines, mtime = _lines(path), os.path.getmtime(path)
            except (OSError, subprocess.SubprocessError):
                continue            # a live rollout may move or vanish while it is read
            for n, line in enumerate(lines):
                if b'"rate_limits"' not in line:
                    continue
                try:
                    rec = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                p = rec.get("payload") if isinstance(rec, dict) and rec.get("type") == "event_msg" else None
                limits = p.get("rate_limits") if isinstance(p, dict) and p.get("type") == "token_count" else None
                for key in ("primary", "secondary"):
                    w = limits.get(key) if isinstance(limits, dict) else None
                    if not (isinstance(w, dict) and w.get("window_minutes") == WEEKLY_MINUTES
                            and isinstance(w.get("used_percent"), (int, float))):
                        continue
                    stamp = _epoch(rec.get("timestamp"))
                    rank = (mtime if stamp is None else stamp, n)
                    if best_key is None or rank >= best_key:
                        resets = w.get("resets_at")
                        best = (float(w["used_percent"]), int(resets) if isinstance(resets, (int, float)) else None)
                        best_key = rank
    return best


def weekly_hold(home, live=None):
    """{paused: text, resets_at} when the weekly window (see weekly) is at WEEKLY_PAUSE percent or more and has not reset, else None:
    nothing more is to be started, and the text says when it may be. A reset time that is not known holds too."""
    wk = weekly(home, live)
    if wk and wk[0] >= WEEKLY_PAUSE and (wk[1] is None or wk[1] > time.time()):
        when = "unknown" if wk[1] is None else "{} ({})".format(wk[1], time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(wk[1])))
        return {"paused": "the weekly window is at {:g}%, resets_at {}".format(wk[0], when), "resets_at": wk[1]}
    return None


# ------------------------------------------------------------------ the leak scan
# A tool call is reduced to the path-like tokens it names; each is resolved the way the system would (from the call's directory,
# ~ and known variables expanded, ./.. collapsed, symlinks followed) and judged by containment in a forbidden root, component by
# component, unless it resolves inside one of the reviewer's allowed subtrees. See the module docstring.

# Checkouts a tool reads without naming them: a checkout named <key> directly in the XDG data home is read by running these words.
TOOLS = {"chezmoi": ("chezmoi",)}
# chezmoi v2.74.0's persistent flags (`chezmoi help`), which may stand before or after the subcommand: those that take a value, and those that do not.
CHEZMOI_VALUED = ("--age-recipient", "--age-recipient-file", "--cache", "--color", "-c", "--config", "--config-format", "-D", "--destination", "--mode",
                  "-o", "--output", "--override-data", "--override-data-file", "--persistent-state", "--progress", "-S", "--source", "--use-builtin-age",
                  "--use-builtin-git", "-W", "--working-tree")
CHEZMOI_FLAGS = ("--debug", "-n", "--dry-run", "--error-on-conflict", "--force", "--interactive", "-k", "--keep-going", "--less-interactive", "--no-pager",
                 "--no-tty", "-R", "--refresh-externals", "--skip-secrets", "--source-path", "--use-builtin-diff", "-v", "--verbose")
# A word that an unknown option, if it takes a value, would swallow: a long source or destination flag, --version, or a short cluster that holds
# an S or a D (-S, -vS, -nD, -vS=x: pflag hands the cluster whole to the unknown option).
CHEZMOI_SWALLOWED = ("--source", "--destination", "--version")
_SHORT_SD = re.compile(r"-[^-]*[SD]")
SHELLS = ("sh", "bash", "zsh", "dash")
KEYWORDS = ("if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done", "esac")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
WITH_ARG = {"sudo": ("-u", "-g", "-C", "-D", "-h", "-p", "-R", "-r", "-t", "-T", "-U"), "env": ("-u", "-C", "-S"),
            "xargs": ("-I", "-J", "-L", "-n", "-P", "-s", "-d", "-E", "-a"), "timeout": ("-s", "-k"), "nice": ("-n",),
            "stdbuf": (), "ionice": ("-c", "-n", "-p")}
DECLARES = ("export", "declare", "local", "typeset", "readonly")     # builtins whose arguments are assignments
WRAPPERS = ("exec", "time", "nohup", "stdbuf", "ionice", "setsid", "builtin", "noglob", "nocorrect")
SEPARATORS = ("&&", "||", ";", "|", "|&", ";;", "&", "(", ")", "$")
REDIRECTS = (">", ">>", "<", "<<", "<<<", ">&", "<&", "&>", "&>>", ">|", "<>")    # operators shlex gives; each takes the next word
FD_MARK = "\x01"       # _logical's mark on an fd number glued to < or > (2>x), which shlex would part from it like a spaced word
OP_MARK = "\x02"       # _logical's mark on a quoted or escaped operator character ('|', \;): the word it is in never reads as an operator
_OPERATOR_CHARS = frozenset("".join(SEPARATORS + REDIRECTS))
# Searches whose first operand is a pattern, not a path: the short option letters and the long options that take a separate value.
# rg, ag and ack are recursive; grep only with -r, -R or -d recurse; git grep searches its repository, not a root it is given.
GREPS = {"grep": ("efmABCDd", ("regexp", "file", "max-count", "after-context", "before-context", "context", "devices", "directories",
                               "include", "exclude", "exclude-dir", "exclude-from", "label", "binary-files"), ("e", "regexp"), ()),
         "rg": ("efgtTmABCjMErd", ("regexp", "file", "glob", "iglob", "type", "type-not", "type-add", "type-clear", "max-count",
                                   "after-context", "before-context", "context", "threads", "max-columns", "encoding", "replace",
                                   "max-depth", "max-filesize", "path-separator", "pre", "pre-glob", "sort", "sortr", "colors",
                                   "context-separator", "field-context-separator", "field-match-separator", "ignore-file", "engine",
                                   "dfa-size-limit", "regex-size-limit", "hyperlink-format"), ("e", "regexp"), ("r", "replace")),
         "git grep": ("efABCm", ("max-depth", "threads", "context", "after-context", "before-context", "max-count"), ("e",), ()),
         "ag": ("ABCGgm", ("after", "before", "context", "file-search-regex", "max-count", "ignore", "ignore-dir", "depth", "path-to-ignore"),
                ("g",), ("G", "file-search-regex")),
         "ack": ("ABCgm", ("after-context", "before-context", "context", "max-count", "ignore-dir", "ignore-file", "type", "match"),
                 ("g", "match"), ())}
GREPS["egrep"] = GREPS["fgrep"] = GREPS["grep"]
# In each GREPS entry, after the options that take a value: those whose value is the pattern (then no operand is), and those whose
# value is other text (a replacement, a file-name filter). git log/diff's pickaxe and --grep values are patterns too (GIT_PATTERNS).
GIT_PATTERNS = (("log", "show", "whatchanged", "rev-list", "diff", "reflog"), ("-S", "-G", "--grep"))
# Other recursive walks, as GREPS: fd (its first operand is a pattern; -x/-X run a command), tree, ls (only with -R).
WALKS = {"fd": ("edtESxXcjo", ("extension", "type", "exclude", "max-depth", "min-depth", "exact-depth", "size", "color", "threads",
                               "changed-within", "changed-before", "owner", "max-results", "path-separator", "ignore-file",
                               "base-directory", "search-path", "batch-size", "exec", "exec-batch")),
         "tree": ("LPIoHT", ("filelimit", "charset", "sort", "timefmt")),
         "ls": ("", ("ignore", "hide", "width", "tabsize", "format", "sort", "color", "time", "time-style", "quoting-style",
                     "indicator-style", "block-size"))}
FIND_GLOBAL = ("-H", "-L", "-P", "-E", "-X", "-s", "-x", "-d", "-O0", "-O1", "-O2", "-O3")
GIT_WITH_ARG = ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix")
# What a replayed reviewer must not read, besides the original checkout: where October's answers live (spec 7.1), the live Codex and
# Claude homes whole (sessions, memories and their sqlite stores, histories, file-history, transcripts, and the deployed copies of the
# dotfiles), but for the instructions in them, which every reviewer is given anyway (INSTRUCTIONS), unless the original is the
# chezmoi source, whose later state they are (forbidden()). The snapshot (C.snapshot_home()) and the harness's exports (exports())
# are roots of their own, under $XDG_STATE_HOME/process-replay.
ANSWERS = ("~/.codex", "~/.claude")
INSTRUCTIONS = ("~/.codex/skills", "~/.codex/plugins", "~/.codex/rules", "~/.codex/AGENTS.md",
                "~/.claude/plugins", "~/.claude/skills", "~/.claude/agents", "~/.claude/CLAUDE.md")
OWN_HOME = ("skills", "plugins", "rules", "AGENTS.md")     # what a replay home gives its reviewer to read (finding A)
PATH_MAX = 4096
MAX_DEPTH = 4           # nested sh -c, $( ) and heredocs followed
MAX_CWDS = 4            # directories one cd may lead to (a variable with several values)
MAX_EXPANSIONS = 16
LITERAL = object()      # in a variable's values: it may also hold what the scan does not know, so its spelling stays
TOO_MANY = "{} (more values than the scan expands)"
TOO_DEEP = "{} (nested deeper than the scan follows)"
EXCERPT = 60            # characters of the command a TOO_DEEP label quotes
_PIECE = re.compile(r"[^\s\"'`;|&<>()\\:,={}]+")
_GLOB = re.compile(r"[*?\[]")
_SUBST = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
_PWD = re.compile(r"\$\(\s*pwd\s*\)|`\s*pwd\s*`")
_BACK = object()        # what `cd -` returns: the directory before the last cd
_VAR = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")

Root = collections.namedtuple("Root", "label parts siblings words")
Wall = collections.namedtuple("Wall", "roots allowed")


def _parts(path):
    return tuple(x for x in path.split("/") if x)


def _real(path):
    """An absolute path with its symlinks resolved as far as it exists; None for a string the system cannot take as a path."""
    if "\0" in path or len(path) > PATH_MAX:
        return None
    try:
        return os.path.realpath(path)
    except (OSError, ValueError):
        return None


def _values(extra=None):
    """{variable: [values]} a path may spell: $HOME, $XDG_STATE_HOME and $XDG_DATA_HOME (as the harness has them, and their
    defaults under $HOME, since a reviewer's environment may differ), and `extra` ($CODEX_HOME for a Codex reviewer)."""
    house = os.path.expanduser("~")
    out = {"HOME": [house], "XDG_STATE_HOME": [L.state_home(), os.path.join(house, ".local", "state")],
           "XDG_DATA_HOME": [os.environ.get("XDG_DATA_HOME") or "", os.path.join(house, ".local", "share")]}
    out.update(extra or {})
    return dict((k, list(dict.fromkeys(v for v in vs if v))) for k, vs in out.items())


def _tool_words(path):
    """The TOOLS words that read the checkout at `path`: a chezmoi source in ~/.local/share or $XDG_DATA_HOME."""
    if any(os.path.dirname(path) == os.path.abspath(d) for d in _values()["XDG_DATA_HOME"]):
        return TOOLS.get(os.path.basename(path), ())
    return ()


def wall(originals=(), roots=(), allowed=()):
    """The wall of one reviewer, held as real paths. `originals` are checkouts (a git directory stands for its work tree): a sibling
    <dir>-<anything> beside one is a `wt` worktree of it, and running one of its TOOLS words reads it. `roots` are the other forbidden
    directories, `allowed` the reviewer's own subtrees. A root is reported by its absolute path as given."""
    out, seen = [], set()
    for path, siblings in [(x, True) for x in originals] + [(x, False) for x in roots]:
        if not (isinstance(path, str) and path):
            continue
        label = os.path.abspath(os.path.expanduser(path))
        if siblings and os.path.basename(label) == ".git":
            label = os.path.dirname(label)
        parts = _parts(_real(label) or label)
        if parts and parts not in seen:
            seen.add(parts)
            out.append(Root(label, parts, siblings, _tool_words(label) if siblings else ()))
    mine = []
    for path in allowed:
        parts = _parts(_real(os.path.abspath(os.path.expanduser(path))) or "") if isinstance(path, str) and path else ()
        if parts and parts not in mine:
            mine.append(parts)
    return Wall(out, mine)


def own_home(home, memories=False):
    """The parts of a reviewer's own replay home it may read: what the home configures it with (OWN_HOME) and, for a §6 A/A2 arm, the
    memories under test (F-3). The rest of the home (sessions, config, auth) stays behind the cxh root."""
    return [os.path.join(home, x) for x in OWN_HOME + (("memories",) if memories else ())]


def deployed(branch):
    """Whether the branch's original is a checkout whose later state is deployed into the homes: the chezmoi source (the TOOLS key).
    ~/.codex and ~/.claude, and a replay home copied from them, then hold that repository's files as merged, fixes included."""
    checkout = os.path.abspath(os.path.expanduser(branch.get("repo") or ""))
    return bool(_tool_words(os.path.dirname(checkout) if os.path.basename(checkout) == ".git" else checkout))


def exports():
    """The harness copies a reviewer must not read: the running harness's own root, then every existing directory
    $XDG_STATE_HOME/process-replay/harness-* (sorted). The checkout is one root (a copy of this repository under the state home is another)
    because either holds the harness's code, its tests and the dotfiles' later state."""
    base = os.path.join(L.state_home(), "process-replay")
    return [C.harness_root()] + sorted(p for p in glob.glob(os.path.join(glob.escape(base), "harness-*")) if os.path.isdir(p))


def beneath(cwd, bounds):
    """The labels of the roots of `bounds` whose real path is `cwd`'s real path or lies below it (at component boundaries): the
    forbidden roots a recursive search from `cwd` would walk into. A root above `cwd`, or beside it, is not named."""
    here = _parts(_real(os.path.abspath(cwd)) or "")
    return [root.label for root in bounds.roots if root.parts[:len(here)] == here]


def forbidden(state, branch, allowed, snapshot_root=None, memwatch=None, home=None, memories=False):
    """The wall of a replayed reviewer (a Codex round, a §6 arm, or the final reviewer and its subagents; spec 7.1, 13), for leaks()
    and final.transcript_leaks(). Its roots: the original checkout (branch["repo"], with its wt siblings and the harness worktrees
    inside it), its objects and view; the state directory (by its real path, which its aliases resolve to); $XDG_STATE_HOME/
    review-work (every scratch, the staged items and the state's alias links); the snapshot home (C.snapshot_home(), and `snapshot_root`
    when given); every harness export and the running harness's own root (exports()); the live Codex and Claude homes, where October's
    answers live (ANSWERS); $XDG_STATE_HOME/xreview; $XDG_STATE_HOME/cxh
    (the replay homes, whose rollouts are other runs' work); and for a §6 run (`memwatch`: the watcher's directory, or True for the usual one) $XDG_STATE_HOME/process-replay/memwatch.
    `allowed` are the reviewer's own subtrees: its scratch, and for a final reviewer its staged item, its own transcripts and its
    session's tool-results/. A Codex reviewer passes its replay `home`: own_home(home, `memories`) is allowed too (`memories`: a §6
    A/A2 arm). Every reviewer may also read INSTRUCTIONS. When the original is the chezmoi source (deployed()), the instructions in
    ~/.codex and ~/.claude and the home's copies of them are that repository's later state: neither is allowed, an arm's memories are."""
    state_home = L.state_home()
    roots = [p for p in (branch.get("objects"), branch.get("view"), state) if isinstance(p, str) and p]
    roots += [os.path.join(state_home, "review-work"), C.snapshot_home()] + ([snapshot_root] if snapshot_root else [])
    roots += exports() + list(ANSWERS) + [os.path.join(state_home, "xreview"), os.path.join(state_home, "cxh")]
    if memwatch:
        roots.append(os.path.join(state_home, "process-replay", "memwatch"))
        if isinstance(memwatch, str):
            roots.append(memwatch)
    allowed = list(allowed)
    if not deployed(branch):
        allowed += list(INSTRUCTIONS) + (own_home(home, memories) if home else [])
    elif home and memories:
        allowed.append(os.path.join(home, "memories"))
    return wall([branch.get("repo")], roots, allowed)


def _matches(want, pattern):
    """Whether glob `pattern` matches the name `want`; a pattern that is no valid glob ([z-a]) is the literal text the shell takes it for."""
    try:
        return fnmatch.fnmatchcase(want, pattern)
    except re.error:
        return False


def _can(name, want):
    """Whether a path component can name `want`: the same name, or a glob that matches it."""
    return name == want or (_GLOB.search(name) is not None and _matches(want, name))


def _sibling(name, want):
    """Whether a component names a wt sibling <want>-<branch>, literally or by a glob that can (approximately: it matches <want>-x, or
    its text before the first glob character starts <want>-)."""
    if name.startswith(want + "-"):
        return True
    return _GLOB.search(name) is not None and (_matches(want + "-x", name) or _GLOB.split(name, 1)[0].startswith(want + "-"))


def _within(parts, root):
    n = len(root.parts)
    if len(parts) < n or not all(_can(p, r) for p, r in zip(parts[:n - 1], root.parts)):
        return False
    return _can(parts[n - 1], root.parts[-1]) or (root.siblings and _sibling(parts[n - 1], root.parts[-1]))


def judge(parts, bounds):
    """The label of the forbidden root of `bounds` that a real path (its components) lies in, or None when it lies in none or inside an
    allowed subtree. An allowed subtree holds a path only literally: a glob component in it may name a neighbour."""
    if any(parts[:len(a)] == a for a in bounds.allowed):
        return None
    return next((root.label for root in bounds.roots if _within(parts, root)), None)


def _tilde(token, values):
    """`token` with a leading ~ or ~/ spelled ${HOME}, so that it takes every value $HOME has (one that `values` lacks: the user's home);
    ~user is that user's home."""
    if not token.startswith("~"):
        return token
    if "HOME" in values and re.match(r"~(/|\Z)", token):
        return "${HOME}" + token[1:]
    return os.path.expanduser(token)


def _expand(token, values):
    """(results, complete): `token` with a leading ~ and the variables of `values` expanded, one result per value; an unknown variable
    stays as written, and so does one whose values hold LITERAL. complete is False when expanding would exceed MAX_EXPANSIONS."""
    token = _PWD.sub("${PWD}", token)
    todo, done = [(_tilde(token, values), 0)], []
    while todo and len(done) + len(todo) <= MAX_EXPANSIONS:
        t, at = todo.pop()
        m = next((m for m in _VAR.finditer(t, at) if (m.group(1) or m.group(2)) in values), None)
        if m is None:
            done.append(t)
        else:
            todo += [(t, m.end()) if v is LITERAL else (t[:m.start()] + v + t[m.end():], m.start()) for v in values[m.group(1) or m.group(2)]]
    return done + [t for t, _at in todo], not todo


def _pieces(word):
    """The path-like pieces of a word: the word, what lies between spaces, quotes, shell punctuation and : , = { }, and a short option's
    glued value (-C../x)."""
    tokens = _PIECE.findall(word)
    return list(dict.fromkeys([word] + tokens + [t[2:] for t in tokens if re.match(r"-[A-Za-z].", t)]))


def _logical(command, bodies=None):
    """`command` as one line: unquoted newlines become `;` (a backslash-newline is a continuation), an unquoted
    comment (a # that starts a word, to the end of its line) and heredoc bodies are dropped (appended to `bodies` when it is a list, as (text, whether the delimiter was quoted)),
    and a backtick substitution becomes $( ... ) (glued to the text before it, as T=~/`date` is T=~/$(date)), so every command sits at a command position. A here-string (<<<) is not a heredoc.
    An unquoted ( or ) stands apart, so shlex never groups it with an operator beside it (as in `);`, `))` or `;(`); a quoted one stays in its word.
    A word of digits glued to < or > (2>x, 1<x) is an fd: it is marked with FD_MARK, so that once tokenised it still differs from a
    number standing on its own before a redirection (-C 2 >x). A quoted run of operator characters ('|', ";;") and an escaped one (\;)
    are marked with OP_MARK, which shlex keeps but would otherwise lose with the quote, so _tokens can tell them from operators."""
    out, quote, i, backtick, opened = [], None, 0, False, 0
    n = len(command)
    while i < n:
        ch = command[i]
        if quote:
            if ch == quote:
                body = command[opened:i].replace("\\", "")
                if body and set(body) <= _OPERATOR_CHARS:
                    out.append(OP_MARK)
                quote = None
            out.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < n:
                out.append(command[i + 1])
                i += 1
        elif ch == "\\" and i + 1 < n:
            if command[i + 1] == "\n":
                i += 1
            else:
                out.append(ch + command[i + 1] + (OP_MARK if command[i + 1] in _OPERATOR_CHARS else ""))
                i += 1
        elif ch in "'\"":
            quote, opened = ch, i + 1
            out.append(ch)
        elif ch == "#" and (not out or out[-1][-1:] in (" ", "\t", "\n", ";", "&", "|", "(")):
            while i < n and command[i] != "\n":
                i += 1
            continue
        elif ch.isdigit() and (not out or out[-1][-1:] in (" ", "\t", "\n", ";", "&", "|", "(")):
            j = i
            while j < n and command[j].isdigit():
                j += 1
            out.append(command[i:j] + (FD_MARK if j < n and command[j] in "<>" else ""))
            i = j
            continue
        elif ch == "`":
            out.append(" ) " if backtick else ("$(" if out and out[-1][-1:] not in " \t\n;&|()<>" else " $( "))
            backtick = not backtick
        elif ch in "()":
            out.append(" " + ch + " ")
        elif ch == "\n":
            line = "".join(out)
            out.append(" ; ")
            m = re.search(r"(?<!<)<<-?(?!<)\s*(['\"]?)([A-Za-z0-9_]+)\1", line.rsplit(" ; ", 1)[-1])
            if m:
                end = re.compile(r"^\s*" + re.escape(m.group(2)) + r"\s*$", re.M)
                found = end.search(command, i + 1)
                if isinstance(bodies, list):
                    bodies.append((command[i + 1:found.start() if found else n], bool(m.group(1))))
                i = found.end() if found else n
                continue
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def _tokens(line):
    """The shell words and operators of a _logical() line, quotes removed. A word with a quoted or escaped operator character loses
    its OP_MARK, unless the _word rule keeps it because the word reads as an operator. _logical has dropped the comments, so a #
    left in a word is text (shlex would end the line there)."""
    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        toks = list(lexer)
    except ValueError:
        toks = line.split()
    return [_word(t.replace(OP_MARK, "")) if OP_MARK in t else t for t in toks]


def _word(text):
    """`text` taken as a word: one that reads as an operator (SEPARATORS, REDIRECTS) carries OP_MARK, so it never splits a command."""
    return text + OP_MARK if text in SEPARATORS + REDIRECTS else text


def _excerpt(command):
    """The start of a command (a string, or an argv list) on one line, at most EXCERPT characters ("..." marks a cut), without OP_MARK and FD_MARK."""
    text = " ".join((command if isinstance(command, str) else " ".join(str(x) for x in command)).replace(OP_MARK, "").replace(FD_MARK, "").split())
    return text if len(text) <= EXCERPT else text[:EXCERPT] + "..."


def _skip(words, base):
    """words[1:] without the options of a wrapper command and their arguments."""
    i = 1
    while i < len(words) and words[i].startswith("-") and words[i] != "--":
        i += 2 if words[i] in WITH_ARG.get(base, ()) else 1
    return words[i + 1:] if i < len(words) and words[i] == "--" else words[i:]


def _effective(words):
    """The words of the command a simple command ends up running (a suffix of `words`), looking through shell keywords, assignments
    and wrappers (env, sudo, command, xargs, timeout, nice, mise exec --, ...); [] for `command -v/-V`, which only finds a binary
    (which, type and hash are commands of their own, so what they look up is an argument)."""
    while words:
        base = os.path.basename(words[0])
        if words[0] in KEYWORDS or ASSIGNMENT.match(words[0]):
            words = words[1:]
        elif base == "command":
            if any(re.match(r"-[a-zA-Z]*[vV]", w) for w in words[1:2]):
                return []
            words = _skip(words, base)
        elif base == "env":
            i = 1
            while i < len(words) and (words[i].startswith("-") or ASSIGNMENT.match(words[i])):
                i += 2 if words[i] in WITH_ARG["env"] else 1
            words = words[i:]
        elif base == "timeout":
            rest = _skip(words, base)
            words = rest[1:]                       # the duration
        elif base == "nice":
            words = [w for w in _skip(words, base)] if not (len(words) > 1 and re.match(r"-\d+\Z", words[1])) else words[2:]
        elif base == "mise" and len(words) > 1 and words[1] in ("exec", "x"):
            words = words[words.index("--") + 1:] if "--" in words else []
        elif base in WITH_ARG or base in WRAPPERS:
            words = _skip(words, base)
        else:
            return words
    return []


def _parse(eff, short, longs, i=1):
    """(operand indices, options) of a command line from eff[i]: options as (name, value, index of the word holding the value); a
    letter of `short` or a name of `longs` takes a value, glued (-C3, --context=3) or the next word; `--` ends the options."""
    operands, options = [], []
    while i < len(eff):
        w = eff[i]
        if w == "--":
            operands += range(i + 1, len(eff))
            break
        if w.startswith("--"):
            name, eq, value = w[2:].partition("=")
            at = i if eq else None
            if not eq and name in longs and i + 1 < len(eff):
                value, at, i = eff[i + 1], i + 1, i + 1
            options.append((name, value, at))
        elif w.startswith("-") and w != "-":
            for j in range(1, len(w)):
                if w[j] not in short:
                    options.append((w[j], None, None))
                    continue
                value, at = w[j + 1:], i
                if not value and i + 1 < len(eff):
                    value, at, i = eff[i + 1], i + 1, i + 1
                options.append((w[j], value, at))
                break
        else:
            operands.append(i)
        i += 1
    return operands, options


def _substitutions(word):
    """The commands of the $( ) and backtick substitutions inside a word."""
    return [a or b for a, b in _SUBST.findall(word)]


def _plain(eff):
    """The indices of `eff` that are not redirections: an operator of REDIRECTS (with the fd number _logical marked glued to it) and its
    target."""
    keep, i = [], 0
    while i < len(eff):
        if eff[i] in REDIRECTS:
            i += 2
        elif eff[i].endswith(FD_MARK) and eff[i][:-1].isdigit() and i + 1 < len(eff) and eff[i + 1] in REDIRECTS:
            i += 3
        else:
            keep.append(i)
            i += 1
    return keep


def _swallowed(word):
    """Whether `word` is a flag an unknown option that takes a value would hide: see CHEZMOI_SWALLOWED."""
    return word.startswith(CHEZMOI_SWALLOWED) or _SHORT_SD.match(word) is not None


def _chezmoi(plain):
    """What a chezmoi call (`plain`: its effective words, redirections dropped) reads, as (kind, roots). `none`: --version before any operand, or
    the subcommand help, which read nothing. `original`: no -S/--source anywhere (-Sx, -S=x and --source=x too), so it reads the checkout it
    finds: the original; also a source flag with no value, and an unknown option followed by a source, destination or --version flag, or a short
    cluster holding an S or a D (-vS, -nD), which the option may take as its value (pflag gives a value-taking flag the next word, whatever it
    starts with, and hands a cluster to it whole). `paths`: the call names its
    source, so `roots` are every source value and the destination (the last -D/--destination, else ~), each read as a search root, because
    chezmoi walks them. No subcommand is exempt from the destination: with a .chezmoiremove in the source, managed and source-path read it
    too (R3, t_codex.py real_chezmoi_source_only)."""
    sources, dests, sub, unknown, ended, i = [], [], None, False, False, 1
    while i < len(plain):
        word = plain[i]
        i += 1
        if ended or not word.startswith("-") or word == "-":
            sub = word if sub is None else sub
        elif word == "--":
            ended = True
        elif word == "--version" and sub is None and not unknown:
            return "none", []
        elif word.startswith("--"):
            name, eq, value = word.partition("=")
            if name in CHEZMOI_VALUED:
                if not eq:
                    value, i = plain[i] if i < len(plain) else None, i + 1
            elif name not in CHEZMOI_FLAGS:
                if not eq and i < len(plain) and _swallowed(plain[i]):
                    return "original", []
                unknown = unknown or sub is None
                continue
            (sources if name == "--source" else dests if name == "--destination" else []).append(value)
        else:
            for j in range(1, len(word)):
                flag = "-" + word[j]
                if flag in CHEZMOI_VALUED:
                    rest = word[j + 1:]
                    value = rest[1:] if rest[:1] == "=" else rest
                    if not rest:
                        value, i = plain[i] if i < len(plain) else None, i + 1
                    (sources if flag == "-S" else dests if flag == "-D" else []).append(value)
                    break
                if flag not in CHEZMOI_FLAGS:
                    rest = word[j + 1:]
                    if "S" in rest or "D" in rest or (not rest and i < len(plain) and _swallowed(plain[i])):
                        return "original", []
                    unknown = unknown or sub is None
                    break
    if sub == "help" and not unknown:
        return "none", []
    if not sources or not all(sources):
        return "original", []
    return "paths", sources + [dests[-1] if dests and dests[-1] else "~"]


def _grep(eff):
    """(pattern indices, path operand indices, recursive) of a search in `eff` (a simple command's effective words, redirections
    dropped) that takes a pattern: grep, rg, ag, ack or git grep; None for any other command. Its first operand is the pattern, unless
    an option gives the patterns (-e/--regexp; ag and ack -g, ack --match) or -f/--file a file of them (rg --files takes none): then
    every operand is a path. The value of a text option (rg --replace, ag -G) is not a path either."""
    if not eff:
        return None
    base, i = os.path.basename(eff[0]), 1
    if base == "git":
        while i < len(eff) and eff[i].startswith("-"):
            i += 2 if eff[i] in GIT_WITH_ARG else 1
        if i >= len(eff) or eff[i] != "grep":
            return None
        base, i = "git grep", i + 1
    if base not in GREPS:
        return None
    short, longs, gives, texts = GREPS[base]
    operands, options = _parse(eff, short, longs + ("regexp", "file"), i)
    patterns = set(at for name, _v, at in options if name in gives + texts and at is not None)
    given = any(name in gives + ("f", "file", "files", "type-list") for name, _v, _a in options)
    if operands and not given:
        patterns.add(operands.pop(0))
    recursive = base in ("rg", "ag", "ack") or any(
        name in ("r", "R", "recursive", "dereference-recursive") or (name in ("d", "directories") and value == "recurse")
        for name, value, _a in options if base != "git grep")
    return patterns, operands, recursive


def _git_patterns(eff):
    """The indices of the values of git log's (show, diff, ...) -S, -G and --grep in `eff`: patterns, not paths."""
    i = 1
    while i < len(eff) and eff[i].startswith("-"):
        i += 2 if eff[i] in GIT_WITH_ARG else 1
    if not (eff and os.path.basename(eff[0]) == "git" and i < len(eff) and eff[i] in GIT_PATTERNS[0]):
        return set()
    out = set()
    for j in range(i + 1, len(eff)):
        w = eff[j]
        if w in GIT_PATTERNS[1]:
            out.add(j + 1)
        elif w.startswith("--grep=") or (w[:2] in ("-S", "-G") and len(w) > 2):
            out.add(j)
    return set(j for j in out if j < len(eff))


def _patterns(eff):
    """The indices in `eff` (redirections dropped) of the words that are search patterns or other text, which name no path read."""
    found = _grep(eff)
    return found[0] if found else _git_patterns(eff)


def _searched(eff, piped):
    """The roots a recursive search in `eff` walks, as words ("." for the working directory): rg, ag, ack, grep -r/-R, find, fd, tree and
    ls -R. One that names no root walks the working directory, but rg, ag, ack and grep in a pipe read their input instead."""
    found = _grep(eff)
    if found:
        _patterns, operands, recursive = found
        return ([eff[i] for i in operands] or ([] if piped else ["."])) if recursive else []
    base = os.path.basename(eff[0]) if eff else ""
    if base == "find":
        i = 1
        while i < len(eff) and eff[i] in FIND_GLOBAL:
            i += 1
        roots = []
        while i < len(eff) and not (eff[i].startswith("-") or eff[i] in ("!", "(" + OP_MARK)):
            roots.append(eff[i])
            i += 1
        return roots or ["."]
    if base not in WALKS:
        return []
    words = eff
    if base == "fd":
        cut = [k for k, w in enumerate(eff) if k and w in ("-x", "-X", "--exec", "--exec-batch")]
        words = eff[:cut[0] + 2] if cut else eff
    operands, options = _parse(words, *WALKS[base])
    if base == "ls" and not any(name in ("R", "recursive") for name, _v, _a in options):
        return []
    roots = [words[i] for i in (operands[1:] if base == "fd" else operands)]
    roots += [value for name, value, _a in options if name in ("search-path", "base-directory") and value]
    return roots or ["."]


class _Scan(object):
    """What one tool call names behind `bounds` (a Wall): the labels of the roots its paths fall in, in `found`."""

    def __init__(self, bounds, values):
        self.bounds, self.found, self._seen = bounds, set(), {}
        self.values = dict((k, list(v)) for k, v in values.items())

    def assign(self, words, end=None):
        """The literal assignments among `words[:end]` (NAME=value, no $ or backtick in the value once its quotes are removed): each adds its value to the variable for what the call does next, never
        removes one. A variable the scan knows keeps its values; an unknown one also keeps its spelling (LITERAL). A leading ~ in the
        value is every home $HOME has so far."""
        for w in words[:end]:
            m = ASSIGNMENT.match(w)
            if not m or "$" in w[m.end():] or "`" in w[m.end():]:
                continue
            name, value = w[:m.end() - 1], w[m.end():]
            if name not in self.values:
                self.values[name] = [] if name == "PWD" else [LITERAL]
            homes = [h for h in self.values.get("HOME", []) if h is not LITERAL]
            for v in [h + value[1:] for h in homes] if homes and re.match(r"~(/|\Z)", value) else [os.path.expanduser(value)]:
                if v not in self.values[name]:
                    self.values[name].append(v)

    def variables(self, cwds):
        """The variables a path may spell from `cwds`: $PWD is the directories the cd tracker holds, and any value assigned to it."""
        return dict(self.values, PWD=list(dict.fromkeys(list(cwds) + self.values.get("PWD", []))))

    def resolved(self, token, cwds):
        """The real paths (as components) a path-like token names from each directory of `cwds`: expanded, joined, then read both ways,
        ./.. collapsed first (as cd and most tools spell it) and symlinks first (as the system opens it)."""
        out = set()
        if not token or "\0" in token or len(token) > PATH_MAX:
            return out
        expanded, whole = _expand(token, self.variables(cwds))
        if not whole:
            self.found.add(TOO_MANY.format(token))
        for t in expanded:
            for joined in ([t] if t.startswith("/") else [c + "/" + t for c in cwds]):
                for p in (os.path.normpath(joined), joined):
                    if p not in self._seen:
                        real = _real(p)
                        self._seen[p] = _parts(real) if real else None
                    if self._seen[p] is not None:
                        out.add(self._seen[p])
        return out

    def path(self, token, cwds):
        for parts in self.resolved(token, cwds):
            label = judge(parts, self.bounds)
            if label:
                self.found.add(label)

    def search(self, token, cwds):
        """A recursive search's root: judged as a path, and every forbidden root beneath it (one it is an ancestor of) counts as read."""
        self.path(token, cwds)
        for parts in self.resolved(token, cwds):
            for root in self.bounds.roots:
                if len(parts) < len(root.parts) and all(_can(p, r) for p, r in zip(parts, root.parts)):
                    self.found.add(root.label)

    def unexpanded(self, token, cwds):
        """Whether `token` still holds a $ or a backtick once the variables the scan knows by value are expanded: a path it cannot name."""
        known = dict((k, [v for v in vs if v is not LITERAL]) for k, vs in self.variables(cwds).items())
        return any("$" in t or "`" in t for t in _expand(token, dict((k, vs) for k, vs in known.items() if vs))[0])

    def dirs(self, target, cwds):
        """The directories `cd target` leads to from `cwds` (logical: ./.. collapsed as cd does)."""
        out = []
        expanded, whole = _expand(target, self.variables(cwds))
        for t in expanded:
            out += [os.path.normpath(j) for j in ([t] if t.startswith("/") else [c + "/" + t for c in cwds])]
        out = list(dict.fromkeys(out))
        if not whole or len(out) > MAX_CWDS:
            self.found.add(TOO_MANY.format(target))
        return out[:MAX_CWDS]

    def text(self, text, cwds):
        """Free text (a call's other arguments, the JavaScript around its commands): every piece of every word is a path-like token."""
        for word in text.split():
            for piece in _pieces(word):
                self.path(piece, cwds)

    def word(self, word, cwds, depth, running=True):
        """A word's pieces, and the commands of its substitutions ("$(cat x)" or `cat x` in a quoted word; $(pwd) is $PWD)."""
        word = _PWD.sub("${PWD}", word)
        for inner in _substitutions(word):
            self.script(inner, cwds, depth + 1, running)
        for piece in _pieces(_SUBST.sub(" ", word)):
            self.path(piece, cwds)

    def simple(self, words, cwds, depth, piped=False, running=True):
        """One simple command (`piped`: it reads a pipe): every word but a search pattern, the script of sh -c, and the roots of a
        recursive search, from `cwds`; the directories it leaves the cd tracker in. When `running`, a command that is a TOOLS word of a root
        (chezmoi) reads that root unless its paths say otherwise (_chezmoi): `original` adds the root's label, `paths` makes each path a search
        root. A heredoc body is not `running`: its paths are read and its commands are not run."""
        eff = _effective(words)
        at = len(words) - len(eff)
        self.assign(words, at)
        if eff and os.path.basename(eff[0]) in DECLARES:
            self.assign(eff[1:])
        keep = _plain(eff)
        plain = [eff[k] for k in keep]
        skip = set(at + keep[i] for i in _patterns(plain))
        base = os.path.basename(eff[0]) if eff else ""
        if base in SHELLS:
            for j in range(1, len(eff) - 1):
                if re.match(r"-[a-z]*c[a-z]*\Z", eff[j]):
                    self.script(eff[j + 1], cwds, depth + 1, running)
                    skip.add(at + j + 1)
                    break
        for i, w in enumerate(words):
            if i not in skip:
                self.word(w, cwds, depth, running)
            else:                                   # a pattern names no path, but the shell still runs its substitutions
                for inner in _substitutions(w):
                    self.script(inner, cwds, depth + 1, running)
        for root in _searched(plain, piped):
            self.search(root, cwds)
        tool = os.path.basename(plain[0].split("$(", 1)[0]) if running and plain else ""        # chezmoi$(true) is chezmoi, x$(...) chezmoi is not
        if tool and any(tool in root.words for root in self.bounds.roots):
            kind, named_roots = _chezmoi(plain)
            if kind == "paths" and any(self.unexpanded(token, cwds) for token in named_roots):
                kind = "original"
            self.found.update(root.label for root in self.bounds.roots if kind == "original" and tool in root.words)
            for token in named_roots:
                self.search(token, cwds)
        if base not in ("cd", "pushd"):
            return cwds
        args = [w for w in plain[1:] if w == "-" or not w.startswith("-")]
        if not args:
            return self.dirs("~", cwds)
        return _BACK if args[0] == "-" else (self.dirs(args[0], cwds) or cwds)

    def script(self, command, cwds, depth=0, running=True):
        """A shell command (a string, or an argv list): its simple commands left to right, each from the directories a cd tracker holds
        (cd X &&, ;, ||, |, newlines; cd - goes back; a subshell's cd ends with it), an unquoted $( ) or backtick substitution as a
        command of its own that leaves one word in its place (an unclosed one runs to the end), then its heredoc bodies from every
        directory it visited, as text (not `running`). `running` passes down into sh -c and $( ). A command nested deeper than MAX_DEPTH is not
        followed: it is a leak (TOO_DEEP)."""
        if depth > MAX_DEPTH:
            self.found.add(TOO_DEEP.format(_excerpt(command)))
            return
        if isinstance(command, (list, tuple)):
            self.simple([_word(str(x)) for x in command], cwds, depth, running=running)   # a lone cd (or cd -) moves nothing after it
            return
        if not isinstance(command, str):
            return
        bodies, stack, simple, before = [], [], [], None
        cur = prev = list(cwds)
        visited = [tuple(cur)]
        toks = _tokens(_logical(command, bodies)) + [";"]
        i = 0
        while i < len(toks):
            tok = toks[i]
            i += 1
            if tok.endswith("$") and i < len(toks) and toks[i] == "(":
                j, level = i + 1, 1
                while j < len(toks) - 1 and level:         # never the closing ; that ends the last simple command
                    level += {"(": 1, ")": -1}.get(toks[j], 0)
                    j += 1
                inner = " ".join(t if t in SEPARATORS + REDIRECTS else shlex.quote(t) for t in toks[i + 1:j - 1 if not level else j])
                self.script(inner, cur, depth + 1, running)
                simple.append(tok[:-1] + "$(" + inner + ")")
                i = j
                continue
            if tok not in SEPARATORS:
                simple.append(tok)
                continue
            if simple:
                new = self.simple(simple, cur, depth, piped=before in ("|", "|&"), running=running)
                if new is _BACK:
                    cur, prev = prev, cur
                elif new is not cur:
                    cur, prev = new, cur
                visited.append(tuple(cur))
                simple = []
            before = tok
            if tok == "(":
                stack.append((cur, prev))
            elif tok == ")" and stack:
                cur, prev = stack.pop()
        for body, quoted in bodies:
            for where in dict.fromkeys(visited):
                self.script(body, list(where), depth + 1, False)
                if not quoted:                      # the shell expands an unquoted body: its $( ) and backticks run
                    for inner in _substitutions(body):
                        self.script(inner, list(where), depth + 1, running)


def named(bounds, cwd, commands=(), texts=(), paths=(), values=None, searches=()):
    """The labels of the forbidden roots of `bounds` that one tool call names: `commands` are its shell commands (strings or argv lists),
    `texts` its other free text, `paths` its path fields, `searches` the roots of the recursive searches it makes (_Scan.search), relative
    ones starting at `cwd` (absolute, else none is resolved); `values` adds variables (_values). Running a root's TOOLS word as a
    command counts as reading that root, unless its paths say otherwise (_chezmoi)."""
    scan = _Scan(bounds, _values(values))
    cwds = [cwd] if isinstance(cwd, str) and cwd.startswith("/") else []
    for command in commands:
        scan.script(command, cwds)
    for text in texts:
        scan.text(text, cwds)
    for path in paths:
        scan.path(path, cwds)
    for root in searches:
        scan.search(root, cwds)
    return scan.found


_STRING = r"""("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"""
_WORKDIR = re.compile(r"""["']?workdir["']?\s*:\s*""" + _STRING)
_CMD = re.compile(r"""["']?cmd["']?\s*:\s*""" + _STRING)


def _js_string(literal):
    if literal.startswith('"'):
        try:
            return json.loads(literal)
        except ValueError:
            pass
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), literal[1:-1])


def _from(cwd, given):
    return given if os.path.isabs(given) or not cwd else os.path.join(cwd, given)


def _strings(value):
    """Every string inside a JSON value."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [s for v in value.values() for s in _strings(v)]
    if isinstance(value, list):
        return [s for v in value for s in _strings(v)]
    return []


def _calls(p, cwd):
    """[(workdir, commands, texts, paths)] of one Codex tool-call payload, as named() takes them: the directory its relative paths start
    from (the call's own workdir when it names one, which is a path it names too, else `cwd`), its shell commands, its other text. A
    function_call carries JSON arguments {cmd, workdir, ...} (arguments that are not JSON are read as a command); a local_shell_call an
    action {command, working_directory}; a custom_tool_call free text (a patch), or Codex `exec` JavaScript calling
    tools.exec_command({cmd: "...", workdir: "..."}), perhaps several times, each with its own workdir."""
    kind = p.get("type")
    if kind == "custom_tool_call":
        if not isinstance(p.get("input"), str):
            return [(cwd, [], _strings(p.get("input")), [])]
        out = []
        for part in re.split(r"(?=exec_command\s*\()", p["input"]):
            wd, given = cwd, []
            m = _WORKDIR.search(part)
            if m and _js_string(m.group(1)):
                wd = _from(cwd, _js_string(m.group(1)))
                given = [wd]
            out.append((wd, [_js_string(x) for x in _CMD.findall(part)], [_CMD.sub(" ", _WORKDIR.sub(" ", part))], given))
        return out
    if kind == "local_shell_call":
        act = p.get("action") if isinstance(p.get("action"), dict) else {}
        given = act.get("working_directory") if isinstance(act.get("working_directory"), str) and act.get("working_directory") else None
        wd = _from(cwd, given) if given else cwd
        rest = dict((k, v) for k, v in act.items() if k not in ("type", "command", "working_directory"))
        return [(wd, [act["command"]] if isinstance(act.get("command"), (str, list)) else [], _strings(rest), [wd] if given else [])]
    args = p.get("arguments")
    try:
        doc = json.loads(args) if isinstance(args, str) else args
    except ValueError:
        return [(cwd, [args], [], [])]
    if not isinstance(doc, dict):
        return [(cwd, [], _strings(doc), [])]
    given = doc.get("workdir") or doc.get("cwd")
    given = given if isinstance(given, str) and given else None
    wd = _from(cwd, given) if given else cwd
    rest = dict((k, v) for k, v in doc.items() if k not in ("cmd", "command", "workdir", "cwd"))
    return [(wd, [doc[k] for k in ("cmd", "command") if isinstance(doc.get(k), (str, list))], _strings(rest), [wd] if given else [])]


def leaks(home, turns, bounds, cwd=None):
    """The tool calls of `turns` ([(thread, turn)]) in `home`'s rollouts that name a path `bounds` forbids (forbidden(), or wall()):
    ["<root> in <turn>"]. `cwd`, the scratch repository, is where a relative path of a call without its own workdir starts, and
    $CODEX_HOME is `home`. Only the reviewer's own calls (custom_tool_call, function_call, local_shell_call) are read, never a user or
    developer message, which may carry the paths legitimately. A scanned turn whose rollout is missing, unreadable or does not hold the
    turn counts as a leak ("rollout unreadable in <turn>"): it cannot be shown clean."""
    wanted = {}
    for thread, turn in turns:
        wanted.setdefault(thread, set()).add(turn)
    found = set()
    with homed(home):
        for thread, ours in wanted.items():
            path = XR.rollout_path(thread)
            try:
                lines = _lines(path) if path is not None else []
            except (OSError, subprocess.SubprocessError):          # unreadable, or zstd timed out: not shown clean
                lines = []
            seen = set()
            inside = False
            for line in lines:
                call = any(m in line for m in CALLS)
                if not call and b'"task_started"' not in line and b'"task_complete"' not in line:
                    continue
                try:
                    rec = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                p = rec.get("payload") if isinstance(rec, dict) and isinstance(rec.get("payload"), dict) else {}
                if rec.get("type") == "event_msg" and p.get("type") == "task_started":
                    inside = p.get("turn_id") in ours
                    turn = p.get("turn_id")
                    seen.add(turn)
                elif rec.get("type") == "event_msg" and p.get("type") == "task_complete":
                    inside = False
                elif inside and rec.get("type") == "response_item" and p.get("type") in ("custom_tool_call", "function_call", "local_shell_call"):
                    for where, commands, texts, paths in _calls(p, cwd):
                        for name in named(bounds, where, commands, texts, paths, {"CODEX_HOME": [home]}):
                            found.add("{} in {}".format(name, turn))
            for turn in sorted(ours - seen):      # a turn that cannot be read cannot be shown clean: it counts as a leak
                found.add("rollout unreadable in {}".format(turn))
    return sorted(found)


# ------------------------------------------------------------------ the round
_TALLY = threading.RLock()       # guards _FLIGHT and, with it, every read of the runs' charged tokens
_FLIGHT = {}                     # (state, case, label) -> the tokens of the turns the run's round in flight has completed, not yet charged to the run


def _key(a, run):
    return (a.state, run.get("case"), run.get("label"))


def spent_now(a, run):
    """Codex tokens spent under the state at this moment: every run's charged tokens (this run's as the caller holds it), the state's isolation
    probes (common.charge_probe) and the tokens of every round in flight, this one's included. A turn that completes is counted at once (flight_add), and a round's outcome is charged to its
    run under settling(), which drops the round from the flight in the same step, so a turn is counted exactly once."""
    with _TALLY:
        total = (run.get("tokens") or 0) + sum(n for k, n in _FLIGHT.items() if k[0] == a.state) + C.probe_tokens(a.state)
        for path in glob.glob(os.path.join(glob.escape(a.state), "runs", "*", "*", "state.json")):
            other = jload(path) or {}
            if (other.get("case"), other.get("label")) != (run.get("case"), run.get("label")):
                total += other.get("tokens") or 0
        return total


def flight_add(a, run, tokens):
    with _TALLY:
        key = _key(a, run)
        _FLIGHT[key] = _FLIGHT.get(key, 0) + tokens


def in_flight(a, run):
    """The tokens of the turns this run's round has completed and the run has not been charged."""
    with _TALLY:
        return _FLIGHT.get(_key(a, run), 0)


@contextlib.contextmanager
def settling(a, run):
    """Hold the tally while the caller charges the round's outcome to `run` and saves it; the round leaves the flight when the block ends."""
    with _TALLY:
        try:
            yield
        finally:
            _FLIGHT.pop(_key(a, run), None)


def _start(a, cwd):
    rc, out, err = XR.rpc("thread-start", "--cwd", cwd)
    if rc != 0 or not out.strip():
        raise Failed("cannot open a thread: {}".format(err.strip()))
    thread = out.strip().splitlines()[-1]
    XR.Threads(a.state).add(thread, "new")
    return thread


def _halt(a, home, run):
    """The reason no Codex turn may start now, as codex_round returns it: the token stop ({stopped}) when spent_now (every completed turn of
    every run, whichever job ran it) reaches a.max_tokens, else the weekly pause (weekly_hold), else None. Asked before every turn."""
    spent = spent_now(a, run)
    if spent >= a.max_tokens:
        return {"stopped": "the Codex token stop: {} tokens spent, stop at {}".format(spent, a.max_tokens)}
    return weekly_hold(home)


def codex_round(a, run, case, branch, home):
    ledger_home = run.get("ledger")
    if not ledger_home or not os.path.isdir(ledger_home):
        raise Failed("the run has no prepared ledger (prepare_ledger runs at setup)")
    k = 1 + sum(1 for r in run.get("reviews") or [] if r.get("kind") == "codex")
    with _TALLY:
        _FLIGHT[_key(a, run)] = 0            # a round begins with nothing in flight; what an earlier one left was charged or is lost
    halt = _halt(a, home, run)
    if halt:
        return halt

    repo = _repo(a, run)
    scratch = cwd = run["scratch"].rstrip("/")
    rundir = os.path.join(a.state, "runs", case["id"], run["label"])
    target = {"repo": repo, "dest": branch["dest"], "dest_ref": branch.get("dest_ref") or branch["dest"],
              "branch": branch.get("branch"), "range": _range(branch), "base": branch["base"],
              "tip": C.git(scratch, "rev-parse", "HEAD"), "full": True}
    out = os.path.join(rundir, "codex-{}".format(k))
    jsave(os.path.join(out, "body.md"), body(branch, k, run.get("addressed") or [], run.get("rejected") or []))
    previous = [r for r in run.get("reviews") or [] if r.get("kind") == "codex"]
    thread_in = run.get("thread") if k >= 2 else None
    req = {"checkpoint": "pre-merge", "body_file": os.path.join(out, "body.md"),
           "reviewer_md": os.path.join(XR.CONF, "reviewer.md"), "framing_md": os.path.join(XR.CONF, "reviewer-framing.md"),
           "cap": None, "switches_file": os.path.join(XR.CONF, "packets.conf"), "codex_home": home,
           "targets": [target], "specs": [target["range"]], "missed": (previous[-1].get("missing") or []) if previous else [],
           "thread": thread_in, "turns_file": None}
    try:
        with _state_home(ledger_home):
            dec = XP.build(req, os.path.join(out, "packets"))
    except Exception as e:
        raise RoundFailed("cannot build the packet: {}".format(e))
    jsave(os.path.join(out, "decision.json"), dec)
    if dec["action"] == "refuse":
        raise RoundFailed("refused: " + dec["reason"])
    framed = bool(dec["switches"]["framing"])
    schema = os.path.join(XR.CONF, "findings.framed.schema.json" if framed else "findings.schema.json")

    res = {"findings": [], "judged": [], "tokens": 0, "turns": [], "models": [], "approvals": []}
    thread = None
    bounds = forbidden(a.state, branch, [scratch], getattr(a, "snapshot_root", None), home=home)
    halt = None
    with homed(home):
        for i, pk in enumerate(dec["packets"]):
            halt = _halt(a, home, run)      # every turn asks again: an earlier one, of this round or another job's, may have crossed a limit
            if halt:
                break
            try:
                thread = thread_in if (dec["action"] == "send" and thread_in and i == 0) else _start(a, cwd)
                box = {}
                try:
                    doc, _compacted = XR.one_turn(thread, pk["file"], schema, cwd, a.budget, box)
                finally:
                    if box.get("turn"):
                        use = XR.turn_usage(thread, box["turn"])
                        res["tokens"] += use["tokens"]
                        flight_add(a, run, use["tokens"])
                        res["models"].append((use["model"], use["effort"]))
                        res["turns"].append([thread, box["turn"]])
            except Failed as e:
                failed = RoundFailed(str(e), res["tokens"], thread)
                try:
                    failed.leak = leaks(home, res["turns"], bounds, cwd)
                except Exception as scan:
                    failed.leak = ["the leak scan failed: {}".format(scan)]
                raise failed
            res["findings"] += [f for f in doc["findings"] if isinstance(f, dict)]
            res["approvals"].append(doc.get("verdict") == "approve")
            res["judged"].append(([x for x in doc.get("reviewed_files") or [] if isinstance(x, str)], pk.get("shown") or []))
    found = leaks(home, res["turns"], bounds, cwd)
    if found:
        return {"leak": found, "tokens": res["tokens"], "thread": thread, "turns": res["turns"]}
    if halt:       # no packet after the one that crossed the line started; the turns that ran are charged and the round is not a review, so it is redone whole
        return dict(halt, tokens=res["tokens"])
    missing = None
    if framed:
        # as xreview's _collect_record: a label is covered only when the turn that showed it lists it (compared
        # after stripping a/, b/ and ./); the uncovered ones keep their shown order before the cap
        missing = []
        for reviewed, shown in res["judged"]:
            listed = set(reviewed) | set(XR.norm(x) for x in reviewed)
            missing += [l for l in shown if l not in listed and XR.norm(l) not in listed]
        missing = missing[:XP.MISSING_CAP]
    return {"kind": "codex", "k": k, "findings": res["findings"], "verdict": "approve" if all(res["approvals"]) else "changes",
            "tokens": res["tokens"], "turns": res["turns"],
            "model": ",".join(sorted(set(m or "?" for m, _e in res["models"]))),
            "effort": ",".join(sorted(set(e or "?" for _m, e in res["models"]))),
            "missing": missing, "decision": dec, "thread": thread}
