# xreview reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

**Goal:** The MCP barrier in `xreview-rpc turn-start` waits only while a server is `starting` or `notStarted`, so a null status no longer refuses a review.

**Architecture:** One predicate in `mcp_barrier` changes from "not in the settled set" to "in the starting set". The refusal text, the 30 s bound and every other path stay. The pane step is not touched (D2 ruled B).

**Tech Stack:** Python 3 (`/usr/bin/python3`), bash test suites.

**Spec:** `docs/superpowers/specs/2026-11-14-xreview-reliability-design.md` (§3.1, §6, §7).

## Global Constraints

- Hold only on `runtimeStatus` `starting` or `notStarted`. Null, a missing field, any other value or type, and a non-object entry let the turn start.
- The refusal after the bound keeps its text: "the thread's MCP servers did not finish starting within {secs} ({what}); no review was started", where `{what}` now names only the servers still `starting` or `notStarted`.
- An empty list, a list error, an answer without a server list, an unreadable status and the 30 s bound (`XREVIEW_MCP_WAIT`) behave as today.
- No change to `executable_xreview`, the skill, any refusal text, guards or prompts.
- The repository is public: no private hostnames, client or repository names.

## Review Focus

- A server list mixing `notStarted` with null: it holds on `notStarted` alone, and the refusal names only it (Task 1, MB6).
- A `runtimeStatus` that is not a string (a number, an object): it settles (Task 1, MB2b).
- A list entry that is not an object (`mcp_servers` maps it to `{}`): it settles, where it used to hold (Task 1, MB2b).
- A starting server on the second page while page 1 holds a null: still held (Task 1, MB5b).
- A null that later turns into `starting` between polls is not waited for: the accepted cost in spec §3.1. No test.

---

### Task 1: The barrier holds only on a starting server

**Depends on:** none

**Files:**
- Modify: `dot_local/bin/executable_xreview-rpc:474-547` (`MCP_SETTLED`, `mcp_barrier`)
- Modify: `docs/superpowers/specs/2026-10-01-xreview-reliable-codex-pane-design.md` (a dated amendment after the 2026-10-15 note in §4.4)
- Test: `tests/xreview-rpc.test.sh:343-410` (section MB)

**Interfaces:**
- Produces: `MCP_STARTING = ("notStarted", "starting")` in `executable_xreview-rpc`, replacing `MCP_SETTLED`, which nothing else reads.

- [ ] **Step 1: Write the failing rows** in section MB of `tests/xreview-rpc.test.sh`, reusing `mb_scn`, `mcp`, `order`, `nsent`, `ST` and `OK`:
  - Split the MB2 loop in two:
    - MB2a: `{"name":"node_repl","runtimeStatus":"notStarted"}` then `OK` holds: `"$rc/$(order)"` is `"0/mcpServerStatus/list,mcpServerStatus/list,turn/start"`.
    - MB2b: each of `{"name":"node_repl","runtimeStatus":null}`, `{"name":"node_repl"}`, `{"name":"node_repl","runtimeStatus":"warmingUp"}`, `{"name":"node_repl","runtimeStatus":7}` and the non-object entry `"node_repl"` starts after one call: `"0/mcpServerStatus/list,turn/start"`. The row names say "settles, so the start does not wait".
  - MB5b: page 1 `{result:{data:[{"name":"x","runtimeStatus":null}], nextCursor:"c2"}}`, page 2 `[ST]`, then page 1 again and page 2 `[OK]`: the start follows four list calls, as MB5.
  - MB6: the list `[node_repl=starting, x=null]` still refuses at the bound (1, no `turn/start`). Replace its stderr row with: names `node_repl=starting` (`grep -c 'within [0-9.]*s (node_repl=starting); no review was started'` is 1) and does not name `x` (`grep -c 'x=null'` is 0).
  - MB6b: `[{"name":"a","runtimeStatus":"notStarted"},{"name":"b","runtimeStatus":null}]` refuses at the bound with `(a=notStarted)`.

- [ ] **Step 2: Run the suite and see the new rows fail**

Run: `./tests/xreview-rpc.test.sh 2>&1 | grep -E 'FAIL|MB2b|MB6' | head -30`
Expected: MB2b rows (null, missing, `warmingUp`, 7, non-object) and the new MB6/MB6b stderr rows FAIL; MB2a and MB5b pass already.

- [ ] **Step 3: Change `mcp_barrier`** in `dot_local/bin/executable_xreview-rpc`: replace `MCP_SETTLED` with `MCP_STARTING`. `held` is `[(name, status) for s in servers if s.get("runtimeStatus") in MCP_STARTING]`. With `held` holding only strings, `what` drops the `None` → `null` branch. Rewrite the constant's comment and the docstring to say what holds and why null settles: the schema's "unavailable or the configuration changed", which never turns into a status. Keep the "status was not readable" branch as it is.

- [ ] **Step 4: Run the suite and see it pass**

Run: `./tests/xreview-rpc.test.sh 2>&1 | tail -3`
Expected: the summary reports every row passed (`passed/total` equal). The 5-second timing row is a known load flake: if it alone fails, rerun the suite alone and report both runs.

- [ ] **Step 5: Revert check.** Temporarily restore `MCP_SETTLED` and its `not in` test, run `./tests/xreview-rpc.test.sh 2>&1 | grep -c FAIL`, and expect at least the MB2b and MB6 rows to fail. Restore the change: `git diff` shows only Step 3's edit.

- [ ] **Step 6: Amend the 2026-10-01 spec.** After the "2026-10-15 — amended" note under §4.4, add a quoted note in the same style:
  "> **2026-11-14 — amended.** The barrier now holds only while a server is `starting` or `notStarted`; null, a missing status and any other value let the turn start. Between 2026-11-01 and 11-11 a null status refused 20 dispatches, because a null never settles (spec `2026-11-14-xreview-reliability-design.md`, §2.2 and §3.1)."
  Change nothing else in that file.

- [ ] **Step 7: Commit**

```bash
git -C /Users/michael/.local/share/chezmoi-fix-xreview-reliability branch --show-current
git -C /Users/michael/.local/share/chezmoi-fix-xreview-reliability add dot_local/bin/executable_xreview-rpc tests/xreview-rpc.test.sh docs/superpowers/specs/2026-10-01-xreview-reliable-codex-pane-design.md
git -C /Users/michael/.local/share/chezmoi-fix-xreview-reliability commit -m "Hold the MCP barrier only on a starting server"
```

## After the task (the controller)

- `./tests/run.sh --changed` from the checkout. `xreview-rpc` changed, so the heavy `xreview` suite is selected; quote its `[needs: heavy; changed: …]` line. The `xreview-rpc` 5-second timing row is a known load flake: if it alone fails, rerun `./tests/run.sh xreview-rpc` alone and report both.
- Mark this plan completed (`**Status:** Implemented`) and set the spec's Status to `Implemented (branch fix/xreview-reliability; no MR, a dotfiles line)`, in one commit, before the pre-merge review.
- Push, then a full-range Codex pre-merge review (`--diff main...fix/xreview-reliability`) on the exact pushed tip; no commit after its approval.
