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
(framing), 3.2 (the fit arithmetic), 3.3 (review units and parts) and 3.8 (switches).

This part holds the switches, the fixed framing copy, the review units of a patch and how a unit
is cut into parts, the fit arithmetic, and today's packet, byte for byte. The ledger (the patch
and its identity) is loaded from XREVIEW_LEDGER, else from beside this file.

Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
"""
import collections
import importlib.util
import math
import os
import re
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER_PATH = os.environ.get("XREVIEW_LEDGER") or os.path.join(HERE, "xreview-ledger.py")

# The fit arithmetic (spec 3.2): need = context now + ceil(bytes / 3.5) + reserve, against
# limit = 0.9 x the context window. Measured: 3.5 bytes per token, a fresh thread starts at
# ~27k tokens (30k with margin), p99 growth within a turn is 56k.
BYTES_PER_TOKEN = 3.5
LIMIT_FRACTION = 0.9
RESERVE = 60000
FRESH_CONTEXT = 30000

# The switches of packets.conf (spec 3.8), all off by default. The last three need framing.
SWITCHES = ("framing", "fit", "delta", "omit_plans")
NEEDS_FRAMING = ("fit", "delta", "omit_plans")

# The fixed framing copy (spec 3.1); reviewer-framing.md carries the same text for the reviewer.
MARKS = ("shown", "earlier", "elsewhere", "listed")
REVIEWED_FILES_TEXT = ("List in `reviewed_files` every file or part label marked shown that you "
                       "reviewed. Do not list a file you did not read.")
FILE_LIST_HEADER = "Files in this change ({}):"
FILE_LIST_LINE = "  {:<9} +{} -{}  {}"

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
    if budget <= 0:
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
