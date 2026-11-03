import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import excerpts as X  # noqa: E402
from process_replay import patches as P  # noqa: E402

ROOT = helpers.tmp_root()
S = os.path.join(ROOT, "state")
os.makedirs(S)

big_lines = ["line {:04d} ".format(i).ljust(30, "x") for i in range(1, 3001)]
BIG = "".join(x + "\n" for x in big_lines)
is_("big.txt: 3000 lines of 31 characters", (len(big_lines), len(BIG)), (3000, 93000))


def lines(a, b):
    return "".join(x + "\n" for x in big_lines[a - 1:b])


def read_of(files):
    return lambda path: files.get(path)


# ---- constants and paths_of
is_("constants: the caps and the context", (X.FILE_CAP, X.TOTAL_CAP, X.CONTEXT), (60000, 150000, 150))
is_("sites: the three sites", X.SITES, ("presence", "validation", "revalidation"))
is_("paths_of: the finding's file, then the files of its fix, once each", X.paths_of({"file": "./a.py", "files": ["b.py", "a.py", "c.py", ""]}), ["a.py", "b.py", "c.py"])
is_("paths_of: no file is none", X.paths_of({}), [])

# ---- short_file_unchanged
short = "x = 1\n" * 83
got = X.files_input(["a.py"], read_of({"a.py": short}), {"a.py": [(1, 1)]})
is_("short_file_unchanged: a file of up to 60000 characters is shown whole, whatever the marks", got, ([{"path": "a.py", "text": short}], []))
exact = "y" * X.FILE_CAP
is_("short_file_unchanged: and 60000 characters exactly still is", X.files_input(["a.py"], read_of({"a.py": exact}), {}), ([{"path": "a.py", "text": exact}], []))
is_("files_input: a name read gives None for is skipped", X.files_input(["gone.py", "a.py"], read_of({"a.py": short}), {}), ([{"path": "a.py", "text": short}], []))

# ---- one_window
got, cut = X.files_input(["big.txt"], read_of({"big.txt": BIG}), {"big.txt": [(1000, 1002)]})
want = "[lines 850-1152 of 3000]\n" + lines(850, 1152)
is_("one_window: 150 lines either side of the mark, headed with the range and the file's length", got[0]["text"], want)
ok("one_window: the lines either side of the window are absent", "line 0849" not in got[0]["text"] and "line 1153" not in got[0]["text"])
is_("one_window: nothing was cut for want of an anchor", cut, [])

# ---- windows_merged
w = X.windows(BIG, [(1000, 1000), (1250, 1250)])
is_("windows_merged: overlapping windows are one, under one header", (w.count("[lines "), w.startswith("[lines 850-1400 of 3000]\n")), (1, True))
w = X.windows(BIG, [(100, 100), (2000, 2000)])
is_("windows_merged: distant windows keep two headers, in order", [x for x in w.split("\n") if x.startswith("[lines ")], ["[lines 1-250 of 3000]", "[lines 1850-2150 of 3000]"])
w = X.windows(BIG, [(100, 100), (401, 401)])
is_("windows_merged: windows that touch are one", [x for x in w.split("\n") if x.startswith("[lines ")], ["[lines 1-551 of 3000]"])
w = X.windows(BIG, [(100, 100), (402, 402)])
is_("windows_merged: and a gap of one line keeps them two", [x for x in w.split("\n") if x.startswith("[lines ")], ["[lines 1-250 of 3000]", "[lines 252-552 of 3000]"])
is_("windows_merged: marks in any order", X.windows(BIG, [(2000, 2000), (100, 100)]), X.windows(BIG, [(100, 100), (2000, 2000)]))

# ---- edges_clamped
is_("edges_clamped: a mark near the top starts at line 1", X.windows(BIG, [(10, 10)]).split("\n")[0], "[lines 1-160 of 3000]")
is_("edges_clamped: a mark near the end stops at the last line", X.windows(BIG, [(2990, 2995)]).split("\n")[0], "[lines 2840-3000 of 3000]")
is_("edges_clamped: a mark wholly outside the file is dropped", X.windows(BIG, [(3001, 3005), (0, 0), (-5, -1)]), None)
is_("edges_clamped: a mark that overlaps the file's end is kept", X.windows(BIG, [(2999, 3500)]).split("\n")[0], "[lines 2849-3000 of 3000]")
is_("windows: an empty text has no window", X.windows("", [(1, 1)]), None)

