#!/usr/bin/env bash
# Tests for dot_claude/xreview-packet.py: the module that builds every xreview review packet
# (spec docs/superpowers/specs/2026-10-25-xreview-review-packets-design.md, 3.1 framing, 3.2
# fit arithmetic, 3.3 review units and parts, 3.8 switches), and the config files it ships with.
#
# K1 is the byte-for-byte oracle for "every switch off gives today's packet": golden packets in
# tests/fixtures/xreview-packet/, captured from the unmodified dispatcher by regenerate.sh there.
# Git fixtures are real repositories under $TMPDIR with a private git configuration. The checks
# run in one python3 process and print PASS:/FAIL: lines; this wrapper counts them.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="$SRC/dot_claude/xreview-packet.py"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
RPC="$SRC/dot_local/bin/executable_xreview-rpc"
FIX="$SRC/tests/fixtures/xreview-packet"
CONF="$SRC/dot_config/xreview"
for f in "$MODULE" "$LEDGER" "$RPC"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrpacket.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$ROOT"
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
  > "$GIT_CONFIG_GLOBAL"
export XREVIEW_LEDGER="$LEDGER" T_MODULE="$MODULE" T_RPC="$RPC" T_FIX="$FIX" T_CONF="$CONF" T_ROOT="$ROOT"

out="$(/usr/bin/python3 -I - <<'PY'
import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys

MODULE, RPC, FIX, CONF, ROOT = (os.environ[k] for k in
                                ("T_MODULE", "T_RPC", "T_FIX", "T_CONF", "T_ROOT"))


def ok(name, cond, got=""):
    if cond:
        print("  PASS: " + name)
    else:
        print("  FAIL: {}\n    | got: {}".format(name, str(got)[:300]))


def is_(name, got, want):
    ok(name, got == want, repr(got) + " want " + repr(want))


spec = importlib.util.spec_from_file_location("xreview_packet", MODULE)
xp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xp)


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), check=True, capture_output=True).stdout


def mkrepo(name):
    repo = os.path.join(ROOT, name)
    os.makedirs(repo)
    git(repo, "init", "-q")
    return repo


def commit(repo, msg):
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", msg)
    return git(repo, "rev-parse", "HEAD").decode().strip()


