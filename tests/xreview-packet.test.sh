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
for f in "$MODULE" "$LEDGER" "$RPC" "$FIX/reviewer.md" "$FIX/body-nl.md" "$FIX/body-nonl.md" \
         "$FIX/d1.patch" "$FIX/d2.patch" "$FIX"/{none,one,two}-{nl,nonl}.packet \
         "$CONF/packets.conf" "$CONF/findings.schema.json" "$CONF/findings.framed.schema.json" \
         "$CONF/reviewer.md" "$CONF/reviewer-framing.md"; do
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
diffs = {k: rd(FIX, k + ".patch") for k in specs}
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
is_("K2 the shipped packets.conf turns on what passed the replay (spec 9)",
    rd(CONF, "packets.conf"), b"framing=on\nfit=off\ndelta=off\nomit_plans=on\n")
is_("K2 and parses to it", xp.read_switches(os.path.join(CONF, "packets.conf")),
    {"framing": True, "fit": False, "delta": False, "omit_plans": True})
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

print("K3c. header paths do not depend on the diff prefix configuration")
repo = mkrepo("noprefix")
git(repo, "config", "diff.noprefix", "true")
git(repo, "config", "diff.mnemonicPrefix", "true")
put(repo, "seed.txt", b"seed\n")
base = commit(repo, "seed")
put(repo, "a.txt", b"one\n")
put(repo, "d/\u00e4 b.txt", b"two\n")
tip = commit(repo, "add")
raw = xp._ledger().patch(repo, base, tip, prefixed=True)
is_("K3c with diff.noprefix and mnemonicPrefix set the headers still say a/ and b/",
    [l for l in raw.split(b"\n") if l.startswith(b"diff --git ")],
    [b"diff --git a/a.txt b/a.txt", b'diff --git "a/d/\\303\\244 b.txt" "b/d/\\303\\244 b.txt"'])
is_("K3c and the labels are the plain paths", [u.label for u in xp.units_for(repo, base, tip)], ["a.txt", "d/\u00e4 b.txt"])

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
# Under 4 bytes of room a range cannot hold a 4-byte character: a ValueError, never a cut inside one.
u = mkunit(HEAD + b"@@ -0,0 +1 @@\n+" + ("\U0001F600" * 50).encode() + b"\n")
outcomes = {}
for mxx in range(len(HEAD) + 1, len(HEAD) + 120):
    try:
        ps = xp.split_unit(u, mxx)
    except ValueError:
        outcomes[mxx] = "raise"
        continue
    cs = [p.text[len(HEAD):].split(b"\n")[1][1:] for p in ps]
    try:
        for c in cs:
            c.decode("utf-8")
        outcomes[mxx] = "whole" if len(ps) == 1 else ("%d-byte" % len(cs[0]) if len(set(map(len, cs))) == 1 else "mixed")
    except UnicodeDecodeError:
        outcomes[mxx] = "cut"
first = min((m for m, o in outcomes.items() if o != "raise"), default=None)
ok("K5c a budget under 4 bytes is a ValueError, never a cut inside a character",
   "cut" not in outcomes.values() and first is not None and outcomes[first] == "4-byte",
   sorted(set(outcomes.values())))

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



# ================================================================ Task 5: context, delta, plans, slices, build
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "state")
LD = xp._ledger()
SCR = [0]


def guarded(name):
    def deco(fn):
        try:
            fn()
        except Exception:
            import traceback
            ok(name + " ran without raising", False, traceback.format_exc()[-700:])
    return deco


def wr(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    return path


def swf(**on):
    SCR[0] += 1
    text = "".join("{}={}\n".format(n, "on" if on.get(n) else "off") for n in ("framing", "fit", "delta", "omit_plans"))
    return wr(os.path.join(ROOT, "sw-{}.conf".format(SCR[0])), text)


def rollout(home, thread, ctx, win, archived=False, stamp="2026-10-25T10-00-00", compressed=False):
    sub = "archived_sessions" if archived else os.path.join("sessions", "2026", "10", "25")
    path = os.path.join(home, sub, "rollout-{}-{}.jsonl".format(stamp, thread))
    recs = [{"type": "session_meta", "payload": {"id": thread}},
            {"type": "event_msg", "payload": {"type": "task_started", "model_context_window": win}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": None}}]
    if ctx is not None:
        recs.append({"type": "event_msg", "payload": {"type": "token_count", "info": {
            "total_token_usage": {"total_tokens": ctx * 3},
            "last_token_usage": {"total_tokens": ctx}, "model_context_window": win}}})
    text = "".join(json.dumps(r) + "\n" for r in recs)
    if not compressed:
        wr(path, text)
        return path
    plain = wr(os.path.join(ROOT, "plain-{}-{}.jsonl".format(stamp, thread)), text)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    subprocess.run(["zstd", "-q", "-f", "-o", path + ".zst", plain], check=True)
    return path + ".zst"


def mkhome(name):
    home = os.path.join(ROOT, "codex-" + name)
    os.makedirs(home, exist_ok=True)
    return home


def target_of(repo, base, tip, dest="main", rng="main...HEAD"):
    return {"repo": LD.common_dir(repo), "dest": dest, "dest_ref": dest, "branch": "feat", "range": rng,
            "base": base, "tip": tip, "full": True, "fingerprint": LD.fingerprint(repo, base, tip)}


AT = [0]


def rc(nonce, thread, turn, tgt, packet="full", clean=True, checkpoint="pre-merge", delta_from=None,
       history=None, plans_from=None, verdict="approve", plan_blobs=None, compacted=False):
    AT[0] += 1
    t = dict(tgt, packet=packet, missing=[], delta_from=delta_from, history=history,
             plans_from=[] if plans_from is None else plans_from)
    if plan_blobs is not None:
        t["plan_blobs"] = plan_blobs
    return {"v": 2, "kind": "receipt", "nonce": nonce,
            "dispatched_at": "2026-10-25T10:{:02d}:{:02d}.000000Z".format(AT[0] // 60, AT[0] % 60),
            "checkpoint": checkpoint, "verdict": verdict, "findings": 0, "thread": thread, "turn": turn,
            "tier": "", "switches": {"framing": True, "fit": True, "delta": True, "omit_plans": True},
            "compacted": compacted, "clean": clean, "targets": [t]}


def tns(ids, **kw):
    comp = kw.get("comp", 0)
    bad = kw.get("bad", {})
    return {"turns": [{"id": i, "status": "completed", "compacted": bad.get(i, False)} for i in ids],
            "thread_compactions": comp}


def put_ledger(repo, *entries):
    common = LD.common_dir(repo)
    for e in entries:
        LD.append(common, e)


def request(repo_targets, specs, **kw):
    SCR[0] += 1
    req = {"checkpoint": "pre-merge", "body_file": wr(os.path.join(ROOT, "body-{}.md".format(SCR[0])), b"Review this.\n"),
           "reviewer_md": os.path.join(FIX, "reviewer.md"), "framing_md": os.path.join(CONF, "reviewer-framing.md"),
           "cap": 100000, "switches_file": swf(), "codex_home": mkhome("none"), "thread": None, "turns_file": None,
           "targets": repo_targets, "specs": specs, "missed": []}
    req.update(kw)
    return req


def outdir():
    SCR[0] += 1
    return os.path.join(ROOT, "out-{}".format(SCR[0]))


def built(req):
    return xp.build(req, outdir())


def pkt(dec, i=0):
    return rd(dec["packets"][i]["file"])


def mkchange(name, files):
    repo = mkrepo(name)
    put(repo, "seed.txt", b"seed\n")
    base = commit(repo, "seed")
    for path, data in files.items():
        put(repo, path, data)
    tip = commit(repo, "change")
    return repo, base, tip


DELTA = ("This round follows {} on this thread. The change as of that round is earlier in this thread; "
         "below is what changed since. Judge the change as it now stands, including how the new code meets the old.")
SLICE = "This is slice {} of {} of one change. The other slices are reviewed in their own turns. Open any file you need."
LISTED = "{} was shown whole in the approved plan review {}; only its changes since then are shown here."
MISSED = "The last round's reviewed_files did not list: {}. Review them too."
CAP_TEXT = ("the diffs are too large to carry inline ({} bytes, cap {}).\n"
            "Review them in slices, or raise XREVIEW_MAX_DIFF_BYTES if the reviewer can hold it.")
CAP_FRAMED = "the diffs are too large to carry inline ({} bytes, cap {}). The cap is Michael's to raise; no review was started."
NO_DIFFS = "This review carries no diffs, so there is no file list; return reviewed_files as an empty list."
HAVE_ZSTD = __import__("shutil").which("zstd") is not None


def skip_zstd(name):
    """A case that needs zstd, when it is not installed: said once, and counted as neither a pass nor a fail."""
    print("  SKIP: zstd not installed ({})".format(name))

# ---------------------------------------------------------------- R1 rollout records
print("R1. thread_context and fresh_window read the rollout records")


@guarded("R1")
def _r1():
    home = mkhome("r1")
    rollout(home, "th-aaa", 123456, 258400)
    is_("R1 context now and window from the latest token_count", xp.thread_context(home, "th-aaa"), (123456, 258400))
    p = rollout(home, "th-bbb", 1000, 200000)
    with open(p, "a") as f:
        f.write(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {
            "last_token_usage": {"total_tokens": 2222}, "model_context_window": 258400}}}) + "\n")
        f.write(json.dumps({"type": "response_item", "payload": {"type": "token_count", "info": {
            "last_token_usage": {"total_tokens": 9}, "model_context_window": 1}}}) + "\n")
        f.write("not json at all token_count\n")
    is_("R1 the latest token_count wins, other record types and damaged lines are skipped",
        xp.thread_context(home, "th-bbb"), (2222, 258400))
    rollout(home, "th-arc", 777, 258400, archived=True)
    is_("R1 an archived thread is found under archived_sessions", xp.thread_context(home, "th-arc"), (777, 258400))
    is_("R1 a thread with no rollout is (None, None)", xp.thread_context(home, "th-none"), (None, None))
    is_("R1 a thread id is never a glob", xp.thread_context(home, "*"), (None, None))
    wr(os.path.join(home, "sessions", "2026", "10", "25", "rollout-2026-10-25T11-00-00-th-junk.jsonl"), "garbage\n{\n")
    is_("R1 an unreadable rollout is (None, None)", xp.thread_context(home, "th-junk"), (None, None))
    rollout(home, "th-new", None, 100000)
    is_("R1 a thread that never ran has a window but no context", xp.thread_context(home, "th-new"), (None, 100000))
    wr(os.path.join(home, "sessions", "2026", "10", "25", "rollout-2026-10-25T11-00-00-th-bad.jsonl"),
       json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {
           "last_token_usage": {"total_tokens": "7"}, "model_context_window": True}}}) + "\n")
    is_("R1 a value that is not a whole number is unreadable", xp.thread_context(home, "th-bad"), (None, None))
    old = os.environ.get("CODEX_HOME")
    os.environ["CODEX_HOME"] = home
    is_("R1 CODEX_HOME is honoured when no home is passed", xp.thread_context(None, "th-aaa"), (123456, 258400))
    if old is None:
        del os.environ["CODEX_HOME"]
    else:
        os.environ["CODEX_HOME"] = old
    # fresh_window: this repository's review threads first, then any rollout
    repo = mkrepo("r1repo")
    put(repo, "s", b"s\n")
    base = commit(repo, "s")
    put(repo, "x", b"x\n")
    tip = commit(repo, "x")
    home2 = mkhome("r1b")
    rollout(home2, "th-other", 5, 300000, stamp="2026-10-25T23-00-00")
    rollout(home2, "th-mine", 5, 120000, stamp="2026-10-25T01-00-00")
    tgt = target_of(repo, base, tip)
    put_ledger(repo, rc("xr-m", "th-mine", "tu", tgt))
    is_("R1 fresh_window prefers this repository's review thread", xp.fresh_window(home2, tgt["repo"]), 120000)
    is_("R1 else any rollout (the newest)", xp.fresh_window(home2, os.path.join(ROOT, "no-such-common")), 300000)
    is_("R1 and None when nothing can be read", xp.fresh_window(mkhome("empty"), tgt["repo"]), None)