# ---- fallback_counted
got, cut = X.files_input(["big.txt"], read_of({"big.txt": BIG}), {})
is_("fallback_counted: a long file with no mark is cut from the top", (got, cut), ([{"path": "big.txt", "text": C.cap(BIG, 60000)}], ["big.txt"]))
ok("fallback_counted: and says so", got[0]["text"].endswith("\n[truncated]\n"), got[0]["text"][-40:])
got, cut = X.files_input(["big.txt"], read_of({"big.txt": BIG}), {"big.txt": [(9000, 9000)]})
is_("fallback_counted: so is one whose only mark lies outside it", cut, ["big.txt"])
X.note_cut(S, "q1", "validation", cut)
is_("fallback_counted: the record is the site and the files", C.jload(os.path.join(S, "cuts", "judge-present", "q1.json")), {"site": "validation", "files": ["big.txt"]})
is_("fallback_counted: count_cuts counts the inputs per site", X.count_cuts(S), {"presence": 0, "validation": 1, "revalidation": 0})
X.note_cut(S, "q2", "validation", ["a.py", "b.py"])
X.note_cut(S, "q3", "presence", ["a.py"])
is_("fallback_counted: an input counts once, whatever its files", X.count_cuts(S), {"presence": 1, "validation": 2, "revalidation": 0})
X.note_cut(S, "q4", "revalidation", [])
ok("fallback_counted: note_cut with no file writes nothing", not os.path.exists(os.path.join(S, "cuts", "judge-present", "q4.json")))
is_("fallback_counted: and count_cuts sees none of it", X.count_cuts(S)["revalidation"], 0)
is_("count_cuts: a state with no record is all zeros", X.count_cuts(os.path.join(ROOT, "empty")), {"presence": 0, "validation": 0, "revalidation": 0})

# ---- total_cap_finding_first
marks = [(i, i) for i in range(125, 3001, 250)]
got, cut = X.files_input(["own.txt", "big.txt", "c.txt"], read_of({"own.txt": BIG, "big.txt": BIG, "c.txt": BIG}),
                         {"own.txt": marks, "big.txt": marks, "c.txt": marks})
own = "[lines 1-3000 of 3000]\n" + BIG
is_("total_cap_finding_first: the finding's file is first, as one window", got[0], {"path": "own.txt", "text": own})
room = X.TOTAL_CAP - len(own)
is_("total_cap_finding_first: the next is cut to the room left", (got[1]["path"], got[1]["text"]), ("big.txt", C.cap(own, room)))
ok("total_cap_finding_first: and ends [truncated]", got[1]["text"].endswith("\n[truncated]\n"))
is_("total_cap_finding_first: the third is absent, and none is cut for want of an anchor", ([x["path"] for x in got], cut), (["own.txt", "big.txt"], []))

