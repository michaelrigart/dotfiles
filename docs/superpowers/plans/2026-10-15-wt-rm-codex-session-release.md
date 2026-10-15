# wt-rm Codex Session Release Implementation Plan

**Status:** Completed 2026-10-15 on branch `feat/wt-rm-codex-session-release` (Tasks 1–4). Do not execute again.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `wt-rm` unloads the Codex sessions of the checkout it retires (archive, then restore), so the daemon's MCP helpers no longer make check 4 refuse.

**Architecture:** A new `xreview-rpc release --dir <dir>` subcommand does the daemon work under a global `flock`, with a pending-restore record per archived thread so a restore is never lost. `wt-rm` calls it between check 3 and check 4 and continues only on exit 0 or 5.

**Tech Stack:** Python 3.9 standard library (`/usr/bin/python3`), zsh, bash test suites.

**Spec:** `docs/superpowers/specs/2026-10-15-wt-rm-codex-session-release-design.md` (Approved). Read it before your task; section and fact numbers (§1, C4, …) below refer to it.

## Global Constraints

- `xreview-rpc` keeps its shebang `#!/usr/bin/python3`. That interpreter is Python 3.9.6: no `match`, no `X | Y` type syntax, standard library only.
- Message texts are the spec's, verbatim (§1, §2). `xreview-rpc` diagnostics go to stderr through its existing `err()` (which prefixes `xreview-rpc: `); stdout carries only `released <id>` lines.
- `release` exit codes: 0 ok, 1 refused or failed, 2 usage, 5 daemon unreachable with no record pending under `--dir` (§1).
- `wt-rm` continues only on release exit 0 or 5; every other status refuses and keeps the worktree and branch (§2).
- State lives under `${XDG_STATE_HOME:-$HOME/.local/state}/xreview-rpc/`: `release.lock` and `release-pending/<thread-id>` (§1).
- Run suites by executing them, never through an interpreter: `./tests/run.sh xreview-rpc`, `./tests/run.sh wt-functions`. `wt-functions` is zsh; `bash tests/…` reports bogus failures.
- Report test totals as passed/total.
- Implementers do not commit and run only their own task's suite; the controller commits each task on its own.
- Match the surrounding code: these files carry explanatory comments on non-obvious decisions, and new code does the same at the same density.
- This checkout is shared. The controller re-checks `git branch --show-current` (`feat/wt-rm-codex-session-release`) right before every commit.

## Review Focus

1. A thread id from the daemon that is not a plain id (`../evil`, `a/b`) must never become a path: refuse before writing a record or archiving. Pinned in Task 1 (helper) and Task 2 (flow).
2. A recorded `cwd` that no longer exists, a `--dir` with a trailing slash, or a `--dir` reached through a symlink must select exactly the same threads as the plain path. Pinned in Task 1.
3. A corrupt pending record must fail closed (exit 1 naming the file), never be skipped. Pinned in Task 1 (helper) and Task 2 (flow).
4. A `--dir` that is not an existing directory is a usage error (exit 2) and sends nothing to the daemon. Pinned in Task 2.
5. `wt-rm` must hand `$dest` to the release as exactly one argument. Pinned in Task 3 (the stub logs one argument per line).

## Batches

- Batch 1: Task 1 and Task 3, in parallel (disjoint files; `wt-functions` stubs `xreview-rpc` and never loads it).
- Batch 2: Task 2.
- Batch 3: Task 4.

---

### Task 1: `xreview-rpc` release building blocks

**Depends on:** none