# ---------------------------------------------------------------- R1z compressed rollouts
print("R1z. a rollout Codex compressed to .jsonl.zst is read the same")


@guarded("R1z")
def _r1z():
    import shutil
    if not HAVE_ZSTD:
        skip_zstd("R1z")
        return
    home = mkhome("r1z")
    rollout(home, "th-zz1", 4242, 258400, compressed=True)
    rollout(home, "th-zz1p", 4242, 258400)
    is_("R1z a thread whose only rollout is .jsonl.zst gives what the plain one does",
        xp.thread_context(home, "th-zz1"), xp.thread_context(home, "th-zz1p"))
    is_("R1z that is the records' values", xp.thread_context(home, "th-zz1"), (4242, 258400))
    rollout(home, "th-zarc", 555, 200000, archived=True, compressed=True)
    is_("R1z an archived .jsonl.zst is found", xp.thread_context(home, "th-zarc"), (555, 200000))
    is_("R1z a thread id is still anchored at the name's end", xp.thread_context(home, "zz1"), (None, None))
    # the newest of both kinds wins, whichever kind it is
    for newer_zst in (True, False):
        th = "th-mix-{}".format("z" if newer_zst else "p")
        old = rollout(home, th, 111, 258400, stamp="2026-10-25T09-00-00", compressed=not newer_zst)
        new = rollout(home, th, 222, 258400, stamp="2026-10-25T09-30-00", compressed=newer_zst)
        os.utime(old, (1000000, 1000000))
        os.utime(new, (2000000, 2000000))
        is_("R1z a newer {} beats an older {}".format(*(("zst", "plain") if newer_zst else ("plain", "zst"))),
            xp.thread_context(home, th), (222, 258400))
    # a corrupt .zst is unreadable, and no partial values come from a stream that fails
    bad = os.path.join(home, "sessions", "2026", "10", "25", "rollout-2026-10-25T11-00-00-th-zbad.jsonl.zst")
    wr(bad, b"this is not zstd data\n" + json.dumps({"type": "event_msg", "payload": {"type": "task_started", "model_context_window": 9}}).encode() + b"\n")
    is_("R1z a corrupt .zst gives (None, None)", xp.thread_context(home, "th-zbad"), (None, None))
    good = rollout(home, "th-ztrunc", 321, 258400, compressed=True)
    with open(good, "rb") as f:
        whole = f.read()
    with open(good, "wb") as f:
        f.write(whole[:-6])
    is_("R1z a truncated stream gives (None, None), not the records read before it broke",
        xp.thread_context(home, "th-ztrunc"), (None, None))
    # zstd absent
    real = shutil.which
    shutil.which = lambda name, *a, **k: None if name == "zstd" else real(name, *a, **k)
    try:
        is_("R1z with zstd absent a .zst-only thread gives (None, None)", xp.thread_context(home, "th-zz1"), (None, None))
        is_("R1z and a plain rollout is read as before", xp.thread_context(home, "th-zz1p"), (4242, 258400))
    finally:
        shutil.which = real
    # a binary that fails to start
    shutil.which = lambda name, *a, **k: os.path.join(ROOT, "no-such-zstd") if name == "zstd" else real(name, *a, **k)
    try:
        is_("R1z a zstd that fails to start gives (None, None)", xp.thread_context(home, "th-zz1"), (None, None))
    finally:
        shutil.which = real
    # fresh_window's fallback reads a .zst-only home
    zhome = mkhome("r1z-only")
    rollout(zhome, "th-only", 9, 187000, compressed=True, stamp="2026-10-25T05-00-00")
    is_("R1z fresh_window's fallback reads the window from a .zst-only home", xp.fresh_window(zhome, None), 187000)
    rollout(zhome, "th-only2", 9, 199000, compressed=True, stamp="2026-10-25T06-00-00")
    is_("R1z and takes the newest by name across them", xp.fresh_window(zhome, None), 199000)


@guarded("R1za")
def _r1za():
    # zstd is told where its options end, whatever the path: no zstd needed, the start is recorded.
    import io
    import shutil
    path = wr(os.path.join(ROOT, "r1za", "-rollout-2026-10-25T00-00-00-th-dash.jsonl.zst"), b"")
    seen = []

    class Proc(object):
        def __init__(self, argv, **_kw):
            seen.append(argv)
            self.stdout = io.BytesIO(b"")

        def wait(self):
            return 0
    real_popen, real_which = xp.subprocess.Popen, shutil.which
    xp.subprocess.Popen = Proc
    shutil.which = lambda name, *a, **k: "/zstd" if name == "zstd" else real_which(name, *a, **k)
    try:
        xp._rollout_values(path)
    finally:
        xp.subprocess.Popen, shutil.which = real_popen, real_which
    is_("R1za zstd gets -- before the rollout's path", seen, [["/zstd", "-dc", "--", path]])


