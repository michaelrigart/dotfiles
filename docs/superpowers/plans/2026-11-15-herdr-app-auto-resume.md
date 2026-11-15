# Herdr app auto-resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Completed 2026-11-15 (branch `feat/herdr-app-auto-resume`, its PR against `main`).
Do not run it again; its execution notes bind that run only.

**Goal:** `mods/resume` resumes an agent without a click only after its terminal was really lost,
never a session that runs elsewhere or that another terminal is already launching.

**Architecture:** The mod's decisions move into a pure module, `mods/resume/decide.js`
(`classify`, `reserve`, `claim`), which `main.js` calls and the tests run under macOS's `jsc`. A
new helper, `bin/session-running`, answers "does this session run anywhere now" from Claude's
session registry, Codex's open rollout files and the herdr TUI's `session.json`.

**Tech Stack:** gpui-kit mod JavaScript (ES modules), POSIX sh, jq, lsof, bash test suite,
JavaScriptCore's `jsc`.

**Spec:** `docs/superpowers/specs/2026-11-15-herdr-app-auto-resume-design.md`

## Global Constraints

- Edit only: `dot_config/herdr-app/mods/resume/{main.js,decide.js}`,
  `dot_config/herdr-app/bin/executable_session-running`, `tests/herdr-app-resume.test.sh`,
  `.scripts/test-audit/subjects.tsv`, `tests/missing-subject.test.sh`. Never `bin/retire`,
  `bin/session-written`, `dot_config/zsh/functions`, `keys.json.tmpl`, any popups file or
  `tests/herdr-app.test.sh` (parallel lines own them).
- Never stop, restart or quit the Herdr app or herdr-core; never `chezmoi apply`. `hc` and
  `herdr-app` need the sandbox off.
- Records stay readable by `bin/retire`: `{app, id, cwd, cmd, fresh}` unchanged in meaning; new
  fields `pid`, `quit`, `sent`; `core` is no longer written.
- Values: settle `SETTLE = 3000` ms; pending limit `PATIENCE = 120000` ms; helper `exec` timeout
  `10000` ms.
