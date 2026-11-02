import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import checks as K  # noqa: E402

ROOT = helpers.tmp_root()

# ================================================================ one classifier
is_("file_kind: by extension", [K.file_kind(n) for n in ("a.sh", "a.bash", "a.zsh", "a.py", "a.rb", "a.json", "a.rs", "a.ts", "a.toml", "README")],
    ["bash", "bash", "zsh", "python", "ruby", "json", "rust", "js", None, None])
is_("file_kind: a shebang naming a known interpreter wins over the extension",
    [K.file_kind("x.sh", "#!/usr/bin/env python3"), K.file_kind("x.py", "#!/bin/zsh"), K.file_kind("x", "#!/bin/sh"), K.file_kind("x", "#!/bin/bash -e"),
     K.file_kind("x", "#!/usr/bin/env -S python3 -u"), K.file_kind("x", "#!/usr/bin/ruby2.7"), K.file_kind("x", "#!/usr/bin/env node"),
     K.file_kind("x", "#!/usr/bin/env FOO=1 zsh")],
    ["python", "zsh", "bash", "bash", "python", "ruby", "js", "zsh"])
is_("file_kind: a shebang naming no known interpreter leaves it to the extension", (K.file_kind("x.py", "#!/usr/bin/env -S uv run --script"),
                                                                                    K.file_kind("x", "#!/usr/bin/awk -f")), ("python", None))
is_("file_kind: then a path convention: a file under a zsh/functions directory is zsh", (K.file_kind("dot_config/zsh/functions/fn"),
                                                                                       K.file_kind("zsh/functions/fn", "")), ("zsh", "zsh"))

# ================================================================ coherent
CO = os.path.join(ROOT, "coh")
for path, text in {"ok.sh": "echo a\n", "bad.sh": "if true; then\n", "ok.py": "x = 1\n", "bad.py": "def (:\n", "ok.json": "{}\n", "bad.json": "{\n",
                   "shebang": "#!/bin/bash\nif true; then\n", "zshbang": "#!/usr/bin/env zsh\nfor x in 1; do\n", "dot_config/zsh/functions/fn": "f() {\n",
                   "plain.txt": "if true; then\n", "pyscript": "#!/usr/bin/env python3\ndef (:\n", "shscript": "#!/bin/sh\nif true; then\n",
                   "pybang.sh": "#!/usr/bin/env python3\nx = (\n"}.items():
    put(CO, path, text)
os.symlink("bad.sh", os.path.join(CO, "link.sh"))
is_("coherent: a good .sh file", K.coherent(CO, ["ok.sh"]), (True, ""))
b = K.coherent(CO, ["bad.sh"])
ok("coherent: bash -n on a .sh file", b[0] is False and "bad.sh" in b[1], b)
ok("coherent: bash -n on a bash shebang", K.coherent(CO, ["shebang"])[0] is False)
ok("coherent: zsh -n on a zsh shebang", K.coherent(CO, ["zshbang"])[0] is False)
ok("coherent: zsh -n on a file under zsh/functions", K.coherent(CO, ["dot_config/zsh/functions/fn"])[0] is False)
b = K.coherent(CO, ["bad.py"])
ok("coherent: a Python syntax error", b[0] is False and "bad.py" in b[1], b)
is_("coherent: a good .py and .json", K.coherent(CO, ["ok.py", "ok.json"]), (True, ""))
b = K.coherent(CO, ["bad.json"])
ok("coherent: a JSON parse error", b[0] is False and "bad.json" in b[1], b)
is_("coherent: a file of no known kind, a path that is gone and a symlink are fine", K.coherent(CO, ["plain.txt", "nothere.sh", "link.sh"]), (True, ""))
ok("coherent (F2): an extensionless script with a python shebang gets Python's check", K.coherent(CO, ["pyscript"])[0] is False)
ok("coherent (F2): one with #!/bin/sh gets bash -n", K.coherent(CO, ["shscript"])[0] is False)
b = K.coherent(CO, ["pybang.sh"])
ok("coherent: the shebang wins over the extension (a .sh file run by python3 is checked as Python)", b[0] is False and "pybang.sh" in b[1], b)

NOTOOLS = os.path.join(ROOT, "notools")
os.makedirs(NOTOOLS)
notes = []
old_path = os.environ["PATH"]
os.environ["PATH"] = NOTOOLS
try:
    got = K.coherent(CO, ["ok.sh"], notes)
    put(CO, "x.rb", "def (\n")
    got_rb = K.coherent(CO, ["x.rb"], notes)