# ---------------------------------------------------------------- C1-C6 delta eligibility
print("C. delta_base applies spec 3.4 in order")
crepo = mkrepo("crepo")
put(crepo, "s.txt", b"seed\n")
CB = commit(crepo, "seed")
put(crepo, "a.txt", b"one\n")
CT1 = commit(crepo, "t1")
put(crepo, "a.txt", b"one\ntwo\n")
CT2 = commit(crepo, "t2")
put(crepo, "a.txt", b"one\ntwo\nthree\n")
CT3 = commit(crepo, "t3")
git(crepo, "checkout", "-q", "-b", "side", CB)
put(crepo, "side.txt", b"side\n")
CS = commit(crepo, "side")
git(crepo, "checkout", "-q", "main")
TH = "th-delta"


def ct(tip, **kw):
    return dict(target_of(crepo, CB, tip), **kw)


@guarded("C")
def _c():
    r1 = rc("xr-1", TH, "tu-1", ct(CT1))
    got = xp.delta_base([r1], TH, ct(CT2), tns(["tu-1"]))
    ok("C0 a clean full receipt on the thread, same base, ancestor tip, history intact: its receipt", got is not None and got["nonce"] == "xr-1", got)
    ok("C0 a thread with no receipt gives none", xp.delta_base([r1], "th-other", ct(CT2), tns(["tu-1"])) is None)
    ok("C0 a missing thread gives none", xp.delta_base([r1], None, ct(CT2), tns(["tu-1"])) is None)
    ok("C0 unknown history (no turns) gives none", xp.delta_base([r1], TH, ct(CT2), None) is None)
    ok("C0 a partial target gives none", xp.delta_base([r1], TH, ct(CT2, full=False), tns(["tu-1"])) is None)
    ok("C0 another destination gives none", xp.delta_base([r1], TH, ct(CT2, dest="develop"), tns(["tu-1"])) is None)
    # C1: the base moved
    ok("C1 a different base gives none", xp.delta_base([r1], TH, dict(ct(CT2), base=CT1), tns(["tu-1"])) is None)
    # C2: the old tip is not an ancestor of the new tip
    ok("C2 a tip that is not a descendant gives none", xp.delta_base([r1], TH, ct(CS), tns(["tu-1"])) is None)
    ok("C2 an unknown commit gives none", xp.delta_base([r1], TH, dict(ct(CT2), tip="0" * 40), tns(["tu-1"])) is None)
    # C3: clean, all the way to the root
    ok("C3 an unclean receipt gives none", xp.delta_base([rc("xr-1", TH, "tu-1", ct(CT1), clean=False)], TH, ct(CT2), tns(["tu-1"])) is None)
    ok("C3 a receipt with no clean field gives none", xp.delta_base([dict((k, v) for k, v in r1.items() if k != "clean")], TH, ct(CT2), tns(["tu-1"])) is None)
    d2 = rc("xr-2", TH, "tu-2", ct(CT2), packet="delta", delta_from="xr-1", history=["tu-1"])
    ids = ["tu-1", "tu-2"]
    got = xp.delta_base([r1, d2], TH, ct(CT3), tns(ids))
    ok("C3 a chain of two follows the newest receipt", got is not None and got["nonce"] == "xr-2", got)
    ok("C3 an unclean middle link gives none", xp.delta_base([r1, rc("xr-2", TH, "tu-2", ct(CT2), packet="delta", delta_from="xr-1", history=["tu-1"], clean=False)], TH, ct(CT3), tns(ids)) is None)
    ok("C3 an unclean root gives none", xp.delta_base([rc("xr-1", TH, "tu-1", ct(CT1), clean=False), d2], TH, ct(CT3), tns(ids)) is None)
    ok("C3 a link that found changes is still a link (a changes verdict)",
       xp.delta_base([r1, rc("xr-2", TH, "tu-2", ct(CT2), packet="delta", delta_from="xr-1", history=["tu-1"], verdict="changes")], TH, ct(CT3), tns(ids)) is not None)
    # C4: the root is a full packet on this thread
    ok("C4 a sliced root gives none", xp.delta_base([rc("xr-1", TH, "tu-1", ct(CT1), packet="slices")], TH, ct(CT2), tns(["tu-1"])) is None)
    ok("C4 a chain whose root is sliced gives none", xp.delta_base([rc("xr-1", TH, "tu-1", ct(CT1), packet="slices"), d2], TH, ct(CT3), tns(ids)) is None)
    legacy = rc("xr-1", TH, "tu-1", ct(CT1))
    del legacy["targets"][0]["packet"]
    ok("C4 a receipt from before packets (no packet field) gives none", xp.delta_base([legacy], TH, ct(CT2), tns(["tu-1"])) is None)
    ok("C4 a chain that runs off the ledger gives none", xp.delta_base([d2], TH, ct(CT3), tns(ids)) is None)
    other = dict(r1, thread="th-else")
    ok("C4 a root on another thread gives none", xp.delta_base([other, d2], TH, ct(CT3), tns(ids)) is None)
    ok("C4 a plan receipt as the latest on the thread gives none", xp.delta_base([r1, rc("xr-p", TH, "tu-p", ct(CT2), checkpoint="plan")], TH, ct(CT3), tns(["tu-1", "tu-p"])) is None)
    loop = rc("xr-1", TH, "tu-1", ct(CT1), packet="delta", delta_from="xr-2", history=["tu-2"])
    ok("C4 a cycle gives none", xp.delta_base([loop, d2], TH, ct(CT3), tns(ids)) is None)
    two = rc("xr-1", TH, "tu-1", ct(CT1))
    two["targets"].append(dict(two["targets"][0]))
    ok("C4 a receipt with two identical targets is ambiguous: none", xp.delta_base([two], TH, ct(CT2), tns(["tu-1"])) is None)
    # C5: the thread still holds the chain
    ok("C5 a chain turn missing from the thread gives none", xp.delta_base([r1, d2], TH, ct(CT3), tns(["tu-1"])) is None)
    ok("C5 a root turn missing from the thread gives none", xp.delta_base([r1], TH, ct(CT2), tns(["tu-x"])) is None)
    ok("C5 chain turns out of order give none", xp.delta_base([r1, d2], TH, ct(CT3), tns(["tu-2", "tu-1"])) is None)
    ok("C5 other turns between and after the chain are fine", xp.delta_base([r1, d2], TH, ct(CT3), tns(["tu-0", "tu-1", "tu-m", "tu-2", "tu-z"])) is not None)
    # C6: no compaction since the root, none at thread level
    ok("C6 a foreign compacted turn since the root gives none", xp.delta_base([r1], TH, ct(CT2), tns(["tu-1", "tu-m"], bad={"tu-m": True})) is None)
    ok("C6 the root turn itself compacted gives none", xp.delta_base([r1], TH, ct(CT2), tns(["tu-1"], bad={"tu-1": True})) is None)
    ok("C6 a turn since the root with compacted unknown gives none", xp.delta_base([r1], TH, ct(CT2), tns(["tu-1", "tu-m"], bad={"tu-m": None})) is None)
    ok("C6 a compacted turn before the root does not matter", xp.delta_base([r1], TH, ct(CT2), tns(["tu-0", "tu-1"], bad={"tu-0": True})) is not None)
    ok("C6 thread_compactions above zero gives none", xp.delta_base([r1], TH, ct(CT2), tns(["tu-1"], comp=1)) is None)
    ok("C6 thread_compactions null gives none", xp.delta_base([r1], TH, ct(CT2), tns(["tu-1"], comp=None)) is None)
    ok("C6 turns without a list give none", xp.delta_base([r1], TH, ct(CT2), {"thread_compactions": 0}) is None)
    # a plan listing a link relied on must still hold (the gate checks it)
    bad_plan = rc("xr-1", TH, "tu-1", ct(CT1), plans_from=[{"path": "docs/superpowers/plans/p.md", "nonce": "xr-none", "blob": "a" * 40}])
    ok("C6 a link whose plans_from is unbacked gives none", xp.delta_base([bad_plan], TH, ct(CT2), tns(["tu-1"])) is None)


# ---------------------------------------------------------------- K10 / F1 every switch off
print("K10. build with every switch off is today's packet")