**Files:**
- Modify: `dot_local/bin/executable_xreview-rpc` (imports; new helpers after `cmd_thread_archive`)
- Test: `tests/xreview-rpc.test.sh` (new section `R0`, inserted right before the suite's final summary)

**Interfaces:**
- Produces (module-level, used by Task 2 and Task 4):
  - `SOURCE_KINDS`: tuple of the ten `ThreadSourceKind` strings.
  - `class RecordError(Exception)`.
  - `state_dir() -> str`: `$XDG_STATE_HOME/xreview-rpc`, default `~/.local/state/xreview-rpc`.
  - `under(path: str, d: str) -> bool`.
  - `take_lock(sd: str, deadline: float) -> int | None` (an fd, or `None` when still held at `deadline`; raises `OSError` when the directory or lock file cannot be made). When `XREVIEW_RPC_LOCK_BUSY_MARK` names a file, it touches that file the first time it finds the lock busy (a test hook; Task 2's R17 relies on it).
  - `write_record(sd, tid, cwd)`, `drop_record(sd, tid)`, `read_records(sd) -> list[tuple[str, str]]` (sorted by id; raise `RecordError` for a bad id or unreadable record).
  - `archived(c, tid, cwd) -> True | False | None` (`None`: a page could not be read).
  - `loaded_ids(c) -> list[str] | None`.

- [ ] **Step 1: Write the failing tests**

Append this section to `tests/xreview-rpc.test.sh` just before its final summary lines (the `printf` of the pass/fail totals):

```bash
echo "R0. release building blocks"
export XDG_STATE_HOME="$T/state"
W="$(mkdir -p "$T/w/repo/sub" "$T/w/repo-x" && cd "$T/w" && pwd -P)"
ln -s "$W/repo" "$T/w/link"
load='import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("xreview_rpc", sys.argv[1])
spec = importlib.util.spec_from_loader("xreview_rpc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)'

out="$(python3 - "$RPC" "$W" "$T/w/link" <<PY
$load
w, link = sys.argv[2], sys.argv[3]
cases = [
    (w + "/repo", w + "/repo", True),
    (w + "/repo/sub", w + "/repo", True),
    (w + "/repo/gone/deeper", w + "/repo", True),   # a cwd that no longer exists
    (w + "/repo-x", w + "/repo", False),            # a sibling sharing the prefix
    (w + "/repo", w + "/repo-x", False),
    (w + "/repo", w + "/repo/", True),              # trailing slash on the dir
    (w + "/repo/sub", link, True),                  # the dir through a symlink
    (w, w + "/repo", False),                        # a parent is not under its child
]
bad = [c for c in cases if m.under(c[0], c[1]) != c[2]]
print("ok" if not bad else "bad " + repr(bad))
PY
)"
is "under() compares whole components, through symlinks, trailing slashes and missing paths" "$out" ok

rm -rf "$XDG_STATE_HOME"
out="$(python3 - "$RPC" "$XDG_STATE_HOME" <<PY
$load
import os
sd = m.state_dir()
ok = sd == os.path.join(sys.argv[2], "xreview-rpc")
m.write_record(sd, "th-1", "/x/repo")
m.write_record(sd, "th-2", "/x/repo-x")
ok &= m.read_records(sd) == [("th-1", "/x/repo"), ("th-2", "/x/repo-x")]
m.drop_record(sd, "th-1"); m.drop_record(sd, "th-1")   # dropping twice is harmless
ok &= m.read_records(sd) == [("th-2", "/x/repo-x")]
for bad_id in ("../evil", "a/b", "", ".hidden"):
    try:
        m.write_record(sd, bad_id, "/x"); ok = False
    except m.RecordError:
        pass
ok &= not os.path.exists(os.path.join(sd, "evil"))
pend = os.path.join(sd, "release-pending")
open(os.path.join(pend, "th-4.tmp"), "w").write("{")   # a write that never finished
ok &= m.read_records(sd) == [("th-2", "/x/repo-x")]
open(os.path.join(pend, "th-3"), "w").write("not json")
try:
    m.read_records(sd); ok = False
except m.RecordError as e:
    ok &= "th-3" in str(e)
print("ok" if ok else "bad")
PY
)"
is "records round-trip, refuse non-id names, skip unfinished writes, fail on corrupt ones" "$out" ok

rm -rf "$XDG_STATE_HOME"
out="$(python3 - "$RPC" <<PY
$load
import os, subprocess, time
sd = m.state_dir()
fd = m.take_lock(sd, time.monotonic() + 1)
ok = fd is not None
probe = "import fcntl,os,sys; fd=os.open(sys.argv[1], os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)"
lock = os.path.join(sd, "release.lock")
ok &= subprocess.run([sys.executable, "-c", probe, lock], stderr=subprocess.DEVNULL).returncode != 0
os.close(fd)
holder = subprocess.Popen([sys.executable, "-c",
    "import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX); print('held', flush=True); time.sleep(30)",
    lock], stdout=subprocess.PIPE)
holder.stdout.readline()
t0 = time.monotonic()
ok &= m.take_lock(sd, time.monotonic() + 0.4) is None
ok &= time.monotonic() - t0 >= 0.4
holder.kill(); holder.wait()
fd = m.take_lock(sd, time.monotonic() + 1)
ok &= fd is not None   # SIGKILL freed it
os.close(fd)
# A waiter whose holder lets go before the deadline gets the lock in that same call. The
# holder lets go only once the busy mark shows the waiter has met it, so no timing is assumed.
mark = os.path.join(os.path.dirname(sd), "busy-mark")
os.environ["XREVIEW_RPC_LOCK_BUSY_MARK"] = mark
holder = subprocess.Popen([sys.executable, "-c",
    "import fcntl,os,sys,time\n"
    "fd=os.open(sys.argv[1], os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX); print('held', flush=True)\n"
    "while not os.path.exists(sys.argv[2]): time.sleep(0.02)",
    lock, mark], stdout=subprocess.PIPE)
holder.stdout.readline()
fd = m.take_lock(sd, time.monotonic() + 30)
ok &= fd is not None and os.path.exists(mark)
holder.wait()
del os.environ["XREVIEW_RPC_LOCK_BUSY_MARK"]
print("ok" if ok else "bad")
PY
)"
is "the lock is exclusive across processes, times out, is freed by a killed holder, and is taken once freed" "$out" ok

: > "$T/afile"
out="$(XDG_STATE_HOME="$T/afile" python3 - "$RPC" <<PY
$load
import time
try:
    m.take_lock(m.state_dir(), time.monotonic() + 1); print("bad")
except OSError:
    print("ok")
PY
)"
is "a state directory that cannot be created raises OSError" "$out" ok

scenario '{"responses":{"thread/list":[{"result":{"data":[{"id":"other"}],"nextCursor":"p2"}},{"result":{"data":[{"id":"th"}]}}]}}'
out="$(python3 - "$RPC" <<PY
$load
print(m.archived(m.Client(), "th", "/x/repo"))
PY
)"
is "archived() follows pages and finds the thread" "$out" True
is "it asks for archived threads of the exact cwd, all ten source kinds" \
   "$(params thread/list | jq -c '[.archived, .cwd, (.sourceKinds | length)]')" '[true,["/x/repo"],10]'
is "the second page is asked for by cursor" \
   "$(jq -c 'select(.method == "thread/list") | .params.cursor' "$FAKE_LOG" | tail -1)" '"p2"'
scenario '{"responses":{"thread/list":{"result":{"data":[]}}}}'
is "archived() is False when the listing lacks the thread" \
   "$(python3 - "$RPC" <<PY
$load
print(m.archived(m.Client(), "th", "/x/repo"))
PY
)" False
scenario '{"responses":{"thread/list":{"error":{"code":-1,"message":"nope"}}}}'
is "archived() is None when the listing fails" \
   "$(python3 - "$RPC" <<PY
$load
print(m.archived(m.Client(), "th", "/x/repo"))
PY
)" None

scenario '{"responses":{"thread/loaded/list":[{"result":{"data":["a"],"nextCursor":"c"}},{"result":{"data":[{"id":"b"}]}}]}}'
is "loaded_ids() follows pages and accepts ids or objects" \
   "$(python3 - "$RPC" <<PY
$load
print(m.loaded_ids(m.Client()))
PY
)" "['a', 'b']"
scenario '{"responses":{"thread/loaded/list":{"error":{"code":-1,"message":"nope"}}}}'
is "loaded_ids() is None when a page fails" \
   "$(python3 - "$RPC" <<PY
$load
print(m.loaded_ids(m.Client()))
PY
)" None
unset XDG_STATE_HOME
```

- [ ] **Step 2: Run the suite to verify the new tests fail**

Run: `./tests/run.sh xreview-rpc`
Expected: the `R0` cases FAIL (`AttributeError: module 'xreview_rpc' has no attribute 'under'` and similar); every earlier case still passes.

- [ ] **Step 3: Implement the helpers**

In `dot_local/bin/executable_xreview-rpc`, add `import fcntl` to the import block (alphabetical, after `import base64`). Then insert after `cmd_thread_archive`:

```python
# --- release (spec: docs/superpowers/specs/2026-10-15-wt-rm-codex-session-release-design.md)

# Every ThreadSourceKind of the protocol schema. thread/list without sourceKinds lists only
# interactive sources (C9), so a confirmation that omitted them could miss an archived thread.
SOURCE_KINDS = ("cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
                "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown")
# A thread id becomes a file name under release-pending/, so it must be one plain name.
THREAD_ID = re.compile(r"^[0-9A-Za-z][0-9A-Za-z_-]*$")


class RecordError(Exception):
    pass


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "xreview-rpc")


def under(path, d):
    """True when path is d or lies below it, by real path, whole components at a time:
    repo and repo-x are neighbours by construction."""
    p, r = os.path.realpath(path), os.path.realpath(d)
    return p == r or p.startswith(r.rstrip(os.sep) + os.sep)


def take_lock(sd, deadline):
    """The exclusive release lock's fd, or None if another process still holds it at deadline.
    flock is dropped by the kernel when the holder dies, however it dies, so it never goes
    stale. Raises OSError when the state directory or the lock file cannot be made."""
    os.makedirs(sd, exist_ok=True)
    fd = os.open(os.path.join(sd, "release.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    # For the test suites only: a file touched the first time the lock is found busy, so a
    # test can see the wait begin instead of guessing it from elapsed time.
    mark = os.environ.get("XREVIEW_RPC_LOCK_BUSY_MARK")
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if mark:
                open(mark, "w").close()
                mark = None
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.2)


def _record_path(sd, tid):
    if not isinstance(tid, str) or not THREAD_ID.match(tid):
        raise RecordError(f"refusing an unexpected thread id: {tid!r}")
    return os.path.join(sd, "release-pending", tid)


def write_record(sd, tid, cwd):
    """Record that tid may be archived, before it is. Written whole or not at all: a .tmp
    left by a crash means the archive was never sent."""
    path = _record_path(sd, tid)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"cwd": cwd}, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def drop_record(sd, tid):
    try:
        os.remove(_record_path(sd, tid))
    except FileNotFoundError:
        pass


def read_records(sd):
    """[(thread id, recorded cwd)] for every pending record, sorted by id. A record that
    cannot be read raises RecordError: its cwd, and so its scope, is unknown."""
    d = os.path.join(sd, "release-pending")
    try:
        names = sorted(os.listdir(d))
    except FileNotFoundError:
        return []
    out = []
    for name in names:
        if name.endswith(".tmp"):
            continue
        path = os.path.join(d, name)
        try:
            with open(path, encoding="utf-8") as fh:
                cwd = json.load(fh).get("cwd")
        except (OSError, ValueError, AttributeError) as e:
            raise RecordError(f"cannot read pending record {path}: {e}")
        if not THREAD_ID.match(name) or not isinstance(cwd, str) or not cwd:
            raise RecordError(f"malformed pending record {path}")
        out.append((name, cwd))
    return out


def archived(c, tid, cwd):
    """Whether thread/list shows tid archived (C9): True, False, or None when a page cannot
    be read. Only False confirms a restore; thread/unarchive's own answer cannot (C5)."""
    cursor = None
    while True:
        p = {"archived": True, "cwd": [cwd], "sourceKinds": list(SOURCE_KINDS)}
        if cursor:
            p["cursor"] = cursor
        r = c.call("thread/list", p)
        if "error" in r:
            return None
        res = r.get("result") or {}
        if any(isinstance(t, dict) and t.get("id") == tid for t in res.get("data") or []):
            return True
        cursor = res.get("nextCursor")
        if not cursor:
            return False


def loaded_ids(c):
    """Every loaded thread id, following nextCursor; None when a page cannot be read."""
    ids, cursor = [], None
    while True:
        r = c.call("thread/loaded/list", {"cursor": cursor} if cursor else {})
        if "error" in r:
            return None
        res = r.get("result") or {}
        for t in res.get("data") or []:
            tid = t.get("id") if isinstance(t, dict) else t
            if isinstance(tid, str):
                ids.append(tid)
        cursor = res.get("nextCursor")
        if not cursor:
            return ids
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./tests/run.sh xreview-rpc`
Expected: every case PASS, including all `R0` cases. Report passed/total.

- [ ] **Step 5: Hand back to the controller** (no commit). The controller commits:

```bash
git add dot_local/bin/executable_xreview-rpc tests/xreview-rpc.test.sh
git commit -m "Add the release building blocks to xreview-rpc"
```

---

### Task 2: `xreview-rpc release --dir`

**Depends on:** Task 1

**Files:**
- Modify: `dot_local/bin/executable_xreview-rpc` (docstring; `cmd_release`, `release`, `owed` after Task 1's helpers; `main()`)
- Modify: `docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md` (amendment banner under `### 7.1 \`xreview-rpc\``)
- Test: `tests/xreview-rpc.test.sh` (header comment; new section `R`, after `R0`)

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces: the CLI `xreview-rpc release --dir <dir>` with the exit codes of Global Constraints; stdout `released <id>` lines. Task 3 relies on these through a stub, Task 4 against the real daemon. Environment overrides for tests: `XREVIEW_RPC_RELEASE_DEADLINE` (seconds, default 120), `XREVIEW_RPC_EPHEMERAL_WAIT` (default 90), `XREVIEW_RPC_EPHEMERAL_POLL` (default 2).

- [ ] **Step 1: Write the failing tests**

Change the suite's first comment line to `# Tests dot_local/bin/executable_xreview-rpc, the dotfiles' client for the Codex daemon`. Then append after section `R0`:

```bash
echo "R. release --dir"
export XDG_STATE_HOME="$T/state"
PEND="$XDG_STATE_HOME/xreview-rpc/release-pending"
pending() { ls "$PEND" 2>/dev/null | grep -v '\.tmp$' | tr '\n' ' ' | sed 's/ $//'; }
record() { mkdir -p "$PEND"; printf '{"cwd":"%s"}' "$2" > "$PEND/$1"; }   # record <id> <cwd>
methods() { jq -r 'select(.id != null and .method != "initialize") | .method + " " + (.params.threadId // "")' "$FAKE_LOG" | tr '\n' '|'; }
th() { # th <id> <cwd> <status> [ephemeral]
  jq -nc --arg id "$1" --arg cwd "$2" --arg s "$3" --argjson e "${4:-false}" \
    '{result:{thread:{id:$id,cwd:$cwd,status:{type:$s},ephemeral:$e}}}'
}
NOTARCH='{"result":{"data":[]}}'
ARCH() { printf '{"result":{"data":[{"id":"%s"}]}}' "$1"; }
ERR='{"error":{"code":-1,"message":"nope"}}'
fresh() { rm -rf "$XDG_STATE_HOME"; }

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson b "$(th b "$W/repo/sub" idle)" \
  --argjson x "$(th x "$W/repo-x" idle)" --argjson n "$NOTARCH" \
  '{responses:{"thread/loaded/list":{result:{data:["a","b","x"]}},"thread/read":[$a,$b,$x],"thread/list":$n}}')"
out="$(rpc release --dir "$T/w/link")"; rc=$?
is "R1 release exits 0 once every selected thread is released" "$rc" 0
is "R1 the checkout and its subdirectory are selected, the prefix sibling is not" "$out" $'released a\nreleased b'
is "R1 each thread is archived, restored, then confirmed, in that order" "$(methods)" \
   "thread/loaded/list |thread/read a|thread/read b|thread/read x|thread/archive a|thread/unarchive a|thread/list |thread/archive b|thread/unarchive b|thread/list |"
is "R1 no record is left" "$(pending)" ""

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson b "$(th b "$W/repo" idle)" --argjson n "$NOTARCH" \
  '{responses:{"thread/loaded/list":[{result:{data:["a"],nextCursor:"c"}},{result:{data:["b"]}}],"thread/read":[$a,$b],"thread/list":$n}}')"
is "R2 loaded threads are read across pages" "$(rpc release --dir "$W/repo")" $'released a\nreleased b'

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson b "$(th b "$W/repo" active)" \
  '{responses:{"thread/loaded/list":{result:{data:["a","b"]}},"thread/read":[$a,$b]}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R3 a running thread refuses (1)" "$rc" 1
grep -q "b is running a turn — let it finish, or open it with codex resume b and interrupt it" "$T/err" \
  && _pass "R3 the refusal names the running thread" || _fail "R3 the refusal names the running thread" "$(cat "$T/err")"
is "R3 nothing is archived" "$(grep -c 'thread/archive' "$FAKE_LOG")" 0

fresh
scenario "$(jq -nc --argjson e "$ERR" '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$e}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R4 an unreadable thread that is still loaded refuses (1)" "$rc" 1
grep -q "cannot read Codex session a" "$T/err" && _pass "R4 the refusal names it" || _fail "R4 the refusal names it" "$(cat "$T/err")"
is "R4 nothing is archived" "$(grep -c 'thread/archive' "$FAKE_LOG")" 0
scenario "$(jq -nc --argjson e "$ERR" '{responses:{"thread/loaded/list":[{result:{data:["a"]}},{result:{data:[]}}],"thread/read":$e}}')"
out="$(rpc release --dir "$W/repo")"; rc=$?
is "R4 an unreadable thread that has since unloaded is skipped" "$rc:$out" "0:"

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson e "$ERR" --argjson n "$NOTARCH" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/archive":$e,"thread/list":$n}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R5 a failed archive exits 1" "$rc" 1
grep -q "a: archive failed: nope" "$T/err" && _pass "R5 the failure names the thread" || _fail "R5 the failure names the thread" "$(cat "$T/err")"
is "R5 a thread confirmed not archived has its record dropped" "$(pending)" ""
fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson e "$ERR" --argjson l "$(ARCH a)" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/archive":$e,"thread/list":$l}}')"
rpc release --dir "$W/repo" 2>/dev/null
is "R5 a failed archive that did archive keeps the record" "$(pending)" a

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson e "$ERR" --argjson l "$(ARCH a)" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/unarchive":$e,"thread/list":$l}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R6 an unconfirmed restore exits 1" "$rc" 1
grep -q "a is archived and could not be restored yet" "$T/err" && _pass "R6 it says the restore is owed" || _fail "R6 it says the restore is owed" "$(cat "$T/err")"
is "R6 the record is kept" "$(pending)" a
fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson e "$ERR" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/list":$e}}')"
rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R6 a failed confirmation listing exits 1 and keeps the record" "$rc:$(pending)" "1:a"

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson n "$NOTARCH" \
  '{runs:[{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a},drop_on:["thread/unarchive"]},
          {responses:{"thread/loaded/list":{result:{data:[]}},"thread/list":$n}}]}')"
rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R7 a connection lost after archive exits 1, not 5" "$rc" 1
is "R7 the record survives the lost connection" "$(pending)" a
: > "$FAKE_LOG"
out="$(rpc release --dir "$W/repo")"; rc=$?
is "R7 the next run restores it first, then finds nothing loaded" "$rc:$out" "0:"
is "R7 the restore precedes the selection" "$(methods)" "thread/unarchive a|thread/list |thread/loaded/list |"
is "R7 the record is gone" "$(pending)" ""

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a},drop_on:["thread/archive"]}')"
rpc release --dir "$W/repo" 2>/dev/null
is "R8 the record is written before the archive is sent" "$(pending)" a

fresh
record a "$W/repo"
scenario "$(jq -nc --argjson n "$NOTARCH" '{responses:{"thread/unarchive":{error:{code:-32600,message:"no archived rollout found for thread id a"}},"thread/list":$n,"thread/loaded/list":{result:{data:[]}}}}')"
rpc release --dir "$W/repo"; rc=$?
is "R9 'no archived rollout found' with the listing clear counts as restored" "$rc:$(pending)" "0:"

fresh
record a "$W/repo"
XREVIEW_RPC_STDIO=false rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R10 an unreachable daemon with a restore owed under --dir exits 1, not 5" "$rc" 1
grep -q "a is archived and could not be restored yet" "$T/err" && _pass "R10 it names the owed restore" || _fail "R10 it names the owed restore" "$(cat "$T/err")"
fresh
record x "$W/repo-x"
XREVIEW_RPC_STDIO=false rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R10 a record for another directory does not turn unreachable into 1" "$rc" 5
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
rpc release --dir "$W/repo"; rc=$?
is "R10 a record for another directory is left alone" "$rc:$(pending):$(grep -c 'thread/unarchive' "$FAKE_LOG")" "0:x:0"

