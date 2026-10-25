#!/usr/bin/python3
# Pinned to the system interpreter, not `env python3`: an untrusted mise.toml in a reviewed
# repository can shadow `python3` on PATH, and the code that builds a review packet (and the
# gate that reads the same constants) must not be shadowable.
"""xreview-packet - the review packet xreview sends to the reviewer.

Managed by chezmoi (source: dot_claude/xreview-packet.py). xreview builds every packet through
this module, and the replay harness imports it, so the packets it tests are the ones dispatch
sends. It lives in ~/.claude beside the ledger, so neither xreview nor the gate runs code from a
directory the sandbox can write.
Design: docs/superpowers/specs/2026-10-25-xreview-review-packets-design.md, sections 3.1
(framing), 3.2 (the fit check), 3.3 (slices), 3.4 (delta rounds), 3.5 (plans covered by their
plan review) and 3.8 (switches).

It holds the switches, the fixed framing copy, the review units of a patch and how a unit is cut
into parts, the fit arithmetic, and today's packet, byte for byte. On top of that it reads a
thread's context from its rollout, decides whether a round can follow the last one (a delta),
which plans an approved plan review covers, and builds the packet: `build` turns a request into
a decision (send, fresh thread, slices or refuse) and the packet files. The ledger (the patch and
its identity) is loaded from XREVIEW_LEDGER, else from beside this file.

Command line:
  xreview-packet.py build REQUEST.json OUTDIR   write the packets, print the decision as JSON
  xreview-packet.py plan-blobs REPO BASE TIP    print the plans BASE..TIP adds, as JSON

Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
"""
import collections
import glob
import importlib.util
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from fractions import Fraction
from typing import Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER_PATH = os.environ.get("XREVIEW_LEDGER") or os.path.join(HERE, "xreview-ledger.py")

# The fit arithmetic (spec 3.2): need = context now + ceil(bytes / 3.5) + reserve, against
# limit = 0.9 x the context window. Measured: 3.5 bytes per token, a fresh thread starts at
# ~27k tokens (30k with margin), p99 growth within a turn is 56k.
BYTES_PER_TOKEN = 3.5
LIMIT_FRACTION = 0.9
RESERVE = 60000
FRESH_CONTEXT = 30000

# A receipt records at most this many uncovered files or part labels (spec 3.6); collect uses it.
MISSING_CAP = 50
# A slice's file list may take at most this share of a slice before it is cut to its own files (3.3).
FILE_LIST_SHARE = 0.1
# The plans a plan review can cover (spec 3.5).
PLAN_PREFIX = "docs/superpowers/plans/"

# The switches of packets.conf (spec 3.8), all off by default. The last three need framing.
SWITCHES = ("framing", "fit", "delta", "omit_plans")
NEEDS_FRAMING = ("fit", "delta", "omit_plans")

# The fixed framing copy (spec 3.1); reviewer-framing.md carries the same text for the reviewer.
MARKS = ("shown", "earlier", "elsewhere", "listed")
REVIEWED_FILES_TEXT = ("List in `reviewed_files` every file or part label marked shown that you "
                       "reviewed. Do not list a file you did not read.")
FILE_LIST_HEADER = "Files in this change ({}):"
FILE_LIST_LINE = "  {:<9} +{} -{}  {}"
# The fixed lines of a delta, a slice, a listed plan and a coverage gap (spec 3.3 to 3.6).
DELTA_HEADER = ("This round follows {} on this thread. The change as of that round is earlier in this "
                "thread; below is what changed since. Judge the change as it now stands, including how "
                "the new code meets the old.")
SLICE_HEADER = ("This is slice {} of {} of one change. The other slices are reviewed in their own turns. "
                "Open any file you need.")
LISTED_PLAN = ("{} was shown whole in the approved plan review {}; only its changes since then are "
               "shown here.")
MISSED_FILES = "The last round's reviewed_files did not list: {}. Review them too."
# The line a framed review without diffs carries where the file list would be (spec 3.1).
NO_DIFFS = "This review carries no diffs, so there is no file list; return reviewed_files as an empty list."
# Today's refusal when the diffs exceed the cap (xreview dispatch), verbatim; with framing on, the
# cap is Michael's to raise, as the cross-review skill says, and nothing offers another way round it.
CAP_REFUSAL = ("the diffs are too large to carry inline ({} bytes, cap {}).\n"
               "Review them in slices, or raise XREVIEW_MAX_DIFF_BYTES if the reviewer can hold it.")
CAP_REFUSAL_FRAMED = ("the diffs are too large to carry inline ({} bytes, cap {}). The cap is Michael's to "
                      "raise; no review was started.")
# Room a slice keeps for the digits of `slice i of n` and the like, and for a part's own list line.
SLICE_SLACK = 64
LINE_SLACK = 96
MIN_PART = 200

# A review unit (spec 3.3): one file's patch, or one part of it. label is the unquoted path,
# `<path>#<i>/<n>` for a part; path is the file's unquoted path; text is the patch bytes,
# beginning with the `diff --git` header; binary marks a `Binary file` summary line.
Unit = collections.namedtuple("Unit", "label path text plus minus binary")

_ledger_module = None