def put(repo, path, data):
    full = os.path.join(repo, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as f:
        f.write(data)


def rd(*parts):
    with open(os.path.join(*parts), "rb") as f:
        return f.read()


# ---------------------------------------------------------------- K1 today's packet
print("K1. every switch off: today_packet equals the golden packets")
reviewer = rd(FIX, "reviewer.md")
specs = {"d1": "HEAD~1..HEAD", "d2": "HEAD~2..HEAD"}
diffs = {k: rd(FIX, k + ".diff") for k in specs}
ok("K1 the golden diffs end in a newline, so the strip is exercised", all(d.endswith(b"\n") for d in diffs.values()))
for kind in ("nl", "nonl"):
    body = rd(FIX, "body-" + kind + ".md")
    is_("K1 the " + kind + " body " + ("ends" if kind == "nl" else "does not end") + " in a newline",
        body.endswith(b"\n"), kind == "nl")
    cases = {"none": [], "one": [("d1")], "two": [("d1"), ("d2")]}
    for name, keys in cases.items():
        got = xp.today_packet(reviewer, body, [(specs[k], diffs[k]) for k in keys])
        want = rd(FIX, "{}-{}.packet".format(name, kind))
        ok("K1 {} diff(s), {} body: byte-identical".format(name, kind), got == want,
           "{} bytes vs {}".format(len(got), len(want)))
ok("K1 trailing newlines of a diff are stripped as $(...) strips them",
   xp.today_packet(b"R\n", b"B\n", [("s", b"x\n\n\n")]) == xp.today_packet(b"R\n", b"B\n", [("s", b"x")]))
ok("K1 but interior blank lines stay",
   b"x\n\ny\n--- end diff ---" in xp.today_packet(b"R\n", b"B\n", [("s", b"x\n\ny\n")]))

# ---------------------------------------------------------------- K2 switches
print("K2. switches")
cfg = os.path.join(ROOT, "packets.conf")
OFF = {"framing": False, "fit": False, "delta": False, "omit_plans": False}


def sw(text):
    with open(cfg, "w") as f:
        f.write(text)
    return xp.read_switches(cfg)


is_("K2 a missing file forces all off", xp.read_switches(os.path.join(ROOT, "nope.conf")), OFF)
is_("K2 an unreadable path (a directory) forces all off", xp.read_switches(ROOT), OFF)
is_("K2 an empty file is all off", sw(""), OFF)
is_("K2 all four on", sw("framing=on\nfit=on\ndelta=on\nomit_plans=on\n"),
    {"framing": True, "fit": True, "delta": True, "omit_plans": True})
is_("K2 fit=yes is off, the rest as written", sw("framing=on\nfit=yes\ndelta=on\nomit_plans=off\n"),
    {"framing": True, "fit": False, "delta": True, "omit_plans": False})
is_("K2 framing off forces the other three off", sw("framing=off\nfit=on\ndelta=on\nomit_plans=on\n"), OFF)
is_("K2 framing missing forces the others off", sw("fit=on\ndelta=on\nomit_plans=on\n"), OFF)
is_("K2 framing=yes forces the others off", sw("framing=yes\nfit=on\n"), OFF)
is_("K2 comments, blanks, spaces and unknown keys are tolerated",
    sw("# note\n\n framing = on \nfit=on # no\nwhat=on\nomit_plans=on\n"),
    {"framing": True, "fit": False, "delta": False, "omit_plans": True})
is_("K2 the last line for a key wins", sw("framing=on\nfit=on\nfit=off\n"),
    {"framing": True, "fit": False, "delta": False, "omit_plans": False})
is_("K2 case matters: ON is not on", sw("framing=ON\n"), OFF)
is_("K2 the shipped packets.conf is the four off lines",
    rd(CONF, "packets.conf"), b"framing=off\nfit=off\ndelta=off\nomit_plans=off\n")
is_("K2 and parses to all off", xp.read_switches(os.path.join(CONF, "packets.conf")), OFF)
sw("framing=off\nfit=on\ndelta=off\nomit_plans=on\n")
is_("K2 the switches framing off ignored are reported", sorted(xp.switches_ignored(cfg)), ["fit", "omit_plans"])
sw("framing=on\nfit=on\n")
is_("K2 none are reported with framing on", xp.switches_ignored(cfg), [])

# ---------------------------------------------------------------- K3/K4 units_for
print("K3. units_for labels paths unquoted")
repo = mkrepo("units")
put(repo, "seed.txt", b"seed\n")
base = commit(repo, "seed")
put(repo, "a b.txt", b"one\ntwo\n")
put(repo, "ä.txt", b"\xc3\xa4\n")
put(repo, 'q"x.txt', b"quote\n")
put(repo, "x b/y.txt", b"dir with space b\n")
put(repo, "tab\there.txt", b"tab\n")
put(repo, "plain.txt", b"p1\np2\np3\n")
put(repo, "bin/ö.bin", b"\x00\x01\x02binary\n")
put(repo, "raw.bin", b"abc\x00def")
tip = commit(repo, "files")
units = xp.units_for(repo, base, tip)
labels = [u.label for u in units]
for want in ("a b.txt", "ä.txt", 'q"x.txt', "x b/y.txt", "tab\there.txt", "plain.txt"):
    ok("K3 label {!r} is the unquoted path".format(want), want in labels, labels)
ok("K3 no label keeps git's quoting", not any(l.startswith('"') or "\\303" in l or "\\t" in l for l in labels), labels)
by = {u.label: u for u in units}
ok("K3 unit.path equals the label of a whole file", all(u.path == u.label for u in units))
ok("K3 a text unit begins with its own diff --git header", by["plain.txt"].text.startswith(b"diff --git a/plain.txt b/plain.txt\n"))
is_("K3 plus and minus count the hunk lines, not the ---/+++ headers",
    (by["plain.txt"].plus, by["plain.txt"].minus), (3, 0))
is_("K3 plus counts for a two-line file", (by["a b.txt"].plus, by["a b.txt"].minus), (2, 0))
ok("K3 a text unit is not binary", not by["plain.txt"].binary)
ok("K3 text is bytes", all(isinstance(u.text, bytes) for u in units))
texts = [u.label for u in units if not u.binary]
is_("K3 text units come in the patch's order, which is byte order of the path", texts,
    sorted(texts, key=lambda l: l.encode("utf-8")))
whole = b"".join(u.text for u in units)
ok("K3 the units concatenate back to the ledger's patch", whole == xp._ledger().patch(repo, base, tip))
only = xp.units_for(repo, base, tip, exclude=("plain.txt",))
ok("K3 exclude leaves a path out", "plain.txt" not in [u.label for u in only] and len(only) == len(units) - 1)

print("K3b. a type change is one unit")
repo = mkrepo("typechg")
put(repo, "seed.txt", b"seed\n")
put(repo, "swap", b"one\ntwo\nthree\n")
put(repo, "after", b"x\n")
base = commit(repo, "seed")
os.remove(os.path.join(repo, "swap"))
os.symlink("seed.txt", os.path.join(repo, "swap"))
put(repo, "after", b"y\n")
tip = commit(repo, "swap file for symlink")
raw = xp._ledger().patch(repo, base, tip)
is_("K3b git renders the type change as two sections for one path",
    [l for l in raw.split(b"\n") if l.startswith(b"diff --git a/swap ")], [b"diff --git a/swap b/swap"] * 2)
tu = xp.units_for(repo, base, tip)
is_("K3b exactly one unit per path", sorted(u.label for u in tu), ["after", "swap"])
sw_ = [u for u in tu if u.label == "swap"][0]
is_("K3b it holds both headers", sw_.text.count(b"diff --git a/swap b/swap\n"), 2)
is_("K3b with the delete before the create, as git orders them",
    [b"deleted file mode" in sw_.text.split(b"diff --git")[1], b"new file mode" in sw_.text.split(b"diff --git")[2]], [True, True])
is_("K3b plus and minus are summed", (sw_.plus, sw_.minus), (1, 3))
ok("K3b the units still concatenate back to the patch", b"".join(u.text for u in tu) == raw)
parts = xp.split_unit(sw_, 150)
ok("K3b split, every part carries its own section's header and fits",
   len(parts) >= 2 and all(p.text.startswith(b"diff --git a/swap b/swap\n") and len(p.text) <= 150 for p in parts),
   [len(p.text) for p in parts])
is_("K3b and the parts' counts add up", (sum(p.plus for p in parts), sum(p.minus for p in parts)), (sw_.plus, sw_.minus))
is_("K3b labels run 1..n over both sections", [p.label for p in parts], ["swap#%d/%d" % (i + 1, len(parts)) for i in range(len(parts))])

print("K4. a binary file is one binary unit")
bins = [u for u in units if u.binary]
is_("K4 two binary units", sorted(u.label for u in bins), ["bin/ö.bin", "raw.bin"])
ok("K4 a binary unit's text is its summary line",
   all(u.text.startswith(b"Binary file ") and u.text.endswith(b"\n") and u.text.count(b"\n") == 1 for u in bins))
ok("K4 no text unit is made for a binary path", not [u for u in units if not u.binary and u.label in ("raw.bin", "bin/ö.bin")])
is_("K4 a binary unit has no plus or minus", [(u.plus, u.minus) for u in bins], [(0, 0), (0, 0)])
ok("K4 the quoted summary path is labelled unquoted", "bin/ö.bin" in [u.label for u in bins])
ok("K4 a binary unit is its own path", all(u.path == u.label for u in bins))
is_("K4 a binary unit is never split", xp.split_unit(bins[0], 10), [bins[0]])

# ---------------------------------------------------------------- K5 split_unit
print("K5. split_unit")
HEAD = b"diff --git a/f.txt b/f.txt\nindex 1111111..2222222 100644\n--- a/f.txt\n+++ b/f.txt\n"
HH = re.compile(rb"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$")


def mkunit(text, label="f.txt"):
    plus, minus, seen = 0, 0, False
    for line in text.split(b"\n"):
        if line.startswith(b"@@"):
            seen = True
        elif seen and line.startswith(b"+"):
            plus += 1
        elif seen and line.startswith(b"-"):
            minus += 1
    return xp.Unit(label, "f.txt", text, plus, minus, False)


def hunk_nums(part_text):
    """(old start, old count, new start, new count, rest) of every @@ line in a part."""
    res = []
    for line in part_text.split(b"\n"):
        m = HH.match(line)
        if m:
            a, b, c, d, rest = m.groups()
            res.append((int(a), int(b) if b is not None else 1, int(c), int(d) if d is not None else 1, rest))
    return res


def body_lines(part_text):
    """The hunk body lines of a part (everything after its first @@ line)."""
    lines = part_text.split(b"\n")
    for i, line in enumerate(lines):
        if line.startswith(b"@@"):
            return [l for l in lines[i:] if not l.startswith(b"@@")]
    return []


# --- K5a: by whole hunks
hunks = b""
old_total = new_total = 0
for i in range(6):
    start = 1 + i * 40
    lines = [b" ctx%d_a" % i, b"-gone%d" % i, b"+new%d_%s" % (i, b"x" * 150), b" ctx%d_b" % i]
    hunks += b"@@ -%d,3 +%d,3 @@\n" % (start, start) + b"\n".join(lines) + b"\n"
u = mkunit(HEAD + hunks)
mx = len(HEAD) + 2 * 200 + 20
parts = xp.split_unit(u, mx)
ok("K5a a unit that fits is returned whole", xp.split_unit(u, len(u.text)) == [u] and xp.split_unit(u, len(u.text) + 5) == [u])
ok("K5a the unit splits into several parts", len(parts) > 1, len(parts))
ok("K5a every part is at most max_bytes", all(len(p.text) <= mx for p in parts), [len(p.text) for p in parts])
ok("K5a every part carries the diff --git header", all(p.text.startswith(HEAD) for p in parts))
is_("K5a labels are <path>#<i>/<n>", [p.label for p in parts], ["f.txt#%d/%d" % (i + 1, len(parts)) for i in range(len(parts))])
ok("K5a path is kept", all(p.path == "f.txt" for p in parts))
ok("K5a no part is binary", not any(p.binary for p in parts))
ok("K5a parts concatenate back to the hunks (headers dropped)",
   b"".join(p.text[len(HEAD):] for p in parts) == hunks)
ok("K5a whole hunks only: every part starts at a hunk's @@ line and keeps it whole",
   all(p.text[len(HEAD):].startswith(b"@@ -") for p in parts))
is_("K5a plus and minus add up", (sum(p.plus for p in parts), sum(p.minus for p in parts)), (u.plus, u.minus))

# --- K5b: by line ranges within one hunk
n = 400
body = b""
for i in range(n):
    body += (b" same%04d\n" % i) if i % 3 == 0 else ((b"-old%04d\n" % i) if i % 3 == 1 else (b"+new%04d\n" % i))
old_n = sum(1 for l in body.split(b"\n") if l[:1] in (b" ", b"-"))
new_n = sum(1 for l in body.split(b"\n") if l[:1] in (b" ", b"+"))
u = mkunit(HEAD + b"@@ -17,%d +21,%d @@ def func():\n" % (old_n, new_n) + body)
mx = len(HEAD) + 600
parts = xp.split_unit(u, mx)
ok("K5b one oversized hunk splits into line ranges", len(parts) > 3, len(parts))
ok("K5b every part is at most max_bytes", all(len(p.text) <= mx for p in parts), max(len(p.text) for p in parts))
ok("K5b every part carries the header and one @@ line", all(p.text.startswith(HEAD) and len(hunk_nums(p.text)) == 1 for p in parts))
nums = [hunk_nums(p.text)[0] for p in parts]
is_("K5b the old counts re-add up to the original", sum(x[1] for x in nums), old_n)
is_("K5b the new counts re-add up to the original", sum(x[3] for x in nums), new_n)
ok("K5b the first part starts where the original did", (nums[0][0], nums[0][2]) == (17, 21), nums[0])
ok("K5b each part starts where the previous one ended",
   all(nums[i + 1][0] == nums[i][0] + nums[i][1] and nums[i + 1][2] == nums[i][2] + nums[i][3] for i in range(len(nums) - 1)),
   nums[:3])
ok("K5b a part's counts match its own body lines",
   all(sum(1 for l in body_lines(p.text) if l[:1] in (b" ", b"-")) == hunk_nums(p.text)[0][1] and
       sum(1 for l in body_lines(p.text) if l[:1] in (b" ", b"+")) == hunk_nums(p.text)[0][3] for p in parts))
ok("K5b the parts concatenate back to the original lines",
   b"\n".join(b"\n".join(l for l in body_lines(p.text) if l != b"") for p in parts) + b"\n" == body)
is_("K5b the function heading stays on the first part only", [bool(x[4].strip()) for x in nums], [True] + [False] * (len(nums) - 1))
is_("K5b plus and minus add up", (sum(p.plus for p in parts), sum(p.minus for p in parts)), (u.plus, u.minus))
is_("K5b labels run 1..n", [p.label for p in parts], ["f.txt#%d/%d" % (i + 1, len(parts)) for i in range(len(parts))])

# whole-file add: counts of zero keep git's start-minus-one convention
add = b"".join(b"+line%03d\n" % i for i in range(200))
u = mkunit(HEAD + b"@@ -0,0 +1,200 @@\n" + add)
parts = xp.split_unit(u, len(HEAD) + 700)
nums = [hunk_nums(p.text)[0] for p in parts]
ok("K5b a whole-file add splits with zero old counts and old start 0", all(x[0] == 0 and x[1] == 0 for x in nums), nums[:2])
ok("K5b and its new starts run on", nums[0][2] == 1 and all(nums[i + 1][2] == nums[i][2] + nums[i][3] for i in range(len(nums) - 1)))
is_("K5b new counts re-add to 200", sum(x[3] for x in nums), 200)

# a "\ No newline" marker stays with its line
marked = b"".join(b"+row%03d\n" % i for i in range(60)) + b"\\ No newline at end of file\n"
u = mkunit(HEAD + b"@@ -0,0 +1,60 @@\n" + marked)
bad = False
for mxx in range(len(HEAD) + 80, len(HEAD) + 400, 7):
    ps = xp.split_unit(u, mxx)
    for p in ps:
        bl = body_lines(p.text)
        if bl and bl[0].startswith(b"\\"):
            bad = True
        if len(p.text) > mxx:
            bad = True
    if b"".join(p.text[len(HEAD):].split(b"\n", 1)[1] for p in ps) != marked:
        bad = True
ok("K5b the no-newline marker never starts a part, and nothing is lost, at every size", not bad)

# --- K5c: a 2 MB single line, split at UTF-8 boundaries
unit_chars = "aé€\U0001F600"          # 1, 2, 3 and 4 bytes
line = (unit_chars * (2_000_000 // len(unit_chars.encode()))).encode()
ok("K5c the line is about 2 MB", len(line) >= 1_990_000, len(line))
for lead, kind in ((b"+", "added"), (b"-", "removed"), (b" ", "context")):
    old_c = 0 if lead == b"+" else 1
    new_c = 0 if lead == b"-" else 1
    text = HEAD + b"@@ -7,%d +9,%d @@\n" % (old_c, new_c) + lead + line + b"\n\\ No newline at end of file\n"
    u = mkunit(text)
    mx = 100_000
    parts = xp.split_unit(u, mx)
    ok("K5c {}: every part is at most max_bytes".format(kind), all(len(p.text) <= mx for p in parts), max(len(p.text) for p in parts))
    ok("K5c {}: there are about 2 MB / max_bytes parts".format(kind), 20 <= len(parts) <= 24, len(parts))
    chunks, prefixes = [], set()
    for p in parts:
        rest = p.text[len(HEAD):]
        first, _, tail = rest.partition(b"\n")
        chunk = tail.split(b"\n", 1)[0]
        prefixes.add(chunk[:1])
        chunks.append(chunk[1:])
    is_("K5c {}: every part's body line keeps the {!r} prefix".format(kind, lead), prefixes, {lead})
    try:
        for c in chunks:
            c.decode("utf-8")
        valid = True
    except UnicodeDecodeError:
        valid = False
    ok("K5c {}: every chunk is valid UTF-8 on its own".format(kind), valid)
    ok("K5c {}: the chunks concatenate back to the original line".format(kind), b"".join(chunks) == line)
    first = parts[0].text[len(HEAD):].split(b"\n", 1)[0].decode("utf-8")
    ok("K5c {}: the @@ line names the line and the bytes".format(kind),
       re.search(r"line (9|7), bytes 1–\d+ of {}$".format(len(line)), first) is not None, first)
    ok("K5c {}: the marker is kept on the last part only".format(kind),
       parts[-1].text.endswith(b"\\ No newline at end of file\n") and not any(b"No newline" in p.text for p in parts[:-1]))
    heads = [hunk_nums(p.text)[0] for p in parts]
    ok("K5c {}: every part keeps the line's own number".format(kind), len({(h[0], h[2]) for h in heads}) == 1, heads[:2])
    ok("K5c {}: labels run 1..n".format(kind), [p.label for p in parts] == ["f.txt#%d/%d" % (i + 1, len(parts)) for i in range(len(parts))])
# a cut that would land inside a continuation byte backs up (4-byte characters, odd budget)
emoji = ("\U0001F600" * 5000).encode()
u = mkunit(HEAD + b"@@ -0,0 +1 @@\n+" + emoji + b"\n")
clean = True
for mxx in range(len(HEAD) + 80, len(HEAD) + 140):
    ps = xp.split_unit(u, mxx)
    cs = [p.text[len(HEAD):].split(b"\n")[1][1:] for p in ps]
    try:
        for c in cs:
            c.decode("utf-8")
    except UnicodeDecodeError:
        clean = False
    if b"".join(cs) != emoji or any(len(p.text) > mxx for p in ps):
        clean = False
ok("K5c at every budget from 80 to 140 a 4-byte character is never cut in two", clean)

# --- K5d: a mix: small hunks, one giant hunk, one giant line, in order
mixed = (b"@@ -1,2 +1,2 @@\n-a\n+b\n"
         + b"@@ -50,%d +50,%d @@\n" % (0, 300) + b"".join(b"+g%03d\n" % i for i in range(300))
         + b"@@ -900 +1000 @@\n-" + b"y" * 5000 + b"\n+" + b"z" * 5000 + b"\n")
u = mkunit(HEAD + mixed)
mx = len(HEAD) + 1500
parts = xp.split_unit(u, mx)
ok("K5d hunks, line ranges and byte ranges mix, every part within max_bytes", all(len(p.text) <= mx for p in parts) and len(parts) > 5)
ok("K5d plus and minus add up", (sum(p.plus for p in parts), sum(p.minus for p in parts)) == (u.plus, u.minus),
   [(p.plus, p.minus) for p in parts])
try:
    xp.split_unit(u, len(HEAD) + 10)
    raised = False
except ValueError:
    raised = True
ok("K5d a max_bytes too small to hold even a few bytes is a ValueError", raised)

# ---------------------------------------------------------------- K6 fits
print("K6. fits at the exact boundary")
ok("K6 the constants are the spec's", (xp.BYTES_PER_TOKEN, xp.LIMIT_FRACTION, xp.RESERVE) == (3.5, 0.9, 60000))
is_("K6 estimate_tokens(0)", xp.estimate_tokens(0), 0)
is_("K6 estimate_tokens(7) is exactly 2", xp.estimate_tokens(7), 2)
is_("K6 estimate_tokens(8) rounds up to 3", xp.estimate_tokens(8), 3)
is_("K6 estimate_tokens(1) is 1", xp.estimate_tokens(1), 1)
is_("K6 estimate_tokens(3500000) is 1000000", xp.estimate_tokens(3500000), 1000000)
window, ctx = 1_000_000, 100_000
room = 900_000 - ctx - xp.RESERVE                      # tokens the packet may take
edge = int(room * 3.5)
is_("K6 the edge is a whole number of tokens", xp.estimate_tokens(edge), room)
ok("K6 true at equality", xp.fits(ctx, edge, window) is True)
ok("K6 false one byte over", xp.fits(ctx, edge + 1, window) is False)
ok("K6 true one byte under", xp.fits(ctx, edge - 1, window) is True)
ok("K6 context one token higher moves the edge", xp.fits(ctx + 1, edge, window) is False)
ok("K6 a window one token short fails at the same size", xp.fits(ctx, edge, 999_999) is False)
ok("K6 an odd window is exact too (0.9 x 258400 = 232560)", xp.fits(0, int((232560 - 60000) * 3.5), 258400) is True and
   xp.fits(0, int((232560 - 60000) * 3.5) + 1, 258400) is False)

# ---------------------------------------------------------------- K7 framed schema
print("K7. the framed schema and the framing copy")
loader = importlib.machinery.SourceFileLoader("xreview_rpc", RPC)
rpc_spec = importlib.util.spec_from_loader("xreview_rpc", loader)
rpc = importlib.util.module_from_spec(rpc_spec)
loader.exec_module(rpc)
framed = json.loads(rd(CONF, "findings.framed.schema.json"))
today = json.loads(rd(CONF, "findings.schema.json"))
good = {"verdict": "approve", "findings": [], "reviewed_files": ["a.txt", "f.txt#1/2"]}
is_("K7 a full answer validates", rpc.validate(good, framed), [])
is_("K7 an empty reviewed_files validates", rpc.validate(dict(good, reviewed_files=[]), framed), [])
nofiles = {"verdict": "approve", "findings": []}
ok("K7 reviewed_files is required", "$: missing reviewed_files" in rpc.validate(nofiles, framed), rpc.validate(nofiles, framed))
ok("K7 reviewed_files must be an array", rpc.validate(dict(good, reviewed_files="a.txt"), framed) != [])
ok("K7 and of strings", rpc.validate(dict(good, reviewed_files=["a", 3]), framed) != [])
ok("K7 the old schema rejects reviewed_files", rpc.validate(good, today) != [])
ok("K7 and accepts the answer without it", rpc.validate(nofiles, today) == [])
f2 = json.loads(json.dumps(framed))
del f2["properties"]["reviewed_files"]
f2["required"].remove("reviewed_files")
is_("K7 otherwise the framed schema is today's schema", f2, today)
is_("K7 reviewed_files is the only addition", framed["required"], today["required"] + ["reviewed_files"])
ok("K7 additionalProperties stays false", framed["additionalProperties"] is False)

framing = rd(CONF, "reviewer-framing.md").decode()
is_("K7 the instruction text is the spec's",
    xp.REVIEWED_FILES_TEXT,
    "List in `reviewed_files` every file or part label marked shown that you reviewed. Do not list a file you did not read.")
ok("K7 reviewer-framing.md holds it", xp.REVIEWED_FILES_TEXT in framing)
is_("K7 the marks", xp.MARKS, ("shown", "earlier", "elsewhere", "listed"))
ok("K7 reviewer-framing.md names every mark", all("- " + m + ":" in framing for m in xp.MARKS))
ok("K7 and the file list header and part labels", "Files in this change (<n>):" in framing and "<path>#<i>/<n>" in framing)
ok("K7 the existing reviewer.md is untouched", rd(FIX, "reviewer.md") == rd(CONF, "reviewer.md"))

# ---------------------------------------------------------------- file_list
print("K8. file_list")
is_("K8 header only", xp.file_list([]), "Files in this change (0):\n")
got = xp.file_list([("shown", 12, 3, "src/a.py"), ("earlier", 0, 40, "docs/b b.md"), ("elsewhere", 1, 1, "c.txt#2/3"),
                    ("listed", 100, 0, "docs/superpowers/plans/p.md")])
want = ("Files in this change (4):\n"
        "  shown     +12 -3  src/a.py\n"
        "  earlier   +0 -40  docs/b b.md\n"
        "  elsewhere +1 -1  c.txt#2/3\n"
        "  listed    +100 -0  docs/superpowers/plans/p.md\n")
is_("K8 the fixed format: two spaces, the mark padded to 9, +plus -minus, two spaces, the label", got, want)
ok("K8 every line is 9 wide before the counts", all(l[2:11].rstrip() in xp.MARKS for l in got.splitlines()[1:]))

# ---------------------------------------------------------------- loading
print("K9. the ledger is loaded from XREVIEW_LEDGER, else beside the module")
ok("K9 the module reads XREVIEW_LEDGER", os.path.realpath(xp.LEDGER_PATH) == os.path.realpath(os.environ["XREVIEW_LEDGER"]))
ok("K9 and exposes the ledger's patch", callable(getattr(xp._ledger(), "patch", None)))
alt = subprocess.run(["/usr/bin/python3", "-I", "-c",
                      "import importlib.util as u; s=u.spec_from_file_location('m', %r); m=u.module_from_spec(s); "
                      "s.loader.exec_module(m); print(m.LEDGER_PATH)" % MODULE],
                     capture_output=True, text=True, env={k: v for k, v in os.environ.items() if k != "XREVIEW_LEDGER"}).stdout.strip()
is_("K9 without it the ledger is beside the module", alt, os.path.join(os.path.dirname(MODULE), "xreview-ledger.py"))
PY
)"
rc=$?
printf '%s\n' "$out"
pass=$(printf '%s\n' "$out" | grep -c '^  PASS:')
fail=$(printf '%s\n' "$out" | grep -c '^  FAIL:')
if [ "$rc" -ne 0 ]; then fail=$((fail + 1)); echo "  FAIL: the python checks died (exit $rc)"; fi
printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