finally:
    os.environ["PATH"] = old_path
is_("tools: a syntax check whose tool is missing passes but is named in the notes", (got, got_rb, sorted(notes)), ((True, ""), (True, ""), ["bash not found", "ruby not found"]))

# ================================================================ removed_names
pd = lambda name, body, start=1, old=0: "diff --git a/{0} b/{0}\n--- a/{0}\n+++ b/{0}\n@@ -{2},{3} +{2},{1} @@\n".format(
    name, len([x for x in body.splitlines() if not x.startswith("-")]), start, old) + body
is_("lexical: names a revert removes, by file kind: Python def, class, top-level assignment; net of what the fix also removed",
    K.removed_names(pd("m.py", "+def f(x):\n+    pass\n+class K:\n+X = 1\n+    cleanup()\n-def f(x):\n")), ["K", "X"])
is_("lexical: a bare call in a .py file and a key in a .toml file define nothing", (K.removed_names(pd("m.py", "+    cleanup()\n")),
                                                                                    K.removed_names(pd("c.toml", "+timeout = 30\n"))), ([], []))
is_("lexical: shell functions in .sh, by shebang, and under zsh/functions",
    (K.removed_names(pd("a.sh", "+k() {\n+function g {\n")), K.removed_names(pd("run", "+#!/bin/bash\n+k2() {\n")),
     K.removed_names(pd("dot_config/zsh/functions/z", "+zf() {\n"))), (["g", "k"], ["k2"], ["zf"]))
is_("lexical: nothing from a .py file that is a shell function", K.removed_names(pd("m.py", "+k() {\n")), [])
is_("lexical: Ruby def, class and module; Rust fn; JS function and X = (", (K.removed_names(pd("a.rb", "+def self.go\n+class A\n+module M\n")),
    K.removed_names(pd("a.rs", "+pub fn go() {\n")), K.removed_names(pd("a.ts", "+export function f() {}\n+const h = (x) => x\n"))), (["A", "M", "go"], ["go"], ["f", "h"]))
is_("lexical: and nothing from YAML, INI, JSON or Markdown", [K.removed_names(pd(n, "+x = 1\n+def y\n+k() {\n")) for n in ("a.yml", "a.ini", "a.json", "a.md")], [[]] * 4)
is_("lexical (F2): a new file with a non-shell shebang on line 1 is read by that shebang, then its extension",
    (K.removed_names(pd("helper.py", "+#!/usr/bin/env python3\n+def helper():\n+    return 1\n")), K.removed_names(pd("lib.sh", "+#!/bin/sh\n+helper() {\n+  :\n+}\n")),
     K.removed_names(pd("a.rb", "+#!/usr/bin/env ruby\n+def helper\n+end\n")), K.removed_names(pd("tool", "+#!/usr/bin/env python3\n+def helper():\n"))),
    (["helper"], ["helper"], ["helper"], ["helper"]))

# an extensionless script whose function the fix added in the middle: only the work tree's first line tells its kind
W = helpers.make_repo(ROOT, "work")
TOOL = "dot_local/bin/executable_tool"
put(W, TOOL, "#!/bin/bash\n" + "".join("echo {}\n".format(i) for i in range(2, 40)))
put(W, "dot_local/bin/executable_other", "#!/bin/bash\n. tool\nhelper_fn\n")
put(W, "notes/zf.txt", "nothing here\n")
helpers.commit(W, "the tree after the revert")
mid = pd(TOOL, "+helper_fn() {\n+  echo hi\n+}\n", start=40, old=0)
is_("lexical (F2): the patch alone does not show line 1 of an extensionless script", K.removed_names(mid), [])
is_("lexical (F2): the work tree's file does: its shebang makes the added function a definition", K.removed_names(mid, W), ["helper_fn"])
is_("dangling (F2): so a revert that removes it while another script still calls it is found", K.dangling(W, mid, [TOOL]),
    (False, "helper_fn is still used by dot_local/bin/executable_other"))
gone = pd("helper.py", "+#!/usr/bin/env python3\n+def helper():\n+    return 1\n")
put(W, "uses.py", "from helper import helper\n")
git(W, "add", "uses.py")
is_("dangling: a file the revert deletes is read by its line 1 in the patch", K.dangling(W, gone, ["helper.py"]), (False, "helper is still used by uses.py"))
is_("dangling: a name nobody uses is fine", K.dangling(W, pd("lib.sh", "+#!/bin/sh\n+lonely_fn() {\n+}\n"), ["lib.sh"]), (True, ""))