# ---- git_lines
odd = ["a{}".format(i) for i in range(1, 400)]
odd[199] = "crlf line\r"
odd[200] = "form\x0cfeed"
odd[201] = "sep arator"
pad = "z" * (X.FILE_CAP // 399 + 10)
odd_text = "\n".join(x + pad for x in odd)                  # no final newline
got = X.windows(odd_text, [(380, 380)])
is_("git_lines: n counts the last line though it has no newline", got.split("\n")[0], "[lines 230-399 of 399]")
ok("git_lines: a mark on line N shows line N as git numbers it", got.split("\n")[1] == odd[229] + pad, got.split("\n")[1][:40])
got = X.windows(odd_text, [(200, 202)])
is_("git_lines: a CR, a form feed and a U+2028 do not split a line", got.split("\n")[0], "[lines 50-352 of 399]")
ok("git_lines: and the three lines are as they were", ("crlf line\r" + pad + "\n" + "form\x0cfeed" + pad + "\n" + "sep arator" + pad + "\n") in got)
ok("git_lines: the last line keeps its lack of a newline", X.windows(odd_text, [(399, 399)]).endswith(odd[-1] + pad))
is_("git_lines: a final newline is not a line", X.windows("a\nb\n", [(1, 1)]), "[lines 1-2 of 2]\na\nb\n")

# ---- anchors_of
is_("anchors_of: the hunks under their files, the finding's line under its normalised file", X.anchors({"file": "./a.py", "line": 7}, [{"file": "b.py", "start": 3, "end": 5}]),
    {"a.py": [(7, 7)], "b.py": [(3, 5)]})
for bad in (None, 0, "7", True, -3, 2.0):
    is_("anchors_of: a line of {!r} adds nothing".format(bad), X.anchors({"file": "a.py", "line": bad}, [{"file": "b.py", "start": 3, "end": 5}]), {"b.py": [(3, 5)]})
is_("anchors_of: the finding's line and a hunk of one file are both held", X.anchors({"file": "a.py", "line": 7}, [{"file": "a.py", "start": 3, "end": 5}]), {"a.py": [(3, 5), (7, 7)]})
is_("anchors_of: no hunk, no line is nothing", X.anchors({"file": "a.py"}, []), {})

# ---- located_per_section
R = helpers.make_repo(ROOT, "repo")
put(R, "one.txt", "".join("one {}\n".format(i) for i in range(1, 31)))
put(R, "two.txt", "".join("two {}\n".format(i) for i in range(1, 31)))
base = helpers.commit(R, "base")
one2 = ["one {}\n".format(i) for i in range(1, 31)]
one2[9] = "one TEN\n"
two2 = ["two {}\n".format(i) for i in range(1, 31)]
two2[14] = "two FIFTEEN\n"
put(R, "one.txt", "".join(one2))
put(R, "two.txt", "".join(two2))
fixed = helpers.commit(R, "fixed")
patch = P.diff(R, base, fixed)
helpers.git(R, "checkout", "-q", "-b", "drift", base)
put(R, "two.txt", "".join("two {}\n".format(i) if i != 15 else "two DRIFTED\n" for i in range(1, 31)))
drifted = helpers.commit(R, "drifted")
work = os.path.join(ROOT, "work")
subprocess.run(["git", "clone", "-q", R, work], check=True, capture_output=True)
is_("located_per_section: files that apply give their hunks", sorted((h["file"], h["start"], h["end"]) for h in X.located(work, base, patch)),
    [("one.txt", 7, 13), ("two.txt", 12, 18)])
got = X.located(work, drifted, patch)
is_("located_per_section: a section that does not apply adds nothing, and the others stand", [(h["file"], h["start"], h["end"]) for h in got], [("one.txt", 7, 13)])
is_("located: a hunk is its file and lines only", sorted(got[0]), ["end", "file", "start"])
is_("located: no patch is no hunk", X.located(work, base, ""), [])

# ---- stale_line_ignored
fin = {"file": "big.txt", "line": 5000}
marks = X.anchors(fin, [{"file": "big.txt", "start": 1000, "end": 1000}])
got, cut = X.files_input(["big.txt"], read_of({"big.txt": BIG}), marks)
is_("stale_line_ignored: the finding's line past the end adds nothing; the located hunk gives the window", (got[0]["text"].split("\n")[0], cut), ("[lines 850-1150 of 3000]", []))
got, cut = X.files_input(["big.txt"], read_of({"big.txt": BIG}), {"big.txt": [(5000, 5000), (1000, 1000)]})
is_("stale_line_ignored: marks [(5000, 5000), (1000, 1000)] give one window around 1000, and no cut", ([x for x in got[0]["text"].split("\n") if x.startswith("[lines ")], cut), (["[lines 850-1150 of 3000]"], []))

# ---- huge_lines_capped
huge = "".join(("{} ".format(i) + "m" * 70000 + "\n") for i in range(1, 5))
got, cut = X.files_input(["min.json"], read_of({"min.json": huge}), {"min.json": [(2, 2)]})
is_("huge_lines_capped: a few huge lines are one window, capped at the total", got[0]["text"], C.cap("[lines 1-4 of 4]\n" + huge, X.TOTAL_CAP))
ok("huge_lines_capped: it ends [truncated], and is no fallback", got[0]["text"].endswith("\n[truncated]\n") and cut == [], (len(got[0]["text"]), cut))