fresh
scenario "$(jq -nc --argjson e "$(th e "$W/repo" idle true)" \
  '{responses:{"thread/loaded/list":[{result:{data:["e"]}},{result:{data:["e"]}},{error:{code:-1,message:"x"}},{result:{data:[]}}],"thread/read":$e}}')"
out="$(XREVIEW_RPC_EPHEMERAL_POLL=0.01 rpc release --dir "$W/repo" 2>"$T/err")"; rc=$?
is "R11 an ephemeral thread is waited out, a failed poll counting as loaded" "$rc:$out" "0:released e"
grep -q "waiting for ephemeral e to unload (up to 90 s)" "$T/err" && _pass "R11 the wait is announced" || _fail "R11 the wait is announced" "$(cat "$T/err")"
is "R11 an ephemeral thread is never archived" "$(grep -c 'thread/archive' "$FAKE_LOG")" 0
scenario "$(jq -nc --argjson e "$(th e "$W/repo" idle true)" '{responses:{"thread/loaded/list":{result:{data:["e"]}},"thread/read":$e}}')"
XREVIEW_RPC_EPHEMERAL_WAIT=0.2 XREVIEW_RPC_EPHEMERAL_POLL=0.05 rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R11 an ephemeral thread still loaded at the end of the wait exits 1" "$rc" 1
grep -q "e (ephemeral) is still loaded — close the Codex client using it" "$T/err" && _pass "R11 it names the thread" || _fail "R11 it names the thread" "$(cat "$T/err")"

fresh
scenario "$(jq -nc --argjson x "$(th x "$W/repo-x" idle)" '{responses:{"thread/loaded/list":{result:{data:["x"]}},"thread/read":$x}}')"
out="$(rpc release --dir "$W/repo")"; rc=$?
is "R12 nothing under --dir: exit 0, no output, nothing archived" "$rc:$out:$(grep -c 'thread/archive' "$FAKE_LOG")" "0::0"
XREVIEW_RPC_STDIO=false rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R12 an unreachable daemon with nothing owed exits 5" "$rc" 5

fresh
scenario "$(jq -nc --argjson a "$(th '../evil' "$W/repo" idle)" '{responses:{"thread/loaded/list":{result:{data:["../evil"]}},"thread/read":$a}}')"
rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R13 a thread id that is not a plain name refuses (1)" "$rc" 1
is "R13 it archives nothing and writes nothing outside the record directory" \
   "$(grep -c 'thread/archive' "$FAKE_LOG"):$(ls "$XDG_STATE_HOME/xreview-rpc" | tr '\n' ' ')" "0:release.lock "

fresh
mkdir -p "$PEND"; printf 'not json' > "$PEND/bad"
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R14 a corrupt pending record fails closed (1)" "$rc" 1
grep -q "bad" "$T/err" && _pass "R14 the error names the record" || _fail "R14 the error names the record" "$(cat "$T/err")"
is "R14 nothing is sent to the daemon" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 0

