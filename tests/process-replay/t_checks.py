import os
import sys
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import checks as K  # noqa: E402

ROOT = helpers.tmp_root()
STATE = os.path.join(ROOT, "state")
ENV = K.tool_env(STATE)

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
is_("coherent: a good .sh file", K.coherent(CO, ["ok.sh"], ENV), (True, ""))
b = K.coherent(CO, ["bad.sh"], ENV)
ok("coherent: bash -n on a .sh file", b[0] is False and "bad.sh" in b[1], b)
ok("coherent: bash -n on a bash shebang", K.coherent(CO, ["shebang"], ENV)[0] is False)
ok("coherent: zsh -n on a zsh shebang", K.coherent(CO, ["zshbang"], ENV)[0] is False)
ok("coherent: zsh -n on a file under zsh/functions", K.coherent(CO, ["dot_config/zsh/functions/fn"], ENV)[0] is False)
b = K.coherent(CO, ["bad.py"], ENV)
ok("coherent: a Python syntax error", b[0] is False and "bad.py" in b[1], b)
is_("coherent: a good .py and .json", K.coherent(CO, ["ok.py", "ok.json"], ENV), (True, ""))
b = K.coherent(CO, ["bad.json"], ENV)
ok("coherent: a JSON parse error", b[0] is False and "bad.json" in b[1], b)
is_("coherent: a file of no known kind, a path that is gone and a symlink are fine", K.coherent(CO, ["plain.txt", "nothere.sh", "link.sh"], ENV), (True, ""))
ok("coherent (F2): an extensionless script with a python shebang gets Python's check", K.coherent(CO, ["pyscript"], ENV)[0] is False)
ok("coherent (F2): one with #!/bin/sh gets bash -n", K.coherent(CO, ["shscript"], ENV)[0] is False)
b = K.coherent(CO, ["pybang.sh"], ENV)
ok("coherent: the shebang wins over the extension (a .sh file run by python3 is checked as Python)", b[0] is False and "pybang.sh" in b[1], b)

NOTOOLS = os.path.join(ROOT, "notools")
os.makedirs(NOTOOLS)
notes = []
old_path = os.environ["PATH"]
os.environ["PATH"] = NOTOOLS
try:
    ENV = K.tool_env(STATE)
    got = K.coherent(CO, ["ok.sh"], ENV, notes)
    put(CO, "x.rb", "def (\n")
    got_rb = K.coherent(CO, ["x.rb"], ENV, notes)
finally:
    os.environ["PATH"] = old_path
    ENV = K.tool_env(STATE)
is_("tools: a syntax check whose tool is missing passes but is named in the notes", (got, got_rb, sorted(notes)), ((True, ""), (True, ""), ["bash not found", "ruby not found"]))

# ================================================================ mise configuration (spec 14.1)
STUB = os.path.join(ROOT, "stub")
for tool in ("python3", "ruby", "cargo"):
    put(STUB, tool, """#!/bin/bash
d=$(pwd -P)
while [ "$d" != / ] && [ ! -e "$d/mise.toml" ]; do d=$(dirname "$d"); done
[ -e "$d/mise.toml" ] || exit 0
IFS=: read -ra P <<< "$MISE_IGNORED_CONFIG_PATHS"
for p in "${P[@]}"; do
  [ -n "$p" ] || continue
  r=$(cd "$p" 2>/dev/null && pwd -P) || r=$p
  case "$d/" in "$r"/*) exit 0;; esac
done
echo "mise ERROR Config files in $d/mise.toml are not trusted." >&2
exit 1
""", 0o755)
S = os.path.join(ROOT, "mise")
saved = dict((k, os.environ.get(k)) for k in ("MISE_IGNORED_CONFIG_PATHS", "XDG_STATE_HOME", "PATH"))
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "xdg")
os.environ["MISE_IGNORED_CONFIG_PATHS"] = "/inherited"
got = K.tool_env(S)["MISE_IGNORED_CONFIG_PATHS"].split(":")
is_("tool_env_paths: the state directory, the review scratch directory, then the inherited entries", got,
    [os.path.abspath(S), os.path.join(ROOT, "xdg", "review-work", "scratch"), "/inherited"])
is_("tool_env_paths: os.environ is not changed", os.environ["MISE_IGNORED_CONFIG_PATHS"], "/inherited")
os.environ["MISE_IGNORED_CONFIG_PATHS"] = os.path.abspath(S) + ":/inherited"
is_("tool_env_paths: an inherited entry already there is not repeated", K.tool_env(S)["MISE_IGNORED_CONFIG_PATHS"].split(":"),
    [os.path.abspath(S), os.path.join(ROOT, "xdg", "review-work", "scratch"), "/inherited"])
del os.environ["MISE_IGNORED_CONFIG_PATHS"]
is_("tool_env_paths: with nothing inherited, two entries", len(K.tool_env(S)["MISE_IGNORED_CONFIG_PATHS"].split(":")), 2)

W = os.path.join(S, "work", "b")
for path, text in {"mise.toml": "[env]\nX = \"1\"\n", "ok.py": "x = 1\n", "ok.rb": "x = 1\n"}.items():
    put(W, path, text)
os.environ["PATH"] = STUB + os.pathsep + saved["PATH"]
try:
    is_("untrusted_mise_toml: with the work tree's directory ignored, the checks pass", K.coherent(W, ["ok.py", "ok.rb"], K.tool_env(S)), (True, ""))
    bare = dict((k, v) for k, v in os.environ.items() if k != "MISE_IGNORED_CONFIG_PATHS")
    b = K.coherent(W, ["ok.py", "ok.rb"], bare)
    ok("untrusted_mise_toml: without it the stub shim refuses (the failure of spec 11.4)", b[0] is False and b[1].startswith("ok.py: mise ERROR Config files in ")
       and b[1].endswith("are not trusted."), b)
    is_("untrusted_mise_toml: cargo check runs with it too", K.cargo_check(Namespace(state=S, budget=60), W, "r")[0], True)
finally:
    for k, v in saved.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
ENV = K.tool_env(STATE)

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