@guarded("K10")
def _k10():
    repo, base, tip = mkchange("k10", {"a.txt": b"one\ntwo\n", "dir/b.txt": b"b\n"})
    repo2, base2, tip2 = mkchange("k10b", {"c.txt": b"c\n"})
    t1, t2 = target_of(repo, base, tip), target_of(repo2, base2, tip2)
    sp = [repo + ":main...HEAD", repo2 + ":main...HEAD"]
    dec = built(request([t1, t2], sp))
    want = xp.today_packet(rd(FIX, "reviewer.md"), b"Review this.\n",
                           [(sp[0], LD.patch(t1["repo"], base, tip)), (sp[1], LD.patch(t2["repo"], base2, tip2))])
    ok("K10 two targets: byte-identical to today_packet", pkt(dec) == want)
    is_("K10 the decision is a send of a full packet", (dec["action"], dec["kind"]), ("send", "full"))
    is_("K10 each target is full, follows nothing, lists no plan",
        [(t["packet"], t["delta_from"], t["history"], t["plans_from"]) for t in dec["targets"]], [("full", None, None, [])] * 2)
    is_("K10 the switches are the four states", dec["switches"], OFF)
    is_("K10 the targets keep their own fields", [t["tip"] for t in dec["targets"]], [tip, tip2])
    is_("K10 no diff at all is today's packet too", pkt(built(request([], []))),
        xp.today_packet(rd(FIX, "reviewer.md"), b"Review this.\n", []))
    n = len(LD.patch(t1["repo"], base, tip).rstrip(b"\n"))
    over = built(request([t1], sp[:1], cap=n - 1))
    is_("F1 fit off: a cap overflow refuses", over["action"], "refuse")
    is_("F1 with today's text, verbatim", over["reason"], CAP_TEXT.format(n, n - 1))
    ok("F1 and no packet is written", over["packets"] == [])
    is_("F1 the cap is a strict greater-than", built(request([t1], sp[:1], cap=n))["action"], "send")
    m = n + len(LD.patch(t2["repo"], base2, tip2).rstrip(b"\n"))
    is_("F1 the total of all the diffs is compared", built(request([t1, t2], sp, cap=100))["reason"], CAP_TEXT.format(m, 100))
    fo = built(request([t1], sp[:1], cap=n - 1, switches_file=swf(framing=True)))
    is_("F1 framing on with fit off refuses, saying the cap is Michael's to raise",
        (fo["action"], fo["reason"]), ("refuse", CAP_FRAMED.format(n, n - 1)))
    ok("F1 and never offers slicing or the variable", "slices" not in fo["reason"] and "XREVIEW_MAX_DIFF_BYTES" not in fo["reason"], fo["reason"])
    fs = built(request([t1], sp[:1], switches_file=swf(framing=True)))
    ok("F1 framing on with fit off sends a framed packet", fs["action"] == "send" and b"Files in this change (2):" in pkt(fs))
    # the cap counts characters, as bash's ${#d} does, not bytes
    ru, bu, tu = mkchange("k10u", {"u.txt": ("\u00e9" * 60000 + "\n").encode()})
    tgu = target_of(ru, bu, tu)
    du = LD.patch(tgu["repo"], bu, tu).rstrip(b"\n")
    nchars = len(du.decode("utf-8"))
    ok("F1 the fixture has fewer characters than bytes, the cap between them", nchars < 100000 < len(du), (nchars, len(du)))
    is_("F1 a non-ASCII diff over the cap in bytes but under it in characters is sent", built(request([tgu], [ru + ":main...HEAD"]))["action"], "send")
    ref = built(request([tgu], [ru + ":main...HEAD"], cap=nchars - 1))
    is_("F1 and the refusal prints the character count", (ref["action"], ref["reason"]), ("refuse", CAP_TEXT.format(nchars, nchars - 1)))
    is_("F1 with framing on too", built(request([tgu], [ru + ":main...HEAD"], cap=nchars - 1, switches_file=swf(framing=True)))["reason"], CAP_FRAMED.format(nchars, nchars - 1))
    rb2, bb2, tb2 = mkchange("k10bad", {"bad.txt": b"\xc3\xa9" * 5 + b"\xff" * 3 + b"\n"})
    tgb = target_of(rb2, bb2, tb2)
    db = LD.patch(tgb["repo"], bb2, tb2).rstrip(b"\n")
    is_("F1 each undecodable byte counts as one character", built(request([tgb], [rb2 + ":main...HEAD"], cap=1))["reason"], CAP_TEXT.format(len(db) - 5, 1))


# ---------------------------------------------------------------- X1 diff prefixes
print("X1. the user's diff prefixes hold with every switch off; a switch on pins a/ and b/")


@guarded("X1")
def _x1():
    for key in ("diff.noprefix", "diff.mnemonicPrefix"):
        tag = key.split(".")[1]
        repo, base, tip = mkchange("x1" + tag, {"a.txt": b"one\ntwo\n", "dir/b.txt": b"b\n"})
        git(repo, "config", key, "true")
        tg = target_of(repo, base, tip)
        sp = [repo + ":main...HEAD"]
        main_diff = git(repo, "diff", "--no-color", *(LD.DIFF_FLAGS + ["--text", base, tip]))
        # mnemonicPrefix leaves a commit-to-commit diff at a/ b/ (it changes only diffs that involve the index
        # or work tree), so only noprefix has a rendering to tell apart; the byte comparison covers both.
        if tag == "noprefix":
            ok("X1 {} (setup) git's own rendering is not a/ b/".format(key), b"diff --git a/a.txt b/a.txt" not in main_diff, main_diff[:120])
        off = built(request([tg], sp))
        want = xp.today_packet(rd(FIX, "reviewer.md"), b"Review this.\n", [(sp[0], main_diff)])
        ok("X1 {} all off: the packet carries main's rendering byte for byte".format(key), pkt(off) == want)
        if tag == "noprefix":
            ok("X1 {} all off: the headers are not forced to a/ b/".format(key), b"diff --git a/" not in pkt(off))
        for sws in ({"framing": True}, {"framing": True, "omit_plans": True}):
            on = built(request([tg], sp, switches_file=swf(**sws)))
            is_("X1 {} {}: the labels are the plain paths".format(key, sorted(sws)), on["packets"][0]["shown"], ["a.txt", "dir/b.txt"])
            heads = [l for l in pkt(on).split(b"\n") if l.startswith(b"diff --git ")]
            is_("X1 {} {}: the diff headers carry a/ and b/".format(key, sorted(sws)), heads,
                [b"diff --git a/a.txt b/a.txt", b"diff --git a/dir/b.txt b/dir/b.txt"])


# ---------------------------------------------------------------- C7 multi-target, one delta one full
print("C7. a multi-target request where one target is a delta and one is full")
dA = mkrepo("c7a")
put(dA, "s", b"s\n")
dAb = commit(dA, "s")
put(dA, "a.py", b"a1\na2\n")
put(dA, "e.py", b"untouched\n")
dA1 = commit(dA, "t1")
put(dA, "a.py", b"a1\na2\na3\n")
put(dA, "c.py", b"c\n")
dA2 = commit(dA, "t2")
dB, dBb, dB1 = mkchange("c7b", {"b.py": b"b1\n"})