fresh
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
rpc release --dir "$W/nope" 2>/dev/null; rc=$?
is "R15 a --dir that is not a directory is a usage error (2)" "$rc:$(wc -l < "$FAKE_LOG" | tr -d ' ')" "2:0"

fresh
mkdir -p "$XDG_STATE_HOME/xreview-rpc"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(60)' \
  "$XDG_STATE_HOME/xreview-rpc/release.lock" "$T/held" &
holder=$!
for _ in $(seq 100); do [ -e "$T/held" ] && break; sleep 0.1; done
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
XREVIEW_RPC_RELEASE_DEADLINE=0.5 rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R16 a release still blocked on the lock at its deadline exits 1" "$rc" 1
grep -q "another release is running" "$T/err" && _pass "R16 it says why" || _fail "R16 it says why" "$(cat "$T/err")"
is "R16 it sent nothing to the daemon" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 0
kill -9 "$holder"; wait "$holder" 2>/dev/null
rpc release --dir "$W/repo"; is "R16 a holder killed with SIGKILL frees the lock" "$?" 0
: > "$T/afile"
XDG_STATE_HOME="$T/afile" rpc release --dir "$W/repo" 2>/dev/null; is "R16 an unusable state directory exits 1" "$?" 1

# The same waiting invocation must go on once the holder lets go: blocked, it sends nothing
# and writes no record; released, it does its whole job. The busy mark proves the waiter has
# met the lock before anything is asserted, and the holder lets go only after the assertions.
fresh
mkdir -p "$XDG_STATE_HOME/xreview-rpc"
rm -f "$T/held" "$T/go" "$T/busy"
python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close()
while not os.path.exists(sys.argv[3]): time.sleep(0.05)' \
  "$XDG_STATE_HOME/xreview-rpc/release.lock" "$T/held" "$T/go" &
holder=$!
for _ in $(seq 100); do [ -e "$T/held" ] && break; sleep 0.1; done
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson n "$NOTARCH" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/list":$n}}')"
XREVIEW_RPC_LOCK_BUSY_MARK="$T/busy" rpc release --dir "$W/repo" > "$T/waiter.out" 2>"$T/err" &
waiter=$!
for _ in $(seq 300); do [ -e "$T/busy" ] && break; sleep 0.1; done
is "R17 the release meets the held lock" "$([ -e "$T/busy" ] && echo yes || echo no)" yes
is "R17 while waiting it sends nothing and writes no record" "$(wc -l < "$FAKE_LOG" | tr -d ' '):$(pending)" "0:"
: > "$T/go"; wait "$holder" 2>/dev/null
wait "$waiter"; rc=$?
is "R17 once the holder lets go, the same release finishes" "$rc:$(cat "$T/waiter.out")" "0:released a"

# A deadline that has passed is exit 1, never the "unreachable" exit 5 that lets wt-rm go on.
fresh
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
XREVIEW_RPC_RELEASE_DEADLINE=0 rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R18 a deadline already passed when the lock is taken exits 1 and asks nothing" \
   "$rc:$(wc -l < "$FAKE_LOG" | tr -d ' ')" "1:0"
scenario '{"silent":["initialize"]}'
XREVIEW_RPC_RELEASE_DEADLINE=0.5 rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R18 a connection that runs out of deadline exits 1, not 5" "$rc" 1
unset XDG_STATE_HOME
```

- [ ] **Step 2: Run the suite to verify the new tests fail**

Run: `./tests/run.sh xreview-rpc`
Expected: the `R` cases FAIL (`invalid choice: 'release'`, exit 2); `R0` and every earlier case still pass.

- [ ] **Step 3: Implement the command**

Insert after Task 1's `loaded_ids`:

```python
def owed(records):
    for tid, _ in records:
        err(f"{tid} is archived and could not be restored yet")


def release(c, sd, d, mine):
    """Steps 1-5 of spec §1, on a connected client, with the lock held. mine: the pending
    records under d. Returns the exit status."""
    # 1. Finish earlier restores. thread/unarchive's answer is not evidence (C5); the
    #    archived listing is. Nothing more is archived while a restore is owed.
    left = []
    for tid, cwd in mine:
        c.call("thread/unarchive", {"threadId": tid})
        if archived(c, tid, cwd) is False:
            drop_record(sd, tid)
        else:
            left.append((tid, cwd))
    if left:
        owed(left)
        return 1

    # 2. Select the loaded threads under d. An id thread/read cannot answer for is unknown
    #    unless a second listing shows it gone.
    ids = loaded_ids(c)
    if ids is None:
        err("cannot list the loaded Codex sessions")
        return 1
    sel, unread = [], []
    for tid in ids:
        r = c.call("thread/read", {"threadId": tid, "includeTurns": False})
        th = None if "error" in r else (r.get("result") or {}).get("thread")
        if not isinstance(th, dict) or not isinstance(th.get("cwd"), str) or not th["cwd"]:
            unread.append(tid)
            continue
        if (th.get("status") or {}).get("type") == "notLoaded" or not under(th["cwd"], d):
            continue
        sel.append(dict(th, id=tid))
    if unread:
        again = loaded_ids(c)
        still = unread if again is None else [t for t in unread if t in again]
        if still:
            for tid in still:
                err(f"cannot read Codex session {tid}")
            return 1

    # 3. A running turn is never cut short.
    running = [th["id"] for th in sel if (th.get("status") or {}).get("type") == "active"]
    if running:
        for tid in running:
            err(f"{tid} is running a turn — let it finish, or open it with codex resume {tid} and interrupt it")
        return 1

    # 4. Saved threads: archive unloads at once (C4), unarchive restores (C5). The record is
    #    written first and dropped only on a confirmed restore.
    for th in sel:
        if th.get("ephemeral"):
            continue
        tid, cwd = th["id"], th["cwd"]
        write_record(sd, tid, cwd)
        r = c.call("thread/archive", {"threadId": tid})
        if "error" in r:
            if archived(c, tid, cwd) is False:
                drop_record(sd, tid)
            e = r["error"]
            err(f"{tid}: archive failed: {e.get('message', e) if isinstance(e, dict) else e}")
            return 1
        c.call("thread/unarchive", {"threadId": tid})
        if archived(c, tid, cwd) is not False:
            owed([(tid, cwd)])
            return 1
        drop_record(sd, tid)
        print(f"released {tid}", flush=True)

    # 5. Ephemeral threads cannot be archived (C6); only the daemon's idle timer (C2)
    #    unloads them. A failed poll counts as still loaded.
    eph = [th["id"] for th in sel if th.get("ephemeral")]
    if eph:
        wait = float(os.environ.get("XREVIEW_RPC_EPHEMERAL_WAIT", "90"))
        poll = float(os.environ.get("XREVIEW_RPC_EPHEMERAL_POLL", "2"))
        for tid in eph:
            err(f"waiting for ephemeral {tid} to unload (up to {wait:g} s)")
        end = min(time.monotonic() + wait, c.deadline)
        left_e = list(eph)
        while True:
            now = loaded_ids(c)
            if now is not None:
                left_e = [t for t in left_e if t in now]
            if not left_e or time.monotonic() >= end:
                break
            time.sleep(poll)
        if left_e:
            for tid in left_e:
                err(f"{tid} (ephemeral) is still loaded — close the Codex client using it")
            return 1
        for tid in eph:
            print(f"released {tid}", flush=True)
    return 0