def _ledger():
    """The ledger module, loaded on first use from LEDGER_PATH."""
    global _ledger_module
    if _ledger_module is None:
        spec = importlib.util.spec_from_file_location("xreview_ledger", LEDGER_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _ledger_module = module
    return _ledger_module


# ------------------------------------------------------------------ switches
def _requested(path):
    """The switches as packets.conf asks for them: `key=on` is on; anything else, a missing
    key, a missing or unreadable file, is off. Unknown keys, comments and blank lines are
    ignored; the last line for a key wins."""
    found = dict((name, False) for name in SWITCHES)
    try:
        with open(path, "rb") as handle:
            text = handle.read().decode("utf-8", "replace")
    except OSError:
        return found
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        key = key.strip()
        if sep and key in found:
            found[key] = value.strip() == "on"
    return found


def read_switches(path):
    """The switches in force, by name, each True or False. Fit, delta and omit_plans need
    framing: with framing off they act as off."""
    found = _requested(path)
    if not found["framing"]:
        return dict((name, False) for name in SWITCHES)
    return found


def switches_ignored(path):
    """The switches packets.conf turns on that read_switches forces off for want of framing,
    in switch order, so xreview can say so once per dispatch."""
    found = _requested(path)
    if found["framing"]:
        return []
    return [name for name in NEEDS_FRAMING if found[name]]


# ------------------------------------------------------------------ the fit arithmetic
def estimate_tokens(nbytes):
    """ceil(nbytes / BYTES_PER_TOKEN), in exact arithmetic."""
    return int(math.ceil(Fraction(nbytes) / Fraction(str(BYTES_PER_TOKEN))))


def fits(context_now, nbytes, window):
    """Whether a packet of nbytes fits a thread now holding context_now tokens, in a window of
    window tokens: context_now + estimate_tokens(nbytes) + RESERVE <= LIMIT_FRACTION x window.
    Exact: no floating-point rounding at the boundary."""
    need = context_now + estimate_tokens(nbytes) + RESERVE
    return Fraction(need) <= Fraction(str(LIMIT_FRACTION)) * Fraction(window)


# ------------------------------------------------------------------ the file list
def _has_control(text):
    return any(ord(c) < 0x20 or c == "\x7f" for c in text)


def label_text(label):
    """A label as a packet prints it, and as the reviewer is held to it: as it is, unless it holds
    a control character or starts with a double quote; then it is in double quotes with git's C
    escapes (the ledger's quote_path), so no file name can end a line of the file list or forge
    one, and no two labels print alike."""
    if _has_control(label) or label.startswith('"'):
        return _ledger().quote_path(os.fsencode(label)).decode("ascii")
    return label


def _line_safe(text):
    """text for a fixed note: quoted only when it holds a control character, so a label the file
    list already printed quoted is named as it was printed."""
    return label_text(text) if _has_control(text) else text


def file_list(entries):
    """The packet's opening list: `Files in this change (<n>):`, then one line per entry,
    `  <mark:9> +<plus> -<minus>  <label>`. entries is [(mark, plus, minus, label)]. Every line,
    the last too, ends in a newline."""
    lines = [FILE_LIST_HEADER.format(len(entries))]
    for mark, plus, minus, label in entries:
        lines.append(FILE_LIST_LINE.format(mark, plus, minus, label))
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------ review units
_ESCAPES = {ord("a"): 7, ord("b"): 8, ord("t"): 9, ord("n"): 10, ord("v"): 11, ord("f"): 12,
            ord("r"): 13, ord('"'): 34, ord("\\"): 92}
_BINARY = re.compile(rb"\ABinary file (.*): ([0-7]{6}) ([0-9a-f]+) -> ([0-7]{6}) ([0-9a-f]+)\n?\Z",
                     re.S)
_HUNK_HEAD = re.compile(rb"\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*?)(\n?)\Z", re.S)


def _lines(data):
    """data as lines, each with its newline; a final line without one keeps none. Splits on
    \\n only: a carriage return is line content."""
    parts = data.split(b"\n")
    out = [p + b"\n" for p in parts[:-1]]
    if parts[-1]:
        out.append(parts[-1])
    return out


def _unquote(token):
    """A path as git quotes it (see the ledger's quote_path), back to bytes. A token that is
    not in double quotes is returned as it is."""
    if not (len(token) >= 2 and token[:1] == b'"' and token[-1:] == b'"'):
        return token
    inner, out, i = token[1:-1], bytearray(), 0
    while i < len(inner):
        c = inner[i]
        if c != 0x5c or i + 1 >= len(inner):
            out.append(c)
            i += 1
        elif inner[i + 1] in _ESCAPES:
            out.append(_ESCAPES[inner[i + 1]])
            i += 2
        elif re.match(rb"[0-7]{3}", inner[i + 1:i + 4]):
            out.append(int(inner[i + 1:i + 4], 8))
            i += 4
        else:
            out.append(c)
            i += 1
    return bytes(out)


def _quoted_end(rest):
    """The index just past the double-quoted token that starts rest."""
    i = 1
    while i < len(rest):
        if rest[i] == 0x5c:
            i += 2
        elif rest[i] == 0x22:
            return i + 1
        else:
            i += 1
    return len(rest)


def _header_path(line):
    """The path of a `diff --git a/<path> b/<path>` line, unquoted, as str. Both sides name the
    same path (the diff never detects renames), which is how an unquoted path that holds spaces,
    or ` b/`, is told apart."""
    rest = line[len(b"diff --git "):].rstrip(b"\n")
    if rest[:1] == b'"':
        token = _unquote(rest[:_quoted_end(rest)])
        path = token[2:]
    else:
        half = (len(rest) - len(b"a/ b/")) // 2
        path = rest[2:2 + half]
        if half < 0 or rest != b"a/" + path + b" b/" + path:
            path = rest[2:].split(b" b/", 1)[0]
    return os.fsdecode(path)


def _count(text):
    """The added and removed lines of a patch's hunks (not the ---/+++ header lines)."""
    plus = minus = 0
    inside = False
    for line in _lines(text):
        if line.startswith(b"@@"):
            inside = True
        elif inside and line[:1] == b"+":
            plus += 1
        elif inside and line[:1] == b"-":
            minus += 1
    return plus, minus


def _units(data):
    """The units of a patch: one per file (the two `diff --git` sections of a type change are one
    unit), one per `Binary file` line. A hunk
    line begins with a space, + or - and never with `diff --git ` or `Binary file `, so both
    start a section wherever they appear."""
    sections, current, kind = [], [], None
    for line in _lines(data):
        if line.startswith(b"diff --git "):
            new = "text"
        elif line.startswith(b"Binary file "):
            new = "binary"
        else:
            new = None
        if new is not None:
            if current:
                sections.append((kind, b"".join(current)))
            current, kind = [], new
        current.append(line)
    if current:
        sections.append((kind, b"".join(current)))
    units = []
    for kind, text in sections:
        if kind == "binary":
            match = _BINARY.match(text)
            path = os.fsdecode(_unquote(match.group(1))) if match else os.fsdecode(text[12:].rstrip(b"\n"))
            units.append(Unit(path, path, text, 0, 0, True))
        else:
            path = _header_path(text.split(b"\n", 1)[0] + b"\n")
            plus, minus = _count(text)
            last = units[-1] if units else None
            if last is not None and not last.binary and last.path == path:
                # A type change (file, symlink, gitlink) is a delete and a create of one path:
                # one file, so one unit with both sections in git's order.
                units[-1] = Unit(path, path, last.text + text, last.plus + plus, last.minus + minus, False)
            else:
                units.append(Unit(path, path, text, plus, minus, False))
    return units


def units_for(repo, base, tip, exclude=()):
    """The review units of base..tip, in patch order, from the ledger's patch: a text file's
    patch is one unit, a binary file's summary line is one binary unit. Labels are unquoted
    paths. exclude is the ledger's: literal top-level paths left out."""
    return _units(_ledger().patch(repo, base, tip, exclude))


# ------------------------------------------------------------------ cutting a unit into parts
def _range(next_line, count):
    """One side of a hunk header: `start,count`, with git's conventions: a count of 1 is
    omitted, and an empty side starts at the line before."""
    start = next_line if count > 0 else next_line - 1
    return str(start) if count == 1 else "{},{}".format(start, count)


def _hunk_head(old_next, old_count, new_next, new_count, tail=b""):
    return (("@@ -" + _range(old_next, old_count) + " +" + _range(new_next, new_count) + " @@")
            .encode("ascii") + tail + b"\n")


def _hunks(text):
    """(header, [hunk, ...]): the bytes before the first `@@` line, and each hunk from its
    `@@` line to the next."""
    header, hunks = [], []
    for line in _lines(text):
        if line.startswith(b"@@"):
            hunks.append([line])
        elif hunks:
            hunks[-1].append(line)
        else:
            header.append(line)
    return b"".join(header), [b"".join(h) for h in hunks]


def _groups(body):
    """The body lines of a hunk as groups: a line with the `\\ No newline` marker lines that
    follow it, which can never start a part."""
    groups = []
    for line in _lines(body):
        if line[:1] == b"\\" and groups:
            groups[-1].append(line)
        else:
            groups.append([line])
    return groups


def _byte_parts(header, group, old_next, new_next, max_bytes):
    """The parts of one body line (with its marker lines) that is too big for a part: byte
    ranges cut at UTF-8 character boundaries. Each part is the header, a one-line hunk header
    that names the line and its bytes (`line N, bytes a-b of c`, 1-based and inclusive, counted
    in the line without its prefix), the range behind the line's prefix, and a newline; the
    last part also carries the marker lines. Returns [(text, plus, minus)]: only the first part
    counts the line, so the parts' counts add up to the file's."""
    first = group[0]
    prefix = first[:1] if first[:1] in (b"+", b"-") else b" "
    content = first[1:] if first[:1] in (b"+", b"-", b" ") else first
    if content.endswith(b"\n"):
        content = content[:-1]
    markers = b"".join(group[1:])
    old_count = 0 if prefix == b"+" else 1
    new_count = 0 if prefix == b"-" else 1
    number = old_next if prefix == b"-" else new_next
    size = len(content)

    def head(a, b):
        tail = " line {}, bytes {}–{} of {}".format(number, a, b, size).encode("utf-8")
        return _hunk_head(old_next, old_count, new_next, new_count, tail)

    budget = max_bytes - len(header) - len(head(size, size)) - len(prefix) - 1 - len(markers)
    # Under 4 bytes a range cannot always hold a whole UTF-8 character, and would cut one.
    if budget < 4:
        raise ValueError("max_bytes {} is too small to hold part of a {}-byte line".format(max_bytes, size))
    parts, pos = [], 0
    while pos < size:
        end = min(size, pos + budget)
        if end < size:
            cut = end
            while cut > pos and (content[cut] & 0xC0) == 0x80:
                cut -= 1
            end = cut if cut > pos else end
        text = header + head(pos + 1, end) + prefix + content[pos:end] + b"\n"
        if end == size:
            text += markers
        parts.append((text, (1 if prefix == b"+" else 0) if pos == 0 else 0,
                      (1 if prefix == b"-" else 0) if pos == 0 else 0))
        pos = end
    return parts


def _line_parts(header, hunk, max_bytes):
    """The parts of one hunk that is too big for a part: consecutive line ranges, each with a
    corrected hunk header (and the original's function heading on the first), and a line that is
    itself too big cut into byte ranges. Returns [(text, plus, minus)]."""
    first, _, body = hunk.partition(b"\n")
    match = _HUNK_HEAD.match(first + b"\n")
    if not match:
        raise ValueError("cannot read the hunk header {!r}".format(first[:60]))
    old_start, old_len, new_start, new_len = (int(x) if x is not None else 1 for x in match.groups()[:4])
    if match.group(2) is not None and old_len == 0:
        old_start += 1
    if match.group(4) is not None and new_len == 0:
        new_start += 1
    old_next, new_next, tail = old_start, new_start, match.group(5)
    parts, rows, o_count, n_count, size = [], [], 0, 0, 0
    r_old, r_new = old_next, new_next

    def flush():
        nonlocal rows, o_count, n_count, size, tail
        if rows:
            text = header + _hunk_head(r_old, o_count, r_new, n_count, tail) + b"".join(rows)
            parts.append((text,) + _count(text))
            tail = b""
        rows, o_count, n_count, size = [], 0, 0, 0

    for group in _groups(body):
        lead = group[0][:1]
        d_old = 0 if lead == b"+" else 1      # a context line, or any other, counts on both sides
        d_new = 0 if lead == b"-" else 1
        data = b"".join(group)
        head_len = len(_hunk_head(r_old if rows else old_next, o_count + d_old,
                                  r_new if rows else new_next, n_count + d_new, tail))
        if rows and len(header) + head_len + size + len(data) > max_bytes:
            flush()
            r_old, r_new = old_next, new_next
            head_len = len(_hunk_head(old_next, d_old, new_next, d_new, tail))
        if len(header) + head_len + len(data) > max_bytes:
            parts.extend(_byte_parts(header, group, old_next, new_next, max_bytes))
            tail = b""
        else:
            if not rows:
                r_old, r_new = old_next, new_next
            rows.append(data)
            size += len(data)
            o_count += d_old
            n_count += d_new
        old_next += d_old
        new_next += d_new
    flush()
    return parts


def _whole(header, hunks):
    text = header + b"".join(hunks)
    return (text,) + _count(text)


def _sections(text):
    """The `diff --git` sections of a unit's text: one, or two for a type change."""
    sections = []
    for line in _lines(text):
        if line.startswith(b"diff --git ") or not sections:
            sections.append([])
        sections[-1].append(line)
    return [b"".join(s) for s in sections]


def _section_pieces(section, max_bytes):
    """[(text, plus, minus)] for one `diff --git` section, each piece with that section's header."""
    header, hunks = _hunks(section)
    if not hunks:
        return [(section,) + _count(section)]
    pieces, group = [], []
    for hunk in hunks:
        if len(header) + len(hunk) > max_bytes:
            if group:
                pieces.append(_whole(header, group))
                group = []
            pieces.extend(_line_parts(header, hunk, max_bytes))
        elif group and len(header) + sum(len(g) for g in group) + len(hunk) > max_bytes:
            pieces.append(_whole(header, group))
            group = [hunk]
        else:
            group.append(hunk)
    if group:
        pieces.append(_whole(header, group))
    return pieces


def split_unit(u, max_bytes):
    """The unit as parts of at most max_bytes each, every part carrying its
    section's `diff --git` header (a type change has two sections, cut apart), in this order of preference:
      - groups of whole hunks;
      - a hunk too big for a part, as consecutive line ranges with recomputed `@@ -a,b +c,d @@`
        headers;
      - a line too big for a part, as byte ranges at UTF-8 character boundaries.
    Labels are `<path>#<i>/<n>`. A unit that fits, or a binary unit, comes back as it is, in a
    list of one. Raises ValueError when max_bytes cannot hold the header and a few bytes."""
    if u.binary or len(u.text) <= max_bytes:
        return [u]
    pieces = []
    for section in _sections(u.text):
        pieces.extend(_section_pieces(section, max_bytes))
    total = len(pieces)
    parts = []
    for i, (text, plus, minus) in enumerate(pieces):
        parts.append(Unit("{}#{}/{}".format(u.path, i + 1, total), u.path, text, plus, minus, False))
    return parts


# ------------------------------------------------------------------ today's packet
def _bytes(value):
    return os.fsencode(value) if isinstance(value, str) else value


def today_packet(reviewer_md, body, diffs):
    """The request cmd_dispatch writes today, byte for byte, from the reviewer instructions,
    the body, and the diffs as [(spec, diff bytes)]:

        <cross-review-request>
        <reviewer.md> <newline> <body, as it is>
        <one block per diff: two newlines, `--- diff (<spec>) ---`, the diff, `--- end diff ---`>
        <one newline, only when there is a block>
        </cross-review-request>

    The shell takes each diff through $(...), which strips its trailing newlines; so does this."""
    out = [b"<cross-review-request>\n", _bytes(reviewer_md), b"\n", _bytes(body)]
    blocks = b"".join(b"\n\n--- diff (" + _bytes(spec) + b") ---\n" + _bytes(d).rstrip(b"\n")
                      + b"\n--- end diff ---" for spec, d in diffs)
    if blocks:
        out += [blocks, b"\n"]
    out.append(b"</cross-review-request>\n")
    return b"".join(out)


# ------------------------------------------------------------------ the thread's context
_ROLLOUT_NAME = r"rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-"
_THREAD_ID = re.compile(r"\A[0-9A-Za-z][0-9A-Za-z_-]*\Z")


def _codex_home(codex_home):
    return codex_home or os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def _count_ok(value, minimum):
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def _rollout_files(home, thread=None):
    """The rollout files under home's sessions and archived_sessions, plain `.jsonl` and the
    `.jsonl.zst` Codex compresses older ones to: those of one thread, or all of them. A thread id
    is matched as a file name's end, never as a glob."""
    name = re.compile(r"\A" + _ROLLOUT_NAME + (re.escape(thread) if thread else r".+")
                      + r"\.jsonl(?:\.zst)?\Z")
    found = []
    for sub in ("sessions", "archived_sessions"):
        pattern = os.path.join(glob.escape(os.path.join(home, sub)), "**", "rollout-*.jsonl*")
        found.extend(p for p in glob.glob(pattern, recursive=True) if name.match(os.path.basename(p)))
    return found


class _RolloutLines(object):
    def __init__(self, path):
        self.path, self.proc, self.handle, self.failed = path, None, None, False

    def __enter__(self):
        if not self.path.endswith(".zst"):
            self.handle = open(self.path, "rb")
            return self.handle
        zstd = shutil.which("zstd")
        if not zstd:
            raise OSError("zstd is not installed, so {} cannot be read".format(self.path))
        self.proc = subprocess.Popen([zstd, "-dc", "--", self.path], stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return self.proc.stdout

    def __exit__(self, *_exc):
        if self.handle is not None:
            self.handle.close()
        if self.proc is not None:
            self.proc.stdout.close()
            self.failed = self.proc.wait() != 0
        return False


def _rollout_values(path):
    """(context now, window) from one rollout: the latest `event_msg` token_count record gives
    `info.last_token_usage.total_tokens` and `info.model_context_window`; a `task_started` record
    carries the window too. A value that is not a whole number is None, as is a file that cannot
    be read. A `.jsonl.zst` is streamed through `zstd -dc`; if zstd is missing, cannot start or
    exits non-zero (a corrupt or truncated file), nothing is returned, not the records read so far."""
    context = window = None
    lines = _RolloutLines(path)
    try:
        with lines as handle:
            for line in handle:
                if b'"token_count"' not in line and b'"task_started"' not in line:
                    continue
                try:
                    record = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                payload = record.get("payload") if isinstance(record, dict) and record.get("type") == "event_msg" else None
                if not isinstance(payload, dict):
                    continue
                if payload.get("type") == "task_started":
                    if _count_ok(payload.get("model_context_window"), 1):
                        window = payload["model_context_window"]
                elif payload.get("type") == "token_count" and isinstance(payload.get("info"), dict):
                    info = payload["info"]
                    last = info.get("last_token_usage")
                    now = last.get("total_tokens") if isinstance(last, dict) else None
                    context = now if _count_ok(now, 0) else None
                    if _count_ok(info.get("model_context_window"), 1):
                        window = info["model_context_window"]
    except OSError:
        return None, None
    if lines.failed:
        return None, None
    return context, window


def thread_context(codex_home, thread) -> Tuple[Optional[int], Optional[int]]:
    """(context now, window) of a thread, from its newest rollout (`.jsonl` or `.jsonl.zst`, by
    modification time) under codex_home (CODEX_HOME, else ~/.codex). None for a value that cannot
    be read; (None, None) when there is no rollout or it cannot be read."""
    if not (isinstance(thread, str) and _THREAD_ID.match(thread)):
        return None, None
    files = _rollout_files(_codex_home(codex_home), thread)
    if not files:
        return None, None

    def age(path):
        try:
            return os.path.getmtime(path)
        except OSError:
            return 0
    return _rollout_values(max(files, key=age))


def _entries(common):
    """The v2 entries on record for a repository (its git common directory), else none."""
    ledger = _ledger()
    try:
        path = ledger.ledger_file(common)
        return ledger.read_entries(path) if os.path.lexists(path) else []
    except (OSError, ledger.Fail):
        return []


def _receipts(entries):
    return [e for e in entries if isinstance(e, dict) and e.get("v") == 2 and e.get("kind") == "receipt"]


def _newest_first(items):
    """(receipt) entries newest dispatch first; ties in the order they reached the ledger."""
    keyed = [((e["dispatched_at"] if isinstance(e.get("dispatched_at"), str) else ""), i, e)
             for i, e in enumerate(items)]
    return [e for _at, _i, e in sorted(keyed, key=lambda k: (k[0], k[1]), reverse=True)]


def fresh_window(codex_home, repo_common) -> Optional[int]:
    """The window a fresh thread will have: the newest `model_context_window` among this
    repository's review threads (the `thread` of its ledger's receipts), else among any rollout.
    None when none can be read."""
    home = _codex_home(codex_home)
    seen = set()
    for receipt in _newest_first(_receipts(_entries(repo_common))) if repo_common else []:
        thread = receipt.get("thread")
        if isinstance(thread, str) and thread not in seen:
            seen.add(thread)
            window = thread_context(home, thread)[1]
            if window is not None:
                return window
    for path in sorted(_rollout_files(home), key=os.path.basename, reverse=True)[:40]:
        window = _rollout_values(path)[1]
        if window is not None:
            return window
    return None


def max_packet_bytes(context_now, window):
    """The most bytes a packet may have for `fits(context_now, bytes, window)` to hold; 0 when
    not even an empty packet fits. Exact: need <= limit is ceil(bytes / 3.5) <= floor(0.9 x
    window) - context_now - reserve."""
    room = math.floor(Fraction(str(LIMIT_FRACTION)) * Fraction(window)) - context_now - RESERVE
    if room <= 0:
        return 0
    return int(math.floor(Fraction(room) * Fraction(str(BYTES_PER_TOKEN))))


# ------------------------------------------------------------------ delta rounds (spec 3.4)
def _link_target(entries, receipt, repo, dest, base, newer_tip):
    """The one target of receipt that a later round on dest and base can follow: a full-range
    target on the same repository, destination and base whose tip is an ancestor of newer_tip.
    None when there is none or more than one (the gate denies an ambiguous link)."""
    ledger = _ledger()
    _entry, found = ledger.receipt_of(entries, receipt.get("nonce"), repo)
    same = [t for t in found if t.get("full") is True and t.get("dest") == dest and t.get("base") == base]
    starts = [t for t in same if ledger.is_ancestor(repo, t.get("tip"), newer_tip)]
    return starts[0] if len(starts) == 1 else None


def delta_base(entries, thread, target, turns):
    """The receipt a round on `thread` can follow with a delta, or None (then the packet is full).
    entries is the repository's ledger; turns is `xreview-rpc thread-turns`'s answer, or None
    when the history is unknown. Spec 3.4, in order:
      - the newest receipt on the thread is a pre-merge one for the same repository, destination
        and base, whose tip is an ancestor of the new tip;
      - it is clean, and so is every receipt back to the chain's root, each link on this thread
        with its plans backed;
      - the root is a full packet (a sliced round never roots a chain);
      - the thread still holds every chain turn, root first; no turn since the root carries a
        compaction (unknown counts as one); and the thread has no thread-level compaction
        (unknown counts as one).
    The gate's own chain check runs last on the receipt this round would record, so xreview
    never builds a chain the gate would deny."""
    ledger = _ledger()
    if not (isinstance(thread, str) and thread and isinstance(turns, dict)):
        return None
    listed, compactions = turns.get("turns"), turns.get("thread_compactions")
    if not (isinstance(listed, list) and all(isinstance(x, dict) and isinstance(x.get("id"), str) for x in listed)):
        return None
    if isinstance(compactions, bool) or not isinstance(compactions, int) or compactions != 0:
        return None
    repo, dest, base, tip = (target.get(k) for k in ("repo", "dest", "base", "tip"))
    if target.get("full") is not True or not all(isinstance(x, str) and x for x in (repo, dest, base, tip)):
        return None
    ids = [x["id"] for x in listed]
    on_thread = [e for e in _receipts(entries) if e.get("thread") == thread]
    if not on_thread:
        return None
    newest = _newest_first(on_thread)[0]
    chain, seen, cur, newer_tip = [], set(), newest, tip
    while True:
        nonce = cur.get("nonce")
        if not isinstance(nonce, str) or nonce in seen:
            return None
        seen.add(nonce)
        if (cur.get("checkpoint") != "pre-merge" or cur.get("thread") != thread
                or cur.get("clean") is not True):
            return None
        turn = cur.get("turn")
        link = _link_target(entries, cur, repo, dest, base, newer_tip)
        if not (isinstance(turn, str) and turn) or link is None or ledger.plans_problem(entries, link):
            return None
        chain.append(turn)
        if link.get("packet") == "full":
            break
        follows = link.get("delta_from")
        if link.get("packet") != "delta" or not (isinstance(follows, str) and follows):
            return None
        cur, _found = ledger.receipt_of(entries, follows, repo)
        if cur is None:
            return None
        newer_tip = link.get("tip")
    at, root_at = 0, None
    for turn in reversed(chain):
        if turn not in ids[at:]:
            return None
        found_at = ids.index(turn, at)
        root_at = found_at if root_at is None else root_at
        at = found_at + 1
    if any(x.get("compacted") is not False for x in listed[root_at:]):
        return None
    probe = {"nonce": "xr-delta-probe", "thread": thread}
    follow = dict(target, packet="delta", delta_from=newest.get("nonce"), history=ids)
    if ledger.chain_problem(entries, probe, follow, repo) is not None:
        return None
    return newest


# ------------------------------------------------------------------ plans covered by a plan review (3.5)
def _plan_changes(repo, base, tip):
    """The plans base..tip changes and still has, as {path: blob id at tip}: regular files under
    PLAN_PREFIX that exist at tip."""
    prefix = PLAN_PREFIX.encode("ascii")
    found = {}
    for path, _old_mode, new_mode, _old_blob, new_blob in _ledger().raw_records(repo, base, tip):
        if path.startswith(prefix) and new_mode in (b"100644", b"100755"):
            found[os.fsdecode(path)] = new_blob.decode("ascii")
    return found


def plan_listing(entries, repo, target):
    """The plans of target's range that an approved plan review covers, as
    {path: {nonce, blob}}. For each plan the range changes, the latest plan-checkpoint receipt of
    this repository that is an approve, is clean and has the path in a target's plan_blobs binds
    it, if the patch from that blob to the plan as it now is can be rendered. Anything else is
    left out, and its whole patch is shown."""
    ledger = _ledger()
    scope = target.get("repo")
    changes = _plan_changes(repo, target["base"], target["tip"])
    if not changes:
        return {}
    plans = _newest_first([e for e in _receipts(entries) if e.get("checkpoint") == "plan"
                           and e.get("verdict") == "approve" and e.get("clean") is True
                           and isinstance(e.get("nonce"), str) and e.get("nonce")])
    listing = {}
    for path in sorted(changes):
        for receipt in plans:
            bound = None
            for t in receipt.get("targets") or []:
                blobs = t.get("plan_blobs") if isinstance(t, dict) and t.get("repo") == scope else None
                if isinstance(blobs, dict) and isinstance(blobs.get(path), str):
                    bound = blobs[path]
                    break
            if bound is None:
                continue
            try:
                ledger.blob_patch(repo, path, bound, changes[path])
            except ledger.Fail:
                pass
            else:
                listing[path] = {"nonce": receipt["nonce"], "blob": bound}
            break
    return listing


# ------------------------------------------------------------------ building a packet
class _Refuse(Exception):
    """A request that cannot be built; the message is the decision's reason."""


class _Target(object):
    """One target of a request while its packet is built: kind (full or delta), the receipt a
    delta follows, the plans listed, the patch shown and the units of it."""


def _label_prefix(spec, several):
    """With several targets a path carries its target's label: the part of the --diff spec before
    its last colon (`.` when it named none), then a colon."""
    if not several:
        return ""
    head, sep, _tail = spec.rpartition(":")
    return (head if sep and head else ".") + ":"


def _slurp(path):
    with open(path, "rb") as handle:
        return handle.read()


def _nl(data):
    return data if not data or data.endswith(b"\n") else data + b"\n"


def _row_key(index, unit):
    part = 0
    if unit.label != unit.path:
        match = re.search(r"#([0-9]+)/[0-9]+\Z", unit.label)
        part = int(match.group(1)) if match else 0
    return (index, os.fsencode(unit.path), part)


def _listing_bytes(rows):
    """The file list of rows [(key, mark, plus, minus, label)], in key order."""
    ordered = sorted(rows, key=lambda r: r[0])
    return os.fsencode(file_list([(m, p, n, l) for _k, m, p, n, l in ordered]))


def _static_rows(t):
    """The file-list rows that do not depend on which units a packet carries: the files of a
    delta's whole change that this packet does not show (earlier), and a listed plan with no
    later patch (listed), both with the whole change's counts."""
    rows = []
    if t.all_units is None:
        return rows
    shown = set(u.path for u in t.units)
    totals = collections.OrderedDict()
    for u in t.all_units:
        plus, minus = totals.get(u.path, (0, 0))
        totals[u.path] = (plus + u.plus, minus + u.minus)
    for path, (plus, minus) in totals.items():
        if path in shown:
            continue
        if t.kind == "delta":
            mark = "earlier"
        elif path in t.listed:
            mark = "listed"
        else:
            continue
        rows.append(((t.index, os.fsencode(path), 0), mark, plus, minus, label_text(t.prefix + path)))
    return rows


def _notes(ts, missed, first=None):
    """The fixed lines between the body and the file list: the slice header, each delta's
    header, each listed plan's line, then the files missed last round."""
    lines = [first] if first else []
    for t in ts:
        if t.kind == "delta":
            lines.append((t.prefix + " " if t.prefix else "") + DELTA_HEADER.format(t.follows["nonce"]))
    for t in ts:
        for path in sorted(t.listed):
            lines.append(LISTED_PLAN.format(label_text(t.prefix + path), t.listed[path]["nonce"]))
    if missed:
        lines.append(MISSED_FILES.format(", ".join(_line_safe(m) for m in missed)))
    return lines


def _framed(reviewer, framing, body, notes, listing, blocks):
    """A framed request: the reviewer instructions, the framing text, the body, the fixed notes,
    the file list, then one diff block per target [(spec, diff bytes)]."""
    out = [b"<cross-review-request>\n", reviewer, b"\n", _nl(framing), b"\n", _nl(body)]
    if notes:
        out.append(b"\n")
        out.extend(os.fsencode(n) + b"\n" for n in notes)
    if listing:
        out += [b"\n", listing]
    for spec, diff in blocks:
        out.append(b"\n--- diff (" + os.fsencode(spec) + b") ---\n" + diff.rstrip(b"\n") + b"\n--- end diff ---\n")
    out.append(b"</cross-review-request>\n")
    return b"".join(out)


def _prepare(c, delta_ok):
    """Each target of the request as a _Target: a delta where it qualifies (and delta_ok), else
    a full packet with the plans an approved plan review covers left out when omit_plans is on."""
    ledger = _ledger()
    ts = []
    for index, (target, spec) in enumerate(zip(c["targets"], c["specs"])):
        t = _Target()
        t.index, t.target, t.spec = index, target, spec
        t.prefix = _label_prefix(spec, len(c["targets"]) > 1)
        t.kind, t.follows, t.history, t.listed, t.all_units = "full", None, None, {}, None
        repo, base, tip = target["repo"], target["base"], target["tip"]
        entries = c["entries"](repo)
        previous = delta_base(entries, c["thread"], target, c["turns"]) if delta_ok else None
        if previous is not None:
            link = _link_target(entries, previous, repo, target["dest"], base, tip)
            diff = ledger.patch(repo, link["tip"], tip)
            if diff:
                t.kind, t.follows, t.diff = "delta", previous, diff
                t.history = [x["id"] for x in c["turns"]["turns"]]
                t.all_units = units_for(repo, base, tip)
        if t.kind == "full":
            if c["sw"]["omit_plans"] and c["checkpoint"] == "pre-merge":
                t.listed = plan_listing(entries, repo, target)
            diff = ledger.patch(repo, base, tip, tuple(sorted(t.listed)))
            if t.listed:
                now = _plan_changes(repo, base, tip)
                for path in sorted(t.listed):
                    diff += ledger.blob_patch(repo, path, t.listed[path]["blob"], now[path])
                t.all_units = units_for(repo, base, tip)
            t.diff = diff
        t.units = _units(t.diff)
        ts.append(t)
    return ts


def _unsliced(c, ts):
    """(request bytes, shown labels) of the targets as one packet."""
    rows = []
    for t in ts:
        for u in t.units:
            rows.append((_row_key(t.index, u), "shown", u.plus, u.minus, label_text(t.prefix + u.label)))
        rows.extend(_static_rows(t))
    shown =[r[4] for r in sorted((r for r in rows if r[1] == "shown"), key=lambda r: r[0])]
    listing = _listing_bytes(rows) if ts else os.fsencode(NO_DIFFS + "\n")
    data = _framed(c["reviewer"], c["framing"], c["body"], _notes(ts, c["missed"]), listing,
                   [(t.spec, t.diff) for t in ts])
    return data, shown


def _cut_listing(total, rows, ts):
    """A slice's file list when the whole list is too long: its own files only, the number of
    files in all, and the command that lists them."""
    lines = [FILE_LIST_HEADER.format(total)]
    lines += [FILE_LIST_LINE.format(m, p, n, l) for _k, m, p, n, l in sorted(rows, key=lambda r: r[0])]
    lines.append("The other files are not listed here; these commands list them all:")
    for t in ts:
        lines.append("  git --git-dir={} diff --stat {} {} --".format(
            shlex.quote(t.target["repo"]), t.target["base"], t.target["tip"]))
    return os.fsencode("\n".join(lines) + "\n")


def _slices(c, ts, window):
    """The request as slices (spec 3.3): [(bytes, shown labels)]. Units are cut into parts to fit,
    packed in path order, each slice's need within the limit at a fresh thread's start."""
    top = max_packet_bytes(FRESH_CONTEXT, window)
    if top <= 0:
        raise _Refuse("the model's context window of {} tokens leaves no room for a review packet "
                      "on a fresh thread".format(window))
    share = Fraction(str(FILE_LIST_SHARE))
    block = [len(b"\n--- diff (" + os.fsencode(t.spec) + b") ---\n") + len(b"\n--- end diff ---\n") for t in ts]
    base_len = len(_framed(c["reviewer"], c["framing"], c["body"],
                           _notes(ts, c["missed"], first=SLICE_HEADER.format(999999, 999999)), b"", []))
    headroom = top - base_len - int(math.ceil(share * top)) - (max(block) if block else 0) - SLICE_SLACK
    units = []
    for t in ts:
        for u in t.units:
            room = headroom - len(os.fsencode(label_text(t.prefix + u.path))) - LINE_SLACK
            if len(u.text) <= room:
                parts = [u]
            elif room < MIN_PART:
                raise _Refuse("the packet around a change leaves no room for any of it in a slice")
            else:
                try:
                    parts = split_unit(u, room)
                except ValueError as e:
                    raise _Refuse("a file of the change cannot be cut to fit a slice: {}".format(e))
            units.extend((_row_key(t.index, p), t.index, p) for p in parts)
    if not units:
        raise _Refuse("the request alone does not fit a fresh thread, and there is no diff to slice")
    units.sort(key=lambda x: x[0])
    static = [r for t in ts for r in _static_rows(t)]
    label = lambda i, p: label_text(ts[i].prefix + p.label)
    all_rows = [(k, "shown", p.plus, p.minus, label(i, p)) for k, i, p in units] + static
    total = len(all_rows)
    whole_list = len(_listing_bytes(all_rows))
    full_mode = whole_list <= share * top
    own_line = lambda i, p: len(os.fsencode(FILE_LIST_LINE.format("shown", p.plus, p.minus, label(i, p)))) + 1
    fixed = whole_list if full_mode else len(_cut_listing(total, [], ts))
    budget = top - base_len - SLICE_SLACK - fixed
    slices, used, present = [[]], 0, set()
    for n, (_k, i, p) in enumerate(units):
        cost = len(p.text) + (0 if full_mode else own_line(i, p))
        add = cost + (0 if i in present else block[i])
        if slices[-1] and used + add > budget:
            slices.append([])
            used, present = 0, set()
            add = cost + block[i]
        if add > budget:
            raise _Refuse("a part of the change does not fit a slice")
        slices[-1].append(n)
        used += add
        present.add(i)
    out = []
    for number, members in enumerate(slices, 1):
        mine = set(members)
        rows = [(k, "shown" if n in mine else "elsewhere", p.plus, p.minus, label(i, p))
                for n, (k, i, p) in enumerate(units) if full_mode or n in mine]
        listing = _listing_bytes(rows + static) if full_mode else _cut_listing(total, rows, ts)
        blocks = [(t.spec, b"".join(units[n][2].text for n in members if units[n][1] == t.index))
                  for t in ts if any(units[n][1] == t.index for n in members)]
        data = _framed(c["reviewer"], c["framing"], c["body"],
                       _notes(ts, c["missed"], first=SLICE_HEADER.format(number, len(slices))), listing, blocks)
        if len(data) > top:
            widest = max(members, key=lambda n: len(units[n][2].text))
            raise _Refuse("slice {} of the change came out at {} bytes, above the {} a fresh thread allows; "
                          "the unit that cannot fit is {}".format(number, len(data), top,
                                                                 label(units[widest][1], units[widest][2])))
        out.append((data, [label(units[n][1], units[n][2]) for n in members]))
    return out


def _target_out(t, packet):
    return dict(t.target, packet=packet,
                delta_from=t.follows["nonce"] if t.follows is not None else None,
                history=t.history if t.kind == "delta" else None,
                plans_from=[{"path": p, "nonce": t.listed[p]["nonce"], "blob": t.listed[p]["blob"]}
                            for p in sorted(t.listed)])


def _load_turns(path):
    """`xreview-rpc thread-turns`'s JSON from a file, or None: the history is then unknown."""
    if not path:
        return None
    try:
        data = json.loads(_slurp(path).decode("utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _chars(diff):
    """What bash's ${#d} counts for a diff taken through $(...): its characters once the trailing
    newlines are gone, the bytes read as UTF-8 with each undecodable byte counting as one."""
    return len(diff.rstrip(b"\n").decode("utf-8", "surrogateescape"))


def _needed(context_now, nbytes):
    return context_now + estimate_tokens(nbytes) + RESERVE


def _limit(window):
    return int(math.floor(Fraction(str(LIMIT_FRACTION)) * Fraction(window)))


def build(request, outdir=None):
    """The decision for a request, with its packets written to outdir. The request is
        {checkpoint, body_file, reviewer_md, framing_md, cap, switches_file, codex_home,
         thread: str|null, turns_file: str|null, targets: [normalized targets], specs: [str],
         missed: [labels]}
    and the decision
        {action: send|fresh|slices|refuse, reason, kind: full|delta|slices,
         packets: [{file, shown: [labels]}], targets: [target + {packet, delta_from, history,
         plans_from}], switches}.
    A shown label is as the file list prints it (label_text), which is what the reviewer lists.
    With every switch off the packet is today's byte for byte and the cap applies as today. With
    framing on and fit off the cap still applies, to the diffs the packet carries. With fit on
    (spec 3.2): a delta or a full packet; sent on the checkpoint's thread if it fits; else on a
    fresh thread, as a full packet; else in slices. A thread whose context cannot be read counts
    as not fitting; a window that cannot be read refuses."""
    ledger = _ledger()
    sw = read_switches(request["switches_file"])
    memo = {}

    def entries_of(repo):
        if repo not in memo:
            memo[repo] = _entries(repo)
        return memo[repo]

    targets = [dict(t) for t in (request.get("targets") or [])]
    specs = [str(s) for s in (request.get("specs") or [])]
    if len(specs) != len(targets):
        raise ValueError("the request names {} targets and {} diff specs".format(len(targets), len(specs)))
    cap = int(request.get("cap") if request.get("cap") is not None else 100000)
    thread = request.get("thread") or None
    out = outdir or request.get("outdir") or tempfile.mkdtemp(prefix="xreview-packet.")
    os.makedirs(out, exist_ok=True)
    c = {"reviewer": _slurp(request["reviewer_md"]), "body": _slurp(request["body_file"]),
         "framing": _slurp(request["framing_md"]) if sw["framing"] else b"",
         "checkpoint": request.get("checkpoint"), "targets": targets, "specs": specs, "sw": sw,
         "missed": [str(x) for x in (request.get("missed") or [])], "thread": thread,
         "turns": _load_turns(request.get("turns_file")) if thread else None, "entries": entries_of}

    def write(name, data, shown):
        path = os.path.join(out, name)
        with open(path, "wb") as handle:
            handle.write(data)
        return {"file": path, "shown": shown}

    def answer(action, reason, kind, packets, tgs):
        return {"action": action, "reason": reason, "kind": kind, "packets": packets, "targets": tgs, "switches": sw}

    def plain(action, reason, packets):
        """A decision for the request's own targets, every one a full packet (framing off)."""
        return answer(action, reason, "full", packets,
                      [dict(t, packet="full", delta_from=None, history=None, plans_from=[]) for t in targets])

    def decide(action, reason, kind, packets, ts, packet=None):
        return answer(action, reason, kind, packets, [_target_out(t, packet or t.kind) for t in ts])

    def send(action, reason, kind, ts, data, shown):
        return decide(action, reason, kind, [write("packet.txt", data, shown)], ts)

    if not sw["framing"]:
        diffs = [(s, ledger.patch(t["repo"], t["base"], t["tip"])) for t, s in zip(targets, specs)]
        total = sum(_chars(d) for _s, d in diffs)
        if total > cap:
            return plain("refuse", CAP_REFUSAL.format(total, cap), [])
        return plain("send", "every switch is off: today's packet",
                     [write("packet.txt", today_packet(c["reviewer"], c["body"], diffs), [])])

    delta_ok = bool(sw["delta"] and c["checkpoint"] == "pre-merge" and thread and c["turns"] is not None)
    ts = _prepare(c, delta_ok)
    kind = "delta" if any(t.kind == "delta" for t in ts) else "full"
    if not sw["fit"]:
        total = sum(_chars(t.diff) for t in ts)
        if total > cap:
            return decide("refuse", CAP_REFUSAL_FRAMED.format(total, cap), kind, [], ts)
        data, shown = _unsliced(c, ts)
        return send("send", "the fit check is off, so the cap holds", kind, ts, data, shown)

    data, shown = _unsliced(c, ts)
    if thread:
        context, window = thread_context(request.get("codex_home"), thread)
        if context is not None and window is not None:
            detail = "need {} tokens, limit {} ({} in the context, {} bytes of packet)".format(
                _needed(context, len(data)), _limit(window), context, len(data))
            if fits(context, len(data), window):
                return send("send", "fits the review thread: " + detail, kind, ts, data, shown)
        else:
            detail = "its context or window cannot be read from its rollout"
        if kind == "delta":
            ts, kind = _prepare(c, False), "full"
            data, shown = _unsliced(c, ts)
        action = "fresh"
        lead = "the review thread cannot hold the packet ({}); moving the checkpoint to a fresh thread".format(detail)
    else:
        action, lead = "send", "a fresh thread"
    window = fresh_window(request.get("codex_home"), targets[0]["repo"] if targets else None)
    if window is None:
        return decide("refuse", "cannot read the model's context window from any Codex rollout, so the fit "
                      "of the review cannot be checked; no review was started", kind, [], ts)
    need, limit = _needed(FRESH_CONTEXT, len(data)), _limit(window)
    if fits(FRESH_CONTEXT, len(data), window):
        return send(action, "{}: need {} tokens, limit {} ({} bytes of packet)".format(
            lead, need, limit, len(data)), kind, ts, data, shown)
    try:
        parts = _slices(c, ts, window)
    except _Refuse as e:
        return decide("refuse", str(e), kind, [], ts)
    packets = [write("slice-{:03d}.txt".format(i), d, s) for i, (d, s) in enumerate(parts, 1)]
    return decide("slices", "a packet of {} bytes does not fit a fresh thread (need {} tokens, limit {}): {} slices".format(
        len(data), need, limit, len(parts)), "slices", packets, ts, packet="slices")


# ------------------------------------------------------------------ the command line
USAGE = "usage: xreview-packet.py build REQUEST.json OUTDIR | plan-blobs REPO BASE TIP"


def main(argv):
    if len(argv) == 3 and argv[0] == "build":
        try:
            with open(argv[1], "rb") as handle:
                request = json.loads(handle.read().decode("utf-8"))
            decided = build(request, argv[2])
        except Exception as e:
            print("xreview-packet: {}".format(e), file=sys.stderr)
            return 1
        print(json.dumps(decided, separators=(",", ":")))
        return 0
    if len(argv) == 4 and argv[0] == "plan-blobs":
        try:
            found = _ledger().plan_blobs(argv[1], argv[2], argv[3])
        except Exception as e:
            print("xreview-packet: {}".format(e), file=sys.stderr)
            return 1
        print(json.dumps(found, sort_keys=True, separators=(",", ":")))
        return 0
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