@guarded("C7")
def _c7():
    tA1, tA2 = target_of(dA, dAb, dA1), target_of(dA, dAb, dA2)
    tB = target_of(dB, dBb, dB1)
    put_ledger(dA, rc("xr-c7", "thD", "tu-c7", tA1))
    home = mkhome("c7")
    rollout(home, "thD", 50000, 258400)
    turns = wr(os.path.join(ROOT, "c7-turns.json"), json.dumps(tns(["tu-c7"])))
    sp = [dA + ":main...HEAD", dB + ":main...HEAD"]
    req = request([tA2, tB], sp, switches_file=swf(framing=True, fit=True, delta=True), codex_home=home,
                  thread="thD", turns_file=turns, missed=["a.py", "x/y.py#1/2"])
    dec = built(req)
    is_("C7 sent on the thread", (dec["action"], dec["kind"]), ("send", "delta"))
    tg = dec["targets"]
    is_("C7 target A is a delta of xr-c7, with the thread's turn ids", (tg[0]["packet"], tg[0]["delta_from"], tg[0]["history"]), ("delta", "xr-c7", ["tu-c7"]))
    is_("C7 target B is full, follows nothing", (tg[1]["packet"], tg[1]["delta_from"], tg[1]["history"]), ("full", None, None))
    is_("C7 each lists no plan", (tg[0]["plans_from"], tg[1]["plans_from"]), ([], []))
    text = pkt(dec).decode()
    ok("C7 the delta header names the round, behind A's label", (dA + ": " + DELTA.format("xr-c7")) in text, text[:600])
    ok("C7 and appears once", text.count("This round follows") == 1)
    ok("C7 A shows only what changed since", "diff --git a/c.py b/c.py" in text and "+a3" in text and "+a1\n" not in text)
    ok("C7 B shows its whole patch", "diff --git a/b.py b/b.py" in text and "new file mode" in text)
    ok("C7 the file list opens with the count of all files", "Files in this change (4):" in text, text[:900])
    ok("C7 A's changed files are shown, behind its label", "  shown     +1 -0  {}:c.py\n".format(dA) in text and "  shown     +1 -0  {}:a.py\n".format(dA) in text)
    ok("C7 A's untouched file is earlier, with the whole change's counts", "  earlier   +1 -0  {}:e.py\n".format(dA) in text)
    ok("C7 B's file is shown", "  shown     +1 -0  {}:b.py\n".format(dB) in text)
    ok("C7 the missed line is fixed text", MISSED.format("a.py, x/y.py#1/2") in text)
    is_("C7 shown is exactly the labels to be covered", sorted(dec["packets"][0]["shown"]),
        sorted(["{}:a.py".format(dA), "{}:c.py".format(dA), "{}:b.py".format(dB)]))
    ok("C7 the reviewer instructions and the framing precede the body",
       text.index("independent reviewer") < text.index("Below this request") < text.index("Review this."))
    ok("C7 the file list follows the body, ahead of the diffs it indexes",
       text.index("Review this.") < text.index("Files in this change (4):") < text.index("--- diff ("))
    ok("C7 the framing text says so, and no longer claims the request opens with the list",
       "precedes the diffs it indexes" in text and "This request opens with a file list" not in text)
    # the gate accepts the chain xreview would record
    rec = rc("xr-c7b", "thD", "tu-c7b", dict(tg[0]))
    ok("C7 a receipt of that delta passes the gate's chain check",
       LD.chain_problem([rc("xr-c7", "thD", "tu-c7", tA1)], rec, dict(tg[0]), dA) is None,
       LD.chain_problem([rc("xr-c7", "thD", "tu-c7", tA1)], rec, dict(tg[0]), dA))
    # moving the checkpoint to a fresh thread rebuilds every target as full
    rollout(home, "thD", 240000, 258400)
    fresh = built(req)
    is_("F3 the thread too full: a fresh thread", (fresh["action"], fresh["kind"]), ("fresh", "full"))
    is_("F3 rebuilt as full for every target", [(t["packet"], t["delta_from"], t["history"]) for t in fresh["targets"]], [("full", None, None)] * 2)
    ftext = pkt(fresh).decode()
    ok("F3 and the whole patch is there", "new file mode" in ftext and "+a1\n" in ftext and "This round follows" not in ftext)
    ok("F3 with no earlier file", "  earlier " not in ftext)
    rollout(home, "thD", 50000, 258400)
    nodelta = built(dict(req, switches_file=swf(framing=True, fit=True)))
    is_("C7 with delta off every target is full", [t["packet"] for t in nodelta["targets"]], ["full", "full"])
    plan_cp = built(dict(req, checkpoint="plan"))
    is_("C7 a plan checkpoint is never a delta", [t["packet"] for t in plan_cp["targets"]], ["full", "full"])
    none_turns = built(dict(req, turns_file=None))
    is_("C7 no turns file: a full packet, not a refusal", (none_turns["action"], [t["packet"] for t in none_turns["targets"]]), ("send", ["full", "full"]))
    junk = wr(os.path.join(ROOT, "junk-turns.json"), "{not json")
    is_("C7 an unreadable turns file is no history either", [t["packet"] for t in built(dict(req, turns_file=junk))["targets"]], ["full", "full"])
    comp = wr(os.path.join(ROOT, "comp-turns.json"), json.dumps(tns(["tu-c7"], comp=1)))
    is_("C7 a thread-level compaction: full", [t["packet"] for t in built(dict(req, turns_file=comp))["targets"]], ["full", "full"])
    same = built(dict(req, targets=[tA1, tB]))
    is_("C7 an unchanged tip is a full packet, not an empty delta", same["targets"][0]["packet"], "full")


# ---------------------------------------------------------------- P1 / P2 plans
print("P. plans covered by their plan review")
PL = "docs/superpowers/plans/"
pr, pbase, ptip0 = mkchange("plans", {PL + "a.md": b"# A\n1\n2\n3\n", PL + "b.md": b"# B\nb1\nb2\n", "src.py": b"print(1)\n"})
PA0, PB0 = LD.plan_blobs(pr, pbase, ptip0)[PL + "a.md"], LD.plan_blobs(pr, pbase, ptip0)[PL + "b.md"]
put(pr, PL + "a.md", b"# A\n1\n2\n3\nstatus: done\n")
put(pr, "src.py", b"print(1)\nprint(2)\n")
ptip = commit(pr, "work")
ptgt = target_of(pr, pbase, ptip)


@guarded("P")
def _p():
    plan_t = target_of(pr, pbase, ptip0)
    entries = [rc("xr-pl", "thP", "tu-p", plan_t, checkpoint="plan", plan_blobs=LD.plan_blobs(pr, pbase, ptip0))]
    got = xp.plan_listing(entries, pr, ptgt)
    is_("P1 both plans are bound to the plan review", got, {PL + "a.md": {"nonce": "xr-pl", "blob": PA0}, PL + "b.md": {"nonce": "xr-pl", "blob": PB0}})
    put_ledger(pr, entries[0])
    sp = [pr + ":main...HEAD"]
    dec = built(request([ptgt], sp, switches_file=swf(framing=True, omit_plans=True)))
    text = pkt(dec).decode()
    cur_a = git(pr, "rev-parse", "HEAD:" + PL + "a.md").decode().strip()
    later = LD.blob_patch(pr, PL + "a.md", PA0, cur_a).decode()
    ok("P1 a bound plan shows its patch from the bound blob to now", later in text and "+status: done" in text)
    ok("P1 and not the plan's whole content", "+# A" not in text)
    ok("P1 a plan with no later change shows nothing of itself", "+b1" not in text and "+# B" not in text)
    ok("P1 the code is shown whole", "diff --git a/src.py b/src.py" in text and "+print(1)" in text)
    ok("P1 both listing lines are fixed text", LISTED.format(PL + "a.md", "xr-pl") in text and LISTED.format(PL + "b.md", "xr-pl") in text)
    ok("P1 the plan with a later change is shown", "  shown     +1 -0  {}a.md\n".format(PL) in text, text[:800])
    ok("P1 the plan with none is listed, with its whole counts", "  listed    +3 -0  {}b.md\n".format(PL) in text)
    is_("P1 plans_from records both, by plan path, nonce and blob", dec["targets"][0]["plans_from"],
        [{"path": PL + "a.md", "nonce": "xr-pl", "blob": PA0}, {"path": PL + "b.md", "nonce": "xr-pl", "blob": PB0}])
    is_("P1 shown covers the plan with a later patch and the code, not the listed plan",
        sorted(dec["packets"][0]["shown"]), sorted([PL + "a.md", "src.py"]))
    gate = rc("xr-gate", "thP", "tu-g", dict(dec["targets"][0]))
    is_("P1 plans_from is backed by the ledger, as the gate checks", LD.plans_problem(entries, gate["targets"][0]), None)
    off = built(request([ptgt], sp, switches_file=swf(framing=True)))
    ok("P1 omit_plans off: the plans are shown whole", "+# A" in pkt(off).decode() and "+# B" in pkt(off).decode())
    is_("P1 and plans_from is empty", off["targets"][0]["plans_from"], [])
    spec_cp = built(request([ptgt], sp, checkpoint="spec", switches_file=swf(framing=True, omit_plans=True)))
    ok("P1 a spec checkpoint lists no plan", "+# A" in pkt(spec_cp).decode())

    def whole_plan(name, ents):
        r2 = mkrepo("p2-" + name.replace(" ", "-").replace("(", "").replace(")", ""))
        put(r2, "s", b"s\n")
        b2 = commit(r2, "s")
        put(r2, PL + "a.md", b"# A\n1\n2\n3\n")
        t0 = commit(r2, "plan")
        put(r2, PL + "a.md", b"# A\n1\n2\n3\nstatus: done\n")
        t1 = commit(r2, "more")
        tg0, tg1 = target_of(r2, b2, t0), target_of(r2, b2, t1)
        es = ents(r2, b2, t0, tg0)
        put_ledger(r2, *es)
        listing = xp.plan_listing(es, r2, tg1)
        d = built(request([tg1], [r2 + ":main...HEAD"], switches_file=swf(framing=True, omit_plans=True)))
        t = pkt(d).decode()
        is_("P2 {}: nothing is listed".format(name), listing, {})
        ok("P2 {}: the whole plan is shown".format(name), "+# A" in t and "+status: done" in t, t[-400:])
        is_("P2 {}: plans_from is empty".format(name), d["targets"][0]["plans_from"], [])
        ok("P2 {}: no listing line".format(name), "was shown whole in the approved plan review" not in t)

    whole_plan("unclean", lambda r, b, t0, tg: [rc("xr-1", "thQ", "tu", tg, checkpoint="plan", clean=False, plan_blobs=LD.plan_blobs(r, b, t0))])
    whole_plan("not approved", lambda r, b, t0, tg: [rc("xr-1", "thQ", "tu", tg, checkpoint="plan", verdict="changes", plan_blobs=LD.plan_blobs(r, b, t0))])
    whole_plan("a spec review", lambda r, b, t0, tg: [rc("xr-1", "thQ", "tu", tg, checkpoint="spec", plan_blobs=LD.plan_blobs(r, b, t0))])
    whole_plan("legacy (no plan_blobs)", lambda r, b, t0, tg: [rc("xr-1", "thQ", "tu", tg, checkpoint="plan")])
    whole_plan("path missing from plan_blobs", lambda r, b, t0, tg: [rc("xr-1", "thQ", "tu", tg, checkpoint="plan", plan_blobs={})])
    r3 = mkrepo("p2-modonly")
    put(r3, "s", b"s\n")
    put(r3, PL + "a.md", b"# A\n1\n")
    b3 = commit(r3, "plan exists")
    put(r3, PL + "a.md", b"# A\n1\n2\n")
    m1 = commit(r3, "modified")
    put(r3, PL + "a.md", b"# A\n1\n2\n3\n")
    m2 = commit(r3, "again")
    mod_entry = rc("xr-1", "thQ", "tu", target_of(r3, b3, m1), checkpoint="plan", plan_blobs=LD.plan_blobs(r3, b3, m1))
    is_("P2 a plan only modified in the plan review's range is not in plan_blobs", mod_entry["targets"][0]["plan_blobs"], {})
    is_("P2 so it is not listed", xp.plan_listing([mod_entry], r3, target_of(r3, b3, m2)), {})
    is_("P2 a plan that is not in the change is not listed", xp.plan_listing(entries, pr, target_of(pr, ptip, ptip)), {})
    newer = rc("xr-pl2", "thP", "tu-p2", plan_t, checkpoint="plan", plan_blobs={PL + "a.md": PA0})
    got2 = xp.plan_listing(entries + [newer], pr, ptgt)
    is_("P2 the latest binding wins", got2[PL + "a.md"]["nonce"], "xr-pl2")
    is_("P2 and another plan keeps its own", got2[PL + "b.md"]["nonce"], "xr-pl")
    gone = rc("xr-pl3", "thP", "tu-p3", plan_t, checkpoint="plan", plan_blobs={PL + "a.md": "f" * 40})
    is_("P2 a bound blob that is not in the repository is not listed", PL + "a.md" in xp.plan_listing(entries + [gone], pr, ptgt), False)