def cmd_release(a):
    deadline = time.monotonic() + float(os.environ.get("XREVIEW_RPC_RELEASE_DEADLINE", "120"))
    sd = state_dir()
    try:
        fd = take_lock(sd, deadline)
    except OSError as e:
        err(f"cannot lock {sd}: {e}")
        return 1
    if fd is None:
        err("another release is running")
        return 1
    # The lock stays held until this process exits (fd is never closed). take_lock tries
    # once more before it looks at the clock, so it can return after the deadline: a passed
    # deadline is exit 1 (spec §1), never the "unreachable" of exit 5.
    if time.monotonic() >= deadline:
        err("the release deadline passed while waiting for the lock")
        return 1
    try:
        mine = [(t, cwd) for t, cwd in read_records(sd) if under(cwd, a.dir)]
        try:
            c = Client(deadline=deadline)
        except (Unreachable, Closed) as e:
            err(f"Codex daemon unreachable: {e}")
            # A connection that failed because the deadline ran out is not unreachable.
            if mine or time.monotonic() >= deadline:
                owed(mine)
                return 1
            return 5
        return release(c, sd, a.dir, mine)
    except (Unreachable, Closed) as e:
        err(f"Codex daemon connection lost: {e}")
    except (OSError, RecordError) as e:
        err(str(e))
    # Whatever stopped the run, every record still under a.dir is a restore owed (spec §1).
    try:
        owed([(t, cwd) for t, cwd in read_records(sd) if under(cwd, a.dir)])
    except (OSError, RecordError):
        pass
    return 1
```

In `main()`, after the `turn-wait` parser block, add:

```python
    sub.add_parser("release").add_argument("--dir", required=True)
```

and right after `a = ap.parse_args(argv)`, before the `turn-wait` dispatch:

```python
    if a.cmd == "release":
        if not os.path.isdir(a.dir):
            err(f"not a directory: {a.dir}")
            return 2
        return cmd_release(a)