- Tests: the two cases below and nothing more (Michael's rule: one or two cases, no matrices).
- Mod rules from `~/.config/herdr-app/AGENTS.md`: no `setTimeout`, no side effects at module
  scope, never keep a `cx` (each callback gets its own), `herdr-app check` must pass.
- New files are mode 755 for scripts and suites (`git add --chmod=+x`), 644 for `decide.js`.

## Review Focus

Not tested (Michael's two-case rule); each is a line the task's reviewer checks by reading:

- A record written before this change (has `core`, no `pid`): an agent running there refreshes it;
  at a shell it becomes `quit` (button), never lost.
- A pane whose `hc get` fails (`null`): no record changes, never lost.
- `bin/session-running` missing, not executable, timing out or exiting 2: the session counts as
  running (held), and one warning toast per mod run says so.
- A button click while a scan is between its awaits: both decide from a fresh `shared(KEY)` read
  in one synchronous block that ends with `setShared` before any send, so neither overwrites the
  other's claim and the second sees the first's `sent`.
- Remote terminals (an address with `/`) are never asked, classified or resumed.

---

### Task 1: `bin/session-running` and the suite

**Depends on:** none

**Files:**
- Create: `dot_config/herdr-app/bin/executable_session-running`
- Create: `tests/herdr-app-resume.test.sh`
- Modify: `.scripts/test-audit/subjects.tsv` (row after `executable_session-written`)
- Modify: `tests/missing-subject.test.sh` (row after the `herdr-app` rows)

**Interfaces:**
- Produces: `session-running <claude|codex> <session-id>`; exit 0 when the session runs now (or
  the TUI keeps it), 1 when it does not, 2 when it cannot tell (unknown app, an id that is not a
  lowercase UUID, `jq` or, for codex, `lsof` missing). Reads `$HOME` and `${CODEX_HOME:-$HOME/.codex}`.
- Produces: `tests/herdr-app-resume.test.sh` with a `check <description> <command...>` helper,
  `passed`/`total` counters and a final `"$passed/$total passed"` line; Task 2 appends its case.

- [ ] **Step 1: Write the suite with the helper case**

`#!/usr/bin/env bash`, `set -uo pipefail`. Guard: the helper missing → `missing <path>` on
stderr, exit 2. Scratch `HOME` under `mktemp -d "${TMPDIR:-/tmp}/herdr-app-resume.XXXXXX"`,
removed on exit; `CODEX_HOME` unset. `check` prints `  PASS: …` / `  FAIL: …` like the other
suites. `rc() { "$H" "$@" >/dev/null 2>&1; echo $?; }` with `H` the source helper.

```bash
# --- session-running ------------------------------------------------------------------------
c=11111111-1111-4111-8111-111111111111 x=22222222-2222-4222-8222-222222222222 u=33333333-3333-4333-8333-333333333333
mkdir -p "$HOME/.claude/sessions" "$HOME/.codex/sessions/2026/11/15" "$HOME/.config/herdr"
sleep 60 & live=$!
printf '{"pid":%d,"sessionId":"%s"}' "$live" "$c" > "$HOME/.claude/sessions/$live.json"
check "a Claude session whose registry pid is alive is running" test "$(rc claude $c)" = 0
kill "$live"; wait "$live" 2>/dev/null
check "...and is not once that pid is dead" test "$(rc claude $c)" = 1
f="$HOME/.codex/sessions/2026/11/15/rollout-2026-11-15T00-00-00-$x.jsonl"; : > "$f"
exec 3<"$f"
check "a Codex session whose rollout is held open is running" test "$(rc codex $x)" = 0
exec 3<&-
check "...and is not once it is closed" test "$(rc codex $x)" = 1
printf '{"workspaces":[{"tabs":[{"panes":[{"agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"%s"}}]}]}]}' "$u" > "$HOME/.config/herdr/session.json"
check "a session the herdr TUI keeps is running" test "$(rc codex $u)" = 0
```

End: `echo "$passed/$total passed"; [ "$passed" -eq "$total" ]`.

- [ ] **Step 2: Run it to see it stop**

Run: `./tests/herdr-app-resume.test.sh; echo "exit=$?"`
Expected: `missing …executable_session-running`, exit=2.

- [ ] **Step 3: Write `bin/executable_session-running`** (`#!/bin/sh`)

Header comment in the style of `executable_session-written`: what it answers, the exit codes, and
that `mods/resume` asks it before every resume. Order: the id must match
`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` (else 2); `jq` present (else 2);
the TUI file `$HOME/.config/herdr/session.json`, when it exists, listing the id as any
`agent_session.value` → 0; then by app:
- `claude`: one `jq` over `$HOME/.claude/sessions/*.json` printing `.pid` where
  `.sessionId == $id`; any of those pids alive (`kill -0`) → 0; else 1.
- `codex`: `lsof` present (else 2); each file
  `find "${CODEX_HOME:-$HOME/.codex}/sessions" -type f -name "rollout-*$id.jsonl"` that
  `lsof -t --` reports open → 0; a process matching `pgrep -f "(^|/)codex .*$id"` → 0; else 1.
- anything else: 2.

- [ ] **Step 4: Run the suite**

Run: `./tests/herdr-app-resume.test.sh`
Expected: `5/5 passed`, exit 0.

- [ ] **Step 5: Map rows**

`subjects.tsv`:
`dot_config/herdr-app/bin/executable_session-running	sh	herdr-app-resume	herdr-app,herdr-app-resume,herdr-app-xreview`
`missing-subject.test.sh`:
`missing herdr-app-resume      dot_config/herdr-app/bin/executable_session-running`

Run: `./tests/run.sh missing-subject herdr-app-resume`
Expected: every listed suite passes.

- [ ] **Step 6: Commit**

```bash
git add --chmod=+x dot_config/herdr-app/bin/executable_session-running tests/herdr-app-resume.test.sh
git add .scripts/test-audit/subjects.tsv tests/missing-subject.test.sh
git commit -m "Add session-running: does an agent session run anywhere now"
```

### Task 2: Decide by the terminal's root pid, and never resume twice

**Depends on:** Task 1

**Files:**
- Create: `dot_config/herdr-app/mods/resume/decide.js`
- Modify: `dot_config/herdr-app/mods/resume/main.js`
- Modify: `tests/herdr-app-resume.test.sh` (the decision case)
- Modify: `.scripts/test-audit/subjects.tsv`, `tests/missing-subject.test.sh`

**Interfaces:**
- Consumes: `session-running` (Task 1) through `exec(`${appHome()}/bin/session-running`, [app, id], { timeout: 10000 })`; exit 1 alone means "not running".
- Produces (`decide.js`, pure, no imports):
  - `export const SETTLE = 3000, PATIENCE = 120000;`
  - `Rec = {app, id, cwd, cmd, fresh, pid?, quit?, sent?}`;
    `Seen = {address, pid: number|null, shell: boolean, now: {app, id, cwd, cmd, fresh}|null}`.
  - `classify(saved, seen, firstSeen, now) → {saved, changed, button, lost, again, firstSeen}`.
    Inputs are not mutated. Per `Seen` with a record (or a running agent):
    agent running (`now`) → record `{...now, pid}` (no `quit`, no `sent`) when there is none or
    its `cmd`, `pid`, `quit` or `sent` differs; shell with a record whose `quit` is set, or whose
    `pid` is missing or equal → `quit: true` (changed only if it was not), address in `button`;
    shell with another pid and no `quit` → lost path: `firstSeen[address]` with that pid and
    `now - at >= SETTLE` → `lost`; otherwise `again = true`, and `firstSeen[address] = {pid, at: now}`
    when its pid differs. A `Seen` that is neither a shell nor a told agent (`now: null`: another
    program, an agent whose session cannot be read yet, a terminal mid-recovery with `pid: null`)
    changes nothing. The returned `firstSeen` keeps only lost-path addresses.
  - `reserve(addresses, saved, seen, elsewhere) → {go, held}`. In order, an address goes when its
    record's `id` is not in `elsewhere` (a Set from the helper), not an earlier `go`'s id, not the
    `now.id` of another address's `Seen`, and not the `id` of another address's record with
    `sent`; else it is held.
  - `claim(saved, addresses, {firstSeen, sent}) → saved` (copy): each address's record gets
    `pid: firstSeen[address].pid` when `firstSeen` is given, and `sent: true` when `sent`.

- [ ] **Step 1: Append the decision case to the suite**

Guard (at the top, with Task 1's): `decide.js` missing → exit 2;
`J=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc` not
executable → `INCONCLUSIVE: no jsc`, exit 2. The case copies `decide.js` into a scratch folder,
writes this `test.js` beside it, runs `"$J" -m test.js`, prints its output, adds its `PASS`/`FAIL`
lines to `passed`/`total`, and counts one failure more when `jsc` exits non-zero or prints no
`PASS`/`FAIL` line.

```js
import { SETTLE, classify, reserve, claim } from "./decide.js";
const check = (what, ok) => print(`  ${ok ? "PASS" : "FAIL"}: ${what}`);
const agent = (id) => ({ app: "claude", id, cwd: "/w", cmd: `claude --resume ${id}`, fresh: "claude" });
const rec = (id, pid, more = {}) => ({ ...agent(id), pid, ...more });
const T = 1000000;

// A core restart or update keeps every terminal: the same root pids.
{
  const saved = { t1: rec("X", 100), t2: rec("Y", 200) };
  const seen = [{ address: "t1", pid: 100, shell: false, now: agent("X") },
                { address: "t2", pid: 200, shell: true, now: null }];
  const r = classify(saved, seen, {}, T);
  check("core restart: nothing is lost", r.lost.length === 0 && !r.again);
  check("core restart: an agent quit in its shell gets the button", r.button.join() === "t2" && r.saved.t2.quit === true);
}
// A loss: every root pid is new.
{
  const saved = { a: rec("X", 100), b: rec("X", 101), q: rec("Y", 102, { quit: true }), e: rec("Z", 103) };
  const seen = [["a", 900], ["b", 901], ["q", 902], ["e", 903]].map(([address, pid]) => ({ address, pid, shell: true, now: null }));
  const r1 = classify(saved, seen, {}, T);
  check("loss: nothing resumes before the new shells settle", r1.lost.length === 0 && r1.again);
  const r2 = classify(r1.saved, seen, r1.firstSeen, T + SETTLE);
  check("loss: settled terminals are lost, a quit one only gets the button", r2.lost.join() === "a,b,e" && r2.button.join() === "q");
  const { go, held } = reserve(r2.lost, r2.saved, seen, new Set(["Z"]));
  check("loss: one terminal per session, none whose session runs elsewhere", go.join() === "a" && held.join() === "b,e");
  const after = claim(r2.saved, go, { firstSeen: r2.firstSeen, sent: true });
  check("claim: the new shell's pid, and sent", after.a.pid === 900 && after.a.sent === true);
  check("a later settle, from the persisted records alone, is held while a's launch is unresolved", reserve(["b"], after, seen, new Set()).go.length === 0);
  const r3 = classify(after, seen, {}, T + SETTLE + 1500);
  check("a resume that did not start falls to the button, not lost again", r3.button.includes("a") && !r3.lost.includes("a"));
  const running = seen.map((s) => (s.address === "a" ? { ...s, now: agent("X") } : s));
  const r4 = classify(after, running, {}, T + 10000);
  check("seen running clears sent", r4.saved.a.sent !== true);
  check("...and the session stays taken while it runs", reserve(["b"], r4.saved, running, new Set()).go.length === 0);
}
```

- [ ] **Step 2: Run it to see it stop**

Run: `./tests/herdr-app-resume.test.sh; echo "exit=$?"`
Expected: `missing …decide.js`, exit=2.

- [ ] **Step 3: Write `decide.js`** to the Interfaces block above, with a header comment saying
  what it decides and that the tests run it under `jsc`.

- [ ] **Step 4: Run the suite**

Run: `./tests/herdr-app-resume.test.sh`
Expected: `15/15 passed`, exit 0.

- [ ] **Step 5: Revert check**

Make `classify` treat every shell with a record as lost (ignore the pid): the "core restart"
checks fail. Restore. Drop the `sent` clause from `reserve`: the "later settle" check fails.
Restore. Run the suite: `15/15 passed`.

- [ ] **Step 6: Wire `main.js` to `decide.js`**

- Header comment: lost means the terminal's root process changed (`hc get` `.pid`), not the core;
  the core restarts with terminals kept.
- Drop `coreNow`, `sameCore`, the local `SETTLE` and every `core` field.
- `init`: `this.firstSeen = {}`, `this.seen = []`, `this.button = []` (renames `this.lost`;
  `render` shows `this.button.length`).
- `scan`: each asked pane gives `{address, pid: t?.pid ?? null, shell, now}` (`now` from
  `record(t)` when not a shell). Then ask `session-running` for the distinct ids of a first
  `classify` pass's `lost`. Then, in one synchronous block (no `await` from here to `setShared`):
  `saved = {...shared(KEY)}`, forget records of closed panes (layout `ready`, as today), run
  `classify` again on that fresh `saved`, `reserve(lost, saved, seen, elsewhere)` where an id
  with no helper answer counts as elsewhere, `gaveUp = held` whose
  `now - firstSeen[a].at >= PATIENCE`, `claim(…, go, {firstSeen, sent: true})`,
  `claim(…, gaveUp, {firstSeen})`, `setShared` when changed; keep `this.firstSeen`,
  `this.seen`, `this.button`, `this.again`. Then send to `go`; when `gaveUp` is not empty,
  `notify({title: `${n} not resumed: already running elsewhere`, level: "warning"})`.
- The helper's answer: exit 1 → not running; exit 0 → running; anything else, or a throw →
  running, and one warning per mod run: "Cannot tell whether agent sessions run elsewhere" /
  "bin/session-running did not answer: those sessions are not resumed."
- Button (`restore` without addresses): ask the helper for `this.button`'s ids, then the same
  synchronous block: fresh `saved`, `reserve(this.button, saved, this.seen, elsewhere)`,
  `claim(saved, go, {sent: true})`, `setShared`, send to `go`, and the same "not resumed" toast for
  `held`. "No agent sessions to resume" stays for an empty button list.
- Sending is unchanged: `cd <cwd> && <cmd or fresh by session-written>`, the toasts after it.

- [ ] **Step 7: Check the mod**

Run (sandbox off): `herdr-app check dot_config/herdr-app/mods/resume`
Expected: exit 0, no error. Then `./tests/herdr-app-resume.test.sh` → `15/15 passed`.

- [ ] **Step 8: Map rows**

`subjects.tsv`:
`dot_config/herdr-app/mods/resume/decide.js	data	herdr-app-resume	herdr-app,herdr-app-resume,herdr-app-xreview`
`missing-subject.test.sh`:
`missing herdr-app-resume      dot_config/herdr-app/mods/resume/decide.js`

Run: `./tests/run.sh missing-subject herdr-app-resume`
Expected: every listed suite passes.

- [ ] **Step 9: Commit**

```bash
git add dot_config/herdr-app/mods/resume tests/herdr-app-resume.test.sh .scripts/test-audit/subjects.tsv tests/missing-subject.test.sh
git commit -m "Resume Herdr app agents only after a real terminal loss, never twice"
```