# ---------------------------------------------------------------- F fit, fresh, slices
print("F. the fit check, a fresh thread, slices")
fr, fb, ft = mkchange("fitrepo", {"a.txt": b"hello\n", "d/b.txt": b"world\n"})
ftgt = target_of(fr, fb, ft)
fsp = [fr + ":main...HEAD"]
FIT = dict(framing=True, fit=True)


@guarded("F")
def _f():
    home = mkhome("f")
    rollout(home, "thF", 100000, 258400)
    d = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=home))
    is_("F2 no thread yet and it fits: send", (d["action"], d["kind"]), ("send", "full"))
    ok("F2 the packet is framed", b"Files in this change (2):" in pkt(d) and b"independent reviewer" in pkt(d))
    is_("F2 shown is the files", sorted(d["packets"][0]["shown"]), ["a.txt", "d/b.txt"])
    d = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=home, thread="thF"))
    is_("F2 on the thread: send", d["action"], "send")
    ok("F2 the reason gives need and limit", "need" in d["reason"] and "limit" in d["reason"], d["reason"])
    d = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=home, thread="thF", cap=1))
    is_("F2 with fit on the cap does not apply", d["action"], "send")
    # F3: too full for the thread, fits a fresh one
    rollout(home, "thF", 232000, 258400)
    d = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=home, thread="thF"))
    is_("F3 context + packet + reserve above the limit: fresh", (d["action"], d["kind"]), ("fresh", "full"))
    is_("F3 one packet", len(d["packets"]), 1)
    is_("F3 packet kind full", d["targets"][0]["packet"], "full")
    pk = len(pkt(d))
    edge_ctx = 232560 - 60000 - xp.estimate_tokens(pk)
    rollout(home, "thF", edge_ctx, 258400)
    is_("F3 need == limit stays on the thread", built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=home, thread="thF"))["action"], "send")
    rollout(home, "thF", edge_ctx + 1, 258400)
    is_("F3 one token more moves it", built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=home, thread="thF"))["action"], "fresh")
    # F5: a thread whose rollout cannot be read counts as not fitting
    d = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=home, thread="th-unread"))
    is_("F5 an existing thread whose rollout cannot be read: fresh", d["action"], "fresh")
    wr(os.path.join(home, "sessions", "2026", "10", "25", "rollout-2026-10-25T12-00-00-th-garble.jsonl"), "x\n")
    is_("F5 so is one whose rollout is garbled", built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=home, thread="th-garble"))["action"], "fresh")
    # F5z: a thread whose rollout is compressed is read, not treated as unreadable
    if HAVE_ZSTD:
        zh = mkhome("f5z")
        os.utime(rollout(zh, "thZ", 100000, 258400, compressed=True), (1000000, 1000000))
        d = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=zh, thread="thZ"))
        is_("F5z a compressed rollout with room: send on the thread", (d["action"], d["kind"]), ("send", "full"))
        ok("F5z and the reason carries the real context", "100000 in the context" in d["reason"], d["reason"])
        os.utime(rollout(zh, "thZ", 232000, 258400, compressed=True, stamp="2026-10-25T11-00-00"), (2000000, 2000000))
        d = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=zh, thread="thZ"))
        is_("F5z the newer compressed rollout is too full: fresh, for the numbers, not for being unreadable",
            d["action"], "fresh")
        ok("F5z and the reason gives them", "232000 in the context" in d["reason"] and "cannot be read" not in d["reason"], d["reason"])
    else:
        skip_zstd("F5z")
    # F6: no window to be had anywhere: refuse, naming the window
    empty = mkhome("f6")
    for th in (None, "thF"):
        d = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=empty, thread=th))
        is_("F6 an unreadable window refuses (thread {})".format(th), d["action"], "refuse")
        ok("F6 and names the window", "context window" in d["reason"], d["reason"])
    # F4: too big for a fresh thread: slices. Window 120000: limit 108000, fresh 30000, reserve 60000
    # leave 18000 tokens = 63000 bytes of packet.
    small = mkhome("f4")
    rollout(small, "thS", 10000, 120000)
    files = dict(("f{:02d}.txt".format(i), (("line %02d %s\n" % (i, "x" * 60)).encode()) * 280) for i in range(12))
    sr, sb, st = mkchange("slicerepo", files)
    stgt = target_of(sr, sb, st)
    ssp = [sr + ":main...HEAD"]
    d = built(request([stgt], ssp, switches_file=swf(**FIT), codex_home=small, thread=None))
    is_("F4 a change too big for a fresh thread: slices", (d["action"], d["kind"]), ("slices", "slices"))
    n = len(d["packets"])
    ok("F4 several slices", n >= 3, n)
    sizes = [len(rd(p["file"])) for p in d["packets"]]
    ok("F4 each slice's need is within the limit at a fresh thread", all(xp.fits(xp.FRESH_CONTEXT, s, 120000) for s in sizes), sizes)
    ok("F4 and the slices are well filled (at most one is under half the room)", sum(1 for s in sizes if s < 31500) <= 1, sizes)
    shown = [l for p in d["packets"] for l in p["shown"]]
    is_("F4 every file is shown in exactly one slice, in path order", shown, sorted(files))
    is_("F4 the targets are slices", d["targets"][0]["packet"], "slices")
    for i, p in enumerate(d["packets"]):
        t = rd(p["file"]).decode()
        ok("F4 slice {} says which it is".format(i + 1), SLICE.format(i + 1, n) in t)
        ok("F4 slice {} carries exactly its own patches".format(i + 1),
           all(("diff --git a/{} b/{}".format(l, l) in t) == (l in p["shown"]) for l in files))
        rows = [x for x in t.splitlines() if x.startswith("  shown ") or x.startswith("  elsewhere ")]
        ok("F4 slice {} lists the complete change, its own as shown and the rest elsewhere".format(i + 1),
           "Files in this change (12):" in t and len(rows) == 12
           and sorted(x.split()[-1] for x in rows if x.startswith("  shown ")) == sorted(p["shown"]), rows[:3])
    is_("F4 a rerun is the same", [rd(p["file"]) for p in built(request([stgt], ssp, switches_file=swf(**FIT), codex_home=small))["packets"]],
        [rd(p["file"]) for p in d["packets"]])
    rollout(small, "thS", 100000, 120000)
    d2 = built(request([stgt], ssp, switches_file=swf(**FIT), codex_home=small, thread="thS"))
    is_("F4 an existing thread too full, and a fresh one too small: slices", d2["action"], "slices")
    big = dict(files, **{"huge.txt": b"".join(b"row %05d %s\n" % (i, b"y" * 70) for i in range(2500))})
    br, bb, bt = mkchange("bigfile", big)
    d3 = built(request([target_of(br, bb, bt)], [br + ":main...HEAD"], switches_file=swf(**FIT), codex_home=small))
    labels = [l for p in d3["packets"] for l in p["shown"]]
    parts = [l for l in labels if l.startswith("huge.txt#")]
    ok("F4 a file bigger than a slice is split into labelled parts", len(parts) >= 3 and re.match(r"huge\.txt#1/\d+", parts[0]) is not None, labels)
    ok("F4 no part is left out", parts == ["huge.txt#%d/%d" % (i + 1, len(parts)) for i in range(len(parts))], parts)
    ok("F4 every slice within the limit", all(xp.fits(xp.FRESH_CONTEXT, len(rd(p["file"])), 120000) for p in d3["packets"]))
    t0 = rd(d3["packets"][[i for i, p in enumerate(d3["packets"]) if parts[0] in p["shown"]][0]]["file"]).decode()
    ok("F4 a part has its own line in the list", any(x.endswith(parts[0]) and x.startswith("  shown ") for x in t0.splitlines()))
    tiny = mkhome("tiny")
    rollout(tiny, "thT", 1, 90000)
    dt = built(request([ftgt], fsp, switches_file=swf(**FIT), codex_home=tiny))
    is_("F4 a window with no room for any packet refuses", dt["action"], "refuse")
    ok("F4 naming the window", "window" in dt["reason"], dt["reason"])
    d4 = built(request([stgt], ssp, switches_file=swf(**FIT), codex_home=small, missed=["f01.txt"]))
    ok("F4 the missed line is in every slice", all(MISSED.format("f01.txt") in rd(p["file"]).decode() for p in d4["packets"]))
    ok("F4 max_packet_bytes is the exact edge of fits",
       xp.fits(xp.FRESH_CONTEXT, 63000, 120000) and not xp.fits(xp.FRESH_CONTEXT, 63001, 120000))
    # a slice that comes out over the limit is a refusal that names the unit, not a crash
    keep = xp.SLICE_SLACK
    xp.SLICE_SLACK = -25000
    try:
        over = built(request([stgt], ssp, switches_file=swf(**FIT), codex_home=small))
    finally:
        xp.SLICE_SLACK = keep
    is_("F4 an over-limit slice is a refuse decision", (over["action"], over["packets"]), ("refuse", []))
    ok("F4 whose reason names the slice and the unit that cannot fit",
       "above the 63000" in over["reason"] and re.search(r"cannot fit is f\d\d\.txt\Z", over["reason"]) is not None, over["reason"])
    is_("F4 and the targets are still reported", len(over["targets"]), 1)