```

Update the module docstring: first line becomes `"""xreview-rpc - the dotfiles' client for Codex's shared app-server daemon (xreview, wt-rm).`, and add to the command list after `thread-archive  --thread ID`:

```
  release         --dir DIR                                  unload every thread under DIR
                  (archive, then restore); prints "released <id>" per thread.
                  Spec: docs/superpowers/specs/2026-10-15-wt-rm-codex-session-release-design.md
```

and to the exit-code paragraph: `release: 5 only when no restore is owed under DIR; a lost connection is 1.`

In `docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md`, directly under the heading `### 7.1 \`xreview-rpc\``, add:

```markdown
> **2026-10-15 — amended.** Adds `release --dir <dir>`, which unloads every thread under a
> checkout for `wt-rm`; see
> [wt-rm: release the checkout's Codex sessions](2026-10-15-wt-rm-codex-session-release-design.md).
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./tests/run.sh xreview-rpc`
Expected: every case PASS. Report passed/total.

- [ ] **Step 5: Hand back to the controller** (no commit). The controller commits:

```bash
git add dot_local/bin/executable_xreview-rpc tests/xreview-rpc.test.sh docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md
git commit -m "Add xreview-rpc release to unload a checkout's Codex sessions"
```

---

### Task 3: The release step in `wt-rm`

**Depends on:** none (it relies only on the exit-code contract in Global Constraints, through a stub)

**Files:**
- Modify: `dot_config/zsh/functions` (the `wt-rm` header comment's step list; a new block between check 3 and check 4)
- Modify: `docs/superpowers/specs/2026-10-13-wt-rm-partial-removal-design.md` (amendment banners)
- Test: `tests/wt-functions.test.sh` (header section list; an `xreview-rpc` stub; `setup()`; the grace-period comment; the missing-`wt-teardown` case; new section `W`)

**Interfaces:**
- Consumes: `command xreview-rpc release --dir "$dest"`; exit 0 with `released <id>` lines on stdout, exit 5, any other status; diagnostics on stderr.
- Produces: nothing other tasks use.

- [ ] **Step 1: Add the stub and the fixture plumbing**

In `tests/wt-functions.test.sh`, after the `wt-teardown` stub is made executable (`chmod +x "$STUBS/wt-teardown"`), add:

```zsh
# Never the real daemon. Logs its argv one argument per line, so the --dir value is checked
# as exactly one argument, then answers as MOCK_XRPC_* say: by default exit 0, nothing
# released. MOCK_XRPC_TO_LLOG also marks the call in $LLOG, for ordering against teardown
# and the check-4 scan.
cat > "$STUBS/xreview-rpc" <<'STUB'
#!/bin/sh
{ printf -- '---\n'; for a in "$@"; do printf '%s\n' "$a"; done; } >> "${XLOG:-/dev/null}"
[ -n "${MOCK_XRPC_TO_LLOG:-}" ] && printf 'xreview-rpc\n' >> "$LLOG"
[ -n "${MOCK_XRPC_OUT:-}" ] && printf '%b' "$MOCK_XRPC_OUT"
[ -n "${MOCK_XRPC_ERR:-}" ] && printf '%b' "$MOCK_XRPC_ERR" >&2
[ -n "${MOCK_XRPC_SIGNAL:-}" ] && kill -s "$MOCK_XRPC_SIGNAL" $$
exit "${MOCK_XRPC_RC:-0}"
STUB
chmod +x "$STUBS/xreview-rpc"
```

In `setup()`: add `XLOG="$ROOTTMP/xreview-rpc.log"` to the `export DLOG=…` line's list, `: > "$XLOG"` to the truncation line, and `MOCK_XRPC_RC MOCK_XRPC_OUT MOCK_XRPC_ERR MOCK_XRPC_SIGNAL MOCK_XRPC_TO_LLOG` to its `unset` list.

In the header comment, change `Eighteen sections` to `Nineteen sections` and add after the `V` line:

```
#   W  wt-rm               the checkout's Codex sessions are released before check 4
```

In section V, replace the comment above the `grace-clears` case

```
# Closing a workspace ends some processes only after a delay: Codex's app-server daemon
# stops a thread's MCP servers a few seconds after its client goes. Check 4 re-scans for
# up to 5 s before refusing, and the schedule is the assertion.
```

with

```
# Closing a workspace ends some processes only after a delay, so check 4 re-scans for up
# to 5 s before refusing, and the schedule is the assertion. (Codex's daemon keeps a
# thread's MCP servers for ~60 s, far beyond this; section W covers how wt-rm frees them.)
```

In the `no-teardown` case of section V, change

```zsh
for b in env git mkdir; do ln -s "$(command -v $b)" "$NOTDP/$b"; done
```

to

```zsh
for b in env git mkdir mktemp rm; do ln -s "$(command -v $b)" "$NOTDP/$b"; done
ln -s "$STUBS/xreview-rpc" "$NOTDP/xreview-rpc"   # the release must pass to reach check 4
```

- [ ] **Step 2: Write the failing tests**

Append section `W` after the last section-V case and before the suite's final summary:

```zsh
print -r -- ""
print -r -- "W. wt-rm — the checkout's Codex sessions are released before check 4"

# Codex's daemon keeps a thread loaded, and its MCP helpers running inside the checkout, for
# about 60 s after the TUI goes, so wt-rm asks it to release them. Only exit 5 (daemon
# unreachable, no restore owed) continues without a release: any other status may have left
# a session archived, and the retry restores it.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && echo teardown-hook >> "$LLOG"
exit 0'
run "$REPO" wt rel-order
RO="$HOME/Code/Org/repo-rel-order"
export MOCK_XRPC_TO_LLOG=1
run "$REPO" wt-rm rel-order
rc_is 0 "W1 the release fixture removes the worktree normally"
eq "$(sed -n 1p "$LLOG")" "teardown-hook" "W1 teardown runs first"
eq "$(sed -n 2p "$LLOG")" "xreview-rpc" "W1 the release runs after teardown and check 3"
[[ "$(sed -n 3p "$LLOG")" == *"-F"* ]] && _pass "W1 check 4 scans after the release" \
                                        || _fail "W1 check 4 scans after the release"
eq "$(<$XLOG)" $'---\nrelease\n--dir\n'"$RO" "W1 the release gets the checkout as one --dir argument"

setup
run "$REPO" wt rel-ok
ROK="$HOME/Code/Org/repo-rel-ok"
export MOCK_XRPC_OUT='released th-1\nreleased th-2\n'
run "$REPO" wt-rm rel-ok
rc_is 0 "W2 released sessions let removal proceed"
has "✓ released Codex session th-1" "W2 the first released session is reported"
has "✓ released Codex session th-2" "W2 the second released session is reported"
[[ -d "$ROK" ]] && _fail "W2 the checkout is removed" || _pass "W2 the checkout is removed"

setup
run "$REPO" wt rel-none
run "$REPO" wt-rm rel-none
rc_is 0 "W3 nothing to release: removal proceeds"
hasnt "released Codex session" "W3 nothing to release: nothing is reported"

for st in 1 2 signal; do
  setup
  run "$REPO" wt rel-refuse
  RR="$HOME/Code/Org/repo-rel-refuse"
  if [[ $st == signal ]]; then
    export MOCK_XRPC_SIGNAL=TERM; want=143
  else
    export MOCK_XRPC_RC=$st; want=$st
  fi
  export MOCK_XRPC_ERR='xreview-rpc: th-1 is running a turn — let it finish\n'
  : > "$LLOG"
  run "$REPO" wt-rm rel-refuse
  rc_is 1 "W4 release status $want refuses removal"
  has "wt-rm: could not release the Codex sessions in $RR (status $want) — removal aborted. Resources may already be reclaimed." \
      "W4 status $want: the refusal names the status"
  has "    xreview-rpc: th-1 is running a turn — let it finish" "W4 status $want: the command's lines follow, indented"
  has "    Then retry: wt-rm rel-refuse" "W4 status $want: the retry is offered"
  [[ -d "$RR" ]] && _pass "W4 status $want: the checkout survives" || _fail "W4 status $want: the checkout survives"
  eq "$(lock_reason_of "$RR")" "wt-managed; remove with command wt-rm" "W4 status $want: the registration survives"
  run "$REPO" git branch --list --format='%(refname:short)' rel-refuse
  eq "$OUT" "rel-refuse" "W4 status $want: the branch survives"
  eq "$(grep -c -- '-F' "$LLOG")" "0" "W4 status $want: check 4 never runs"
done

setup
run "$REPO" wt rel-missing
RMI="$HOME/Code/Org/repo-rel-missing"
NOXR=$(mkd)
for b in env git mkdir mktemp rm; do ln -s "$(command -v $b)" "$NOXR/$b"; done
OUT="$(cd "$REPO" && source "$FUNCS" && export PATH="$NOXR" && wt-rm rel-missing 2>&1)"; RC=$?
rc_is 1 "W5 a missing xreview-rpc refuses removal"
has "(status 127)" "W5 the refusal carries the missing command's status"
[[ -d "$RMI" ]] && _pass "W5 the checkout survives" || _fail "W5 the checkout survives"

setup
run "$REPO" wt rel-down
RD="$HOME/Code/Org/repo-rel-down"
export MOCK_XRPC_RC=5 MOCK_XRPC_ERR='xreview-rpc: Codex daemon unreachable: gone\n'
run "$REPO" wt-rm rel-down
rc_is 0 "W6 an unreachable daemon with no restore owed continues"
has "wt-rm: the Codex daemon is not reachable — continuing; check 4 decides." "W6 it says it continues"
hasnt "Codex daemon unreachable: gone" "W6 the command's own diagnostic is not repeated"
[[ -d "$RD" ]] && _fail "W6 check 4 and removal still run" || _pass "W6 check 4 and removal still run"

setup
run "$REPO" wt rel-dirty
print -r -- "wip" > "$HOME/Code/Org/repo-rel-dirty/dirty.txt"
run "$REPO" wt-rm rel-dirty
rc_is 1 "W7 a dirty checkout is refused at check 1"
eq "$(<$XLOG)" "" "W7 a refusal before teardown never calls xreview-rpc"
```

- [ ] **Step 3: Run the suite to verify the new tests fail**

Run: `./tests/run.sh wt-functions`
Expected: the `W1`, `W2`, `W4`, `W5` and `W6` cases FAIL (no release call is made yet); `W3`, `W7` and every pre-existing case pass.

- [ ] **Step 4: Implement the release step**

In `dot_config/zsh/functions`, in the comment above `wt-rm()`, replace the step list item

```
#   6. check 4 (`wt-teardown scan`), last before Git deletes files: it reads the OS,
```

and the lines up to the end of that item with a new item 6 and the old item renumbered 7:

```
#   6. release the checkout's Codex sessions (`xreview-rpc release`): the daemon keeps a
#      thread's MCP helpers running in the checkout for ~60 s after its TUI goes. Only
#      exit 0 or 5 continues; any other status may have left a session archived.
#   7. check 4 (`wt-teardown scan`), last before Git deletes files: it reads the OS,
#      which Git and Herdr cannot see. After teardown because stopping project
#      services is what teardown is for. It re-scans every 0.5 s for up to 5 s, since
#      some processes exit only after their workspace closes. A heuristic, not a proof.
```

and in the paragraph below it change `skips hook validation, checks 1-4 and teardown (steps 1 and 3-6)` to `skips hook validation, checks 1-4, teardown and the release (steps 1 and 3-7)`.

Then insert between the end of the check-3 `case … esac` and the `# Check 4 — the last witness …` comment:

```zsh
    # Release the checkout's Codex sessions, which check 4 would otherwise find: the daemon
    # unloads an idle thread, and stops its MCP helpers, only ~60 s after its TUI goes. Exit
    # 5 is the command's own statement that the daemon is unreachable and no restore is owed
    # here; every other failure, a killed release included, may have left a session archived,
    # so the checkout stays for the retry to restore it. Spec:
    # docs/superpowers/specs/2026-10-15-wt-rm-codex-session-release-design.md
    local rel_out rel_err rel_line
    local -i rel_rc
    rel_err="$(command mktemp "${TMPDIR:-/tmp}/wt-rm-release.XXXXXX")" || {
      print -ru2 -- "wt-rm: cannot create a scratch file to release Codex sessions — refusing."
      return 1
    }
    rel_out="$(command xreview-rpc release --dir "$dest" 2>"$rel_err")"; rel_rc=$?
    case $rel_rc in
      0) for rel_line in ${(f)rel_out}; do
           [[ "$rel_line" == "released "* ]] && print -r -- "✓ released Codex session ${rel_line#"released "}"
         done ;;
      5) print -ru2 -- "wt-rm: the Codex daemon is not reachable — continuing; check 4 decides." ;;
      *) print -ru2 -- "wt-rm: could not release the Codex sessions in $dest (status $rel_rc) — removal aborted. Resources may already be reclaimed."
         for rel_line in ${(f)"$(<$rel_err)"}; do print -ru2 -- "    $rel_line"; done
         print -ru2 -- "    Then retry: wt-rm $qb"
         command rm -f -- "$rel_err"
         return 1 ;;
    esac
    command rm -f -- "$rel_err"
```

In `docs/superpowers/specs/2026-10-13-wt-rm-partial-removal-design.md`:
- directly under the heading `### 3. A grace period before check 4 refuses`, add:

```markdown
> **2026-10-15 — amended.** The Codex daemon keeps an idle thread, and its MCP helpers,
> loaded for ~60 s after its client goes, not "a few seconds"; this grace period does not
> cover it. `wt-rm` now releases the checkout's Codex sessions before check 4; see
> [wt-rm: release the checkout's Codex sessions](2026-10-15-wt-rm-codex-session-release-design.md).
```

- directly under the "Out of scope" bullet that begins `- **Treating Codex-daemon processes specially in the scan.**`, add an indented line:

```markdown
  > **2026-10-15 — amended.** Still not done in the scan: `wt-rm` releases the sessions
  > before it instead; see [the release spec](2026-10-15-wt-rm-codex-session-release-design.md).
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./tests/run.sh wt-functions`
Expected: every case PASS, including section W and the amended `no-teardown` case. Report passed/total.

- [ ] **Step 6: Hand back to the controller** (no commit). The controller commits:

```bash
git add dot_config/zsh/functions tests/wt-functions.test.sh docs/superpowers/specs/2026-10-13-wt-rm-partial-removal-design.md
git commit -m "Release the checkout's Codex sessions in wt-rm before check 4"
```

---

### Task 4: Live canary for the release

**Depends on:** Task 2

**Files:**
- Test: `tests/live-codex-daemon.test.sh` (cleanup trap; a new case before the final summary)

**Interfaces:**
- Consumes: `xreview-rpc release --dir`, `archived()` from Task 1 (through a module import, as section A of the unit suite does).

This suite needs the real daemon, an unsandboxed shell and a Herdr pane (`# test-requires:` already says so). The implementer writes the case and checks it with `zsh -n`/`bash -n`; the controller runs it.

- [ ] **Step 1: Write the case**

In the variable line `tab=""; pane=""; thread=""; prefix=""; wait_pid=""; f22_thread=""`, add `rel_thread=""`. In `cleanup()`, after the `f22_thread` archive line, add:

```bash
  [ -n "$rel_thread" ] && rpc thread-archive --thread "$rel_thread" >/dev/null 2>&1
```

Before the final `printf '\npassed: …'` line, add:

```bash
# release --dir (spec 2026-10-15, C4/C5/C9): archive unloads a thread with saved history at
# once and its helpers exit; unarchive restores it; the archived listing tells the two apart.
echo "R1: release --dir unloads a scratch thread at once and restores it"
rel_archived() { python3 - "$RPCF" "$1" "$2" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("xreview_rpc", sys.argv[1])
spec = importlib.util.spec_from_loader("xreview_rpc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
print({True: "true", False: "false", None: "unknown"}[m.archived(m.Client(), sys.argv[2], sys.argv[3])])
PY
}
RELD="$(mkdir -p "$T/rel/scratch" && cd "$T/rel/scratch" && pwd -P)"
rel_thread="$(rpc thread-start --cwd "$RELD")"
printf 'Live canary. Reply with verdict "approve" and no findings.\n' > "$T/rel-in"
rel_turn="$(rpc turn-start --thread "$rel_thread" --input "$T/rel-in" --schema "$SCHEMA")"
rpc turn-wait --thread "$rel_thread" --turn "$rel_turn" --budget 180 --schema "$SCHEMA" >/dev/null
is "R1 the scratch thread is loaded before the release" \
   "$(rpc thread-status --thread "$rel_thread" | jq -r .loaded)" true
out="$(XDG_STATE_HOME="$T/rel/state" rpc release --dir "$RELD")"; rc=$?
is "R1 release exits 0" "$rc" 0
is "R1 release names the thread" "$out" "released $rel_thread"
is "R1 the thread is no longer loaded" "$(rpc thread-status --thread "$rel_thread" | jq -r .loaded)" false
# No pipe into grep -q: under pipefail an early-exiting grep can SIGPIPE lsof and read as
# "absent". An empty listing is a failed scan (this shell's own cwd is always in a real one),
# so it never counts as absence either.
procs=unknown
for _ in $(seq 10); do
  scan="$(lsof -a -d cwd -Fn 2>/dev/null)"
  if [ -z "$scan" ]; then
    procs=unknown
  elif grep -qxF "n$RELD" <<< "$scan"; then
    procs=present
  else
    procs=gone; break
  fi
  sleep 0.2
done
is "R1 no process is left in the scratch directory within 2 s" "$procs" gone
is "R1 the archived listing does not show the restored thread" "$(rel_archived "$rel_thread" "$RELD")" false
is "R1 no pending record is left" \
   "$(ls "$T/rel/state/xreview-rpc/release-pending" 2>/dev/null | wc -l | tr -d ' ')" 0
rpc thread-archive --thread "$rel_thread"
is "R1 the archived listing does show it once archived (C9 is not vacuous)" \
   "$(rel_archived "$rel_thread" "$RELD")" true
```

- [ ] **Step 2: Syntax-check it**

Run: `bash -n tests/live-codex-daemon.test.sh`
Expected: no output, exit 0.

- [ ] **Step 3: The controller runs the canary**

From a Herdr pane, unsandboxed, after `chezmoi apply`: `./tests/run.sh live-codex-daemon`
Expected: every case PASS, `R1` included. If it cannot run (no Herdr pane, daemon not clean), report it as not run, with the reason; never as passed.

- [ ] **Step 4: The controller commits**

```bash
git add tests/live-codex-daemon.test.sh
git commit -m "Pin the release protocol facts in the live Codex canary"
```