# ---------------------------------------------------------------- F7 a 20,000-file change
print("F7. a 20,000-file change cuts the slice file lists")


@guarded("F7")
def _f7():
    repo = mkrepo("f7")
    put(repo, "seed.txt", b"seed\n")
    base = commit(repo, "seed")
    for i in range(20000):
        put(repo, "d{:02d}/file{:05d}.txt".format(i // 1000, i), ("content %d\n" % i).encode())
    tip = commit(repo, "many")
    home = mkhome("f7")
    rollout(home, "thW", 1000, 258400)
    tg = target_of(repo, base, tip)
    d = built(request([tg], [repo + ":main...HEAD"], switches_file=swf(**FIT), codex_home=home, thread=None))
    is_("F7 slices", d["action"], "slices")
    n = len(d["packets"])
    ok("F7 several slices", n >= 2, n)
    shown = [l for p in d["packets"] for l in p["shown"]]
    is_("F7 every file shown once", len(shown), 20000)
    is_("F7 and in path order", shown, sorted(shown))
    for i, p in enumerate(d["packets"]):
        data = rd(p["file"])
        t = data.decode()
        lines = [x for x in t.splitlines() if x.startswith("  shown ") or x.startswith("  elsewhere ")]
        ok("F7 slice {} fits a fresh thread".format(i + 1), xp.fits(xp.FRESH_CONTEXT, len(data), 258400), len(data))
        is_("F7 slice {} lists only its own files".format(i + 1), len(lines), len(p["shown"]))
        ok("F7 slice {} says how many files there are, and how to list them all".format(i + 1),
           "Files in this change (20000):" in t and "git --git-dir=" in t and "diff --stat" in t)
        ok("F7 no slice names a file elsewhere", not any(x.startswith("  elsewhere ") for x in t.splitlines()))
    full_list = len(xp.file_list([("shown", 1, 0, l) for l in shown]))
    ok("F7 the complete list would have been more than a tenth of a slice", full_list > xp.FILE_LIST_SHARE * 499000, full_list)


# ---------------------------------------------------------------- F8 slices of several targets
print("F8. slices of two targets")


@guarded("F8")
def _f8():
    home = mkhome("f8")
    rollout(home, "thM", 1000, 120000)
    mk = lambda tag: dict(("%s%d.txt" % (tag, i), (b"%s line %d %s\n" % (tag.encode(), i, b"x" * 60)) * 300) for i in range(4))
    ra, ba, ta = mkchange("f8a", mk("a"))
    rb, bb, tb = mkchange("f8b", mk("b"))
    d = built(request([target_of(ra, ba, ta), target_of(rb, bb, tb)], [ra + ":main...HEAD", rb + ":main...HEAD"],
                      switches_file=swf(**FIT), codex_home=home))
    is_("F8 two targets too big for a fresh thread: slices", d["action"], "slices")
    shown = [l for p in d["packets"] for l in p["shown"]]
    is_("F8 every file of both targets, behind its target's label, in target then path order",
        shown, ["{}:a{}.txt".format(ra, i) for i in range(4)] + ["{}:b{}.txt".format(rb, i) for i in range(4)])
    is_("F8 each target is slices", [t["packet"] for t in d["targets"]], ["slices", "slices"])
    for i, p in enumerate(d["packets"]):
        t = rd(p["file"]).decode()
        heads = [x for x in t.splitlines() if x.startswith("--- diff (")]
        want = [ra for l in p["shown"] if l.startswith(ra + ":")][:1] + [rb for l in p["shown"] if l.startswith(rb + ":")][:1]
        is_("F8 slice {} has a diff block for each target it carries".format(i + 1), len(heads), len(want))
        ok("F8 slice {} fits a fresh thread".format(i + 1), xp.fits(xp.FRESH_CONTEXT, len(t.encode()), 120000))
        ok("F8 slice {} header is fixed text".format(i + 1), SLICE.format(i + 1, len(d["packets"])) in t)
    is_("F8 the same two repositories give two distinct targets", len(set(t["repo"] for t in d["targets"])), 2)


# ---------------------------------------------------------------- CLI
print("B. the command line")


@guarded("B")
def _b():
    repo, base, tip = mkchange("cli", {"a.txt": b"x\n"})
    tg = target_of(repo, base, tip)
    req = request([tg], [repo + ":main...HEAD"])
    rq = wr(os.path.join(ROOT, "cli-req.json"), json.dumps(req))
    od = os.path.join(ROOT, "cli-out")
    p = subprocess.run(["/usr/bin/python3", "-I", MODULE, "build", rq, od], capture_output=True, text=True, env=dict(os.environ))
    is_("B build exits 0", p.returncode, 0)
    dec = json.loads(p.stdout)
    is_("B and prints the decision", (dec["action"], dec["kind"]), ("send", "full"))
    ok("B the packet is written under OUTDIR", dec["packets"][0]["file"].startswith(od) and os.path.isfile(dec["packets"][0]["file"]))
    ok("B and is today's bytes", rd(dec["packets"][0]["file"]) == xp.today_packet(rd(FIX, "reviewer.md"), b"Review this.\n", [(req["specs"][0], LD.patch(tg["repo"], base, tip))]))
    pb = subprocess.run(["/usr/bin/python3", "-I", MODULE, "plan-blobs", repo, base, tip], capture_output=True, text=True, env=dict(os.environ))
    is_("B plan-blobs exits 0", pb.returncode, 0)
    is_("B and prints the ledger's plan_blobs as JSON", json.loads(pb.stdout), {})
    pb2 = subprocess.run(["/usr/bin/python3", "-I", MODULE, "plan-blobs", pr, pbase, ptip0], capture_output=True, text=True, env=dict(os.environ))
    is_("B plan-blobs lists the added plans", json.loads(pb2.stdout), LD.plan_blobs(pr, pbase, ptip0))
    bad = subprocess.run(["/usr/bin/python3", "-I", MODULE, "plan-blobs", repo, "nope", tip], capture_output=True, text=True, env=dict(os.environ))
    ok("B plan-blobs on a bad range fails with a message", bad.returncode != 0 and bad.stderr.strip() != "", bad)
    nr = subprocess.run(["/usr/bin/python3", "-I", MODULE, "build", os.path.join(ROOT, "missing.json"), od], capture_output=True, text=True, env=dict(os.environ))
    ok("B build with an unreadable request fails with a message", nr.returncode != 0 and nr.stderr.strip() != "")
    us = subprocess.run(["/usr/bin/python3", "-I", MODULE], capture_output=True, text=True, env=dict(os.environ))
    is_("B no arguments is a usage error", us.returncode, 2)


# ---------------------------------------------------------------- L labels a file name could break
print("L. a label that holds a control character is quoted, and a review without diffs says so")


@guarded("L")
def _l():
    is_("L1 a plain label is as it is, non-ASCII included", [xp.label_text(x) for x in ("a/b c.txt", "ö.md", ".:x#1/2")],
        ["a/b c.txt", "ö.md", ".:x#1/2"])
    is_("L1 a newline or another control character is quoted as git quotes a path",
        [xp.label_text(x) for x in ("a\nb.txt", "c\x01d.txt", "t\tab", "del\x7f")],
        ['"a\\nb.txt"', '"c\\001d.txt"', '"t\\tab"', '"del\\177"'])
    is_("L1 so is a label that starts with a double quote, so no two labels print alike",
        xp.label_text('"a\\nb.txt"'), '"\\"a\\\\nb.txt\\""')
    is_("L1 quoting a quoted label's text never brings a control character back", xp.label_text(xp.label_text("a\nb")).count("\n"), 0)
    repo, base, tip = mkchange("lq", {"a\nb.txt": b"one\n", "c\x01d.txt": b"two\n", "n.txt": b"three\n"})
    tgt = target_of(repo, base, tip)
    d = built(request([tgt], [repo + ":main...HEAD"], switches_file=swf(framing=True),
                      missed=["x\ny.txt", '"q\\tz.txt"', "plain.txt"]))
    text = pkt(d).decode("utf-8", "replace")
    listing = text[text.index("Files in this change (3):"):text.index("--- diff (")].rstrip("\n").split("\n")
    is_("L2 the file list quotes the labels, one line each", listing,
        ["Files in this change (3):", '  shown     +1 -0  "a\\nb.txt"', '  shown     +1 -0  "c\\001d.txt"',
         "  shown     +1 -0  n.txt"])
    is_("L2 the labels to cover are the ones the file list prints", d["packets"][0]["shown"],
        ['"a\\nb.txt"', '"c\\001d.txt"', "n.txt"])
    ok("L2 the missed note quotes a label that holds one, and keeps one the file list printed quoted as it is",
       MISSED.format('"x\\ny.txt", "q\\tz.txt", plain.txt') in text, text[:1200])
    ok("L2 and no label's newline reaches the packet outside the diff", "\nb.txt" not in text.split("--- diff (")[0] and "\ny.txt" not in text)
    # A review with no --diff still gets the framing, and one fixed line instead of a file list.
    nd = built(request([], [], checkpoint="spec", switches_file=swf(framing=True)))
    ntext = pkt(nd).decode()
    ok("L3 a framed review without diffs says there is no file list and reviewed_files is empty",
       NO_DIFFS + "\n" in ntext and re.search(r"Files in this change \(\d+\):", ntext) is None
       and "List in `reviewed_files`" in ntext, ntext[-400:])
    is_("L3 its line closes the request, after the body", ntext.endswith("Review this.\n\n" + NO_DIFFS + "\n</cross-review-request>\n"), True)
    is_("L3 and nothing is to be covered", nd["packets"][0]["shown"], [])
    ok("L3 with every switch off the packet is today's, without the line",
       NO_DIFFS not in pkt(built(request([], [], checkpoint="spec"))).decode())


@guarded("L4")
def _l4():
    # With several targets a label is <printed prefix><label_text(path)>: the prefix stays outside the
    # quotes, so a dispatcher can match a label to its target by the prefix the module reports.
    is_("L4 a prefix without a control character is as the spec gave it",
        [xp._label_prefix(s, True) for s in ("/r/x:main...HEAD", "main...HEAD", "/r/x y:a..b")], ["/r/x:", ".:", "/r/x y:"])
    is_("L4 one prefix alone is empty", xp._label_prefix("/r/x:main...HEAD", False), "")
    is_("L4 a prefix that holds a control character is quoted, colon inside",
        xp._label_prefix("/r/a\nb:main...HEAD", True), '"/r/a\\nb:"')
    ra, ba, ta = mkchange("l4a", {"a\nb.txt": b"one\n", '"q.txt': b"two\n", "n.txt": b"three\n"})
    rb, bb, tb = mkchange("l4b", {"x.txt": b"four\n"})
    d = built(request([target_of(ra, ba, ta), target_of(rb, bb, tb)], [ra + ":main...HEAD", rb + ":main...HEAD"],
                      switches_file=swf(framing=True)))
    want = [ra + ':"\\"q.txt"', ra + ':"a\\nb.txt"', ra + ":n.txt", rb + ":x.txt"]
    is_("L4 a label is the prefix, then the path as it prints", d["packets"][0]["shown"], want)
    text = pkt(d).decode()
    listing = text[text.index("Files in this change (4):"):text.index("--- diff (")].rstrip("\n").split("\n")
    is_("L4 and the file list prints the same labels", listing[1:], ["  shown     +1 -0  " + l for l in want])
    # The shown labels of a sliced review hold the same form.
    home = mkhome("l4")
    rollout(home, "thL4", 1000, 120000)
    big = dict(("f%d.txt" % i, (b"line %d %s\n" % (i, b"x" * 60)) * 300) for i in range(4))
    big["a\nb.txt"] = (b"line %s\n" % (b"x" * 60)) * 300
    rc_, bc_, tc_ = mkchange("l4c", big)
    rd_, bd_, td_ = mkchange("l4d", {"y.txt": b"y\n" * 300})
    ds = built(request([target_of(rc_, bc_, tc_), target_of(rd_, bd_, td_)], [rc_ + ":main...HEAD", rd_ + ":main...HEAD"],
                       switches_file=swf(**FIT), codex_home=home))
    is_("L4 two targets too big for a fresh thread: slices", ds["action"], "slices")
    shown = [l for p in ds["packets"] for l in p["shown"]]
    ok("L4 a sliced review's shown label keeps the prefix outside the quotes",
       rc_ + ':"a\\nb.txt"' in shown and not any(l.startswith('"') for l in shown), shown)


print("K11. the constants")
is_("K11 constants", (xp.MISSING_CAP, xp.FILE_LIST_SHARE, xp.PLAN_PREFIX), (50, 0.1, "docs/superpowers/plans/"))

PY
)"
rc=$?
printf '%s\n' "$out"
pass=$(printf '%s\n' "$out" | grep -c '^  PASS:')
fail=$(printf '%s\n' "$out" | grep -c '^  FAIL:')
if [ "$rc" -ne 0 ]; then fail=$((fail + 1)); echo "  FAIL: the python checks died (exit $rc)"; fi
printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
