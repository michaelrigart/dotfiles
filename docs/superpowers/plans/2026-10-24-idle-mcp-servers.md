# Idle MCP servers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (branch `feat/idle-mcp-servers`; the dotfiles have no MR)

**Goal:** Codex threads start no REPL MCP servers, and ha-mcp is registered only for Claude Code sessions started in `~`.

**Architecture:** Two independent changes. The Codex config modify-template gains two enforced switches. `reconcile-agents.sh` learns an optional directory on `claude_mcp` lines and registers such a server in Claude Code's local scope for that directory, then removes its user-scope entry.

**Tech Stack:** chezmoi modify-template (Go text/template + sprig + chezmoi functions), Bash 3.2, jq, the repo's shell test suites.

**Spec:** `docs/superpowers/specs/2026-10-24-idle-mcp-servers-design.md`

## Global Constraints

- The repo is public: no secret or internal hostname in any file. MCP entry contents are compared, never printed.
- `reconcile-agents.sh` stays Bash 3.2 compatible: no associative arrays, `mapfile` or `${x,,}`.
- `~/.codex/config.toml` keeps every key the template does not name; no `-c` overrides anywhere.
- A `[mcp_servers.node_repl]` table holding only `enabled` makes Codex fail with `invalid transport`; the template must never create one.
- Suites are executed, never run through an interpreter: `./tests/run.sh <name>`. Report totals as passed/total.
- `reconcile-agents` needs the sandbox disabled; `codex-config` runs sandboxed.
- Implementers do not commit; the controller commits each task.

## Review Focus

1. **Symlinked declared directory** (`~/link` → `~/sub`; macOS `mktemp -d` paths under `/var` → `/private/var`): the reconciler must read and register under the physical path (`pwd -P`), the path Claude Code itself uses. Pinned in Task 2, case H3.k.
2. **User-scope entry holding a token while the local add fails:** the user-scope entry must stay, exit 1, and the token must appear in no output or CLI call. Pinned in Task 2, case H3.f.
3. **Declared directory already in `.projects` without `mcpServers`** (true for `~` today, which holds other project state): treated as absent → added. Pinned in Task 2, case H3.c.
4. **A `node_repl` table that is already populated, including a nested `env` subtable and `enabled = true`:** comes out `enabled = false` with every other key intact. Pinned in Task 1, case K.1.
5. **No ChatGPT.app** (no `mcp_servers` table, or one with other servers only): no `node_repl` entry appears, and the output still parses as TOML. Pinned in Task 1, case K.2.

---

### Task 1: Codex REPL servers off

**Depends on:** none

**Files:**
- Modify: `dot_codex/modify_private_config.toml` (after the `features.js_repl` delete, before `toToml`)
- Modify: `tests/codex-config.test.sh` (new section K, before `J`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing tests** in a new section `echo "K. REPL MCP servers stay off (spec 2026-10-24 §1)"`. Add a helper next to `has`/`hasnt`:

```bash
# tq <python expr over d> <expected repr> <label> — query the emitted TOML
tq() {
  local got
  got=$(printf '%s' "$OUT" | python3 -c 'import sys,tomllib; d=tomllib.loads(sys.stdin.read()); print(repr(eval(sys.argv[1])))' "$1" 2>&1)
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$got"; fi
}
```

Cases:
- **K.1** fixture: `[mcp_servers.node_repl]` with `command = "/x/node_repl"`, `enabled = true`, `env_vars = ["A"]`, and `[mcp_servers.node_repl.env]` with `FOO = "bar"`. Assert `d["mcp_servers"]["node_repl"]["enabled"]` → `False`; `["command"]` → `'/x/node_repl'`; `["env_vars"]` → `['A']`; `["env"]["FOO"]` → `'bar'`.
- **K.2** fixture `''`: `'mcp_servers' in d` → `False`. Fixture with only `[mcp_servers.other]` / `command = "x"`: `'node_repl' in d["mcp_servers"]` → `False`, `d["mcp_servers"]["other"]["command"]` → `'x'`. Both outputs parse as TOML (the `tq` call itself fails on invalid TOML).
- **K.3** plugin: fixture `''` → `d["plugins"]["unified-computer-use@openai-bundled"]["enabled"]` → `False`. Fixture `[plugins."unified-computer-use@openai-bundled"]` / `enabled = true` plus `[plugins."browser@openai-bundled"]` / `enabled = true` → unified `False`, browser `True`.
- **K.4** idempotent: feed the K.1 output back through `emit`; the second output equals the first (`[ "$first" = "$OUT" ]`).

- [ ] **Step 2: Run to verify K fails**

Run: `./tests/run.sh codex-config`
Expected: K.1 `enabled` and K.3 assertions FAIL; all other sections pass.

- [ ] **Step 3: Implement the two switches** in `dot_codex/modify_private_config.toml`, with a comment in the file's existing style that cites spec 2026-10-24 §1:
  - `mcp_servers.node_repl.enabled = false` only when `mcp_servers.node_repl` exists in the parsed `$config` (for example with `dig "mcp_servers" "node_repl" ""`). The comment says why it's conditional: a table without a command fails with `invalid transport`.
  - `plugins."unified-computer-use@openai-bundled".enabled = false` unconditionally. Use `setValueAtPath` with a **list** path (`list "plugins" "unified-computer-use@openai-bundled" "enabled"`) so the dotted-name parsing never splits the plugin id.
  - Also extend the header comment's bullet list with one line for these switches.

- [ ] **Step 4: Run to verify all pass**

Run: `./tests/run.sh codex-config`
Expected: every case passes, including A–J unchanged.

- [ ] **Step 5: Preview against the live file, printing only the three projected values**

Never print the rendered config itself: it carries every MCP table, `env` values included.

Run: `command chezmoi cat ~/.codex/config.toml | python3 -c 'import sys,tomllib; d=tomllib.loads(sys.stdin.read()); print(d["mcp_servers"]["node_repl"]["enabled"], d["plugins"]["unified-computer-use@openai-bundled"]["enabled"], d["mcp_servers"]["node_repl"]["command"])'`
Expected: `False False /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl`. If the zsh wrapper refuses off main, render with `command chezmoi execute-template --with-stdin --file dot_codex/modify_private_config.toml < ~/.codex/config.toml`, piped into the same `python3` projection, never to the terminal.

- [ ] **Step 6: Commit** (controller): `git add dot_codex/modify_private_config.toml tests/codex-config.test.sh && git commit -m "Keep Codex's REPL MCP servers off"`

---

### Task 2: Directory-scoped `claude_mcp`

**Depends on:** none

**Files:**
- Modify: `.scripts/reconcile-agents.sh` (`parse_manifest`, `reconcile_claude_mcp`, header comment)
- Modify: `dot_config/agents/plugins.conf` (header comment; `claude_mcp ha-mcp` → `claude_mcp ha-mcp ~`)
- Modify: `tests/reconcile-agents.test.sh` (claude stub, new helper, new section H3 after H2)

**Interfaces:**
- Consumes: nothing.
- Produces, inside `reconcile-agents.sh`:
  - `claude_mcp_dirs=()`: index-aligned with `claude_mcps`. Each element is the expanded directory, or `""` for user scope.
  - `expand_mcp_dir <raw>`: echoes `$HOME` for `~`, `$HOME/<rest>` for `~/<rest>`, the input for `/…`. Returns 1 for anything else, including `~user` and relative paths.
  - `mcp_entry_state <cfg> <name> <cmd> [<dir>]`: echoes `absent`, `match` or `differs` for `.mcpServers[name]`, or for `.projects[dir].mcpServers[name]` when `dir` is given. Uses the existing match rule (stdio, command `== cmd`, empty args and env). Returns non-zero when jq fails. An absent file → `absent`. The existing user-scope path is refactored onto it, with behaviour unchanged.

Exact log lines the tests assert (`<dir>` = physical path):

| Event | Line |
|---|---|
| local present | `claude mcp present: <name> (local: <dir>)` |
| local add | `claude mcp add: <name> (local: <dir>)` |
| local replace | `claude mcp replace: <name> (local: <dir>)` |
| user entry removed | `claude mcp remove: <name> (user scope)` |
| dir missing (warn, status 1) | `claude mcp: directory not found for <name>: <expanded dir>` |
| stale local elsewhere (warn, status unchanged) | `claude mcp: <name> is also registered for <path> (local scope) — left as-is` |
| bad dir (warn, status 1) | `manifest line <n>: claude_mcp directory must be ~, ~/<path> or absolute: '<raw>' — skipped` |
| field count | other kinds keep `expected 2 fields, got <k> — skipped`; `claude_mcp` with 4+ → `expected 2 or 3 fields, got <k> — skipped` |

Failures reuse the existing `failed to add claude mcp: <name>` / `failed to remove claude mcp: <name>` warnings and set `status=1`.

- [ ] **Step 1: Extend the claude stub** so `mcp` calls also record their working directory. In the `"mcp "*)` branch, also append `printf '%s\t%s\n' "$(pwd -P)" "$*" >> "$MCPCWD"`. Set `MCPCWD="$BIN/mcp-cwd.log"` beside `CALLS`, pass it into `run`'s environment, and truncate it in `run`. Add:

```bash
# called_in <dir> <args> <label> — an mcp call with exactly these args ran in <dir>
called_in() { if grep -qxF -- "$1	$2" "$MCPCWD"; then _pass "$3"; else _fail "$3"; fi; }
```

The H2 cases stay as they are and must keep passing.

- [ ] **Step 2: Write the failing H3 cases.** `echo "H3. claude_mcp with a directory — local scope there, user entry removed"`. Set `CFGP=$(cd "$CFG" && pwd -P)`. `L` and `J` are the H2 values. `TOK` is H2's stale user entry holding `SECRET-TOKEN-123`. `LOC <dir>` builds `{"projects":{"<dir>":{"mcpServers":{"ha-mcp":J}}}}` (combine with `jq` where a case needs several keys).
  - **a** no `.claude.json`, `claude_mcp ha-mcp ~` → `called_in "$CFGP" "mcp add-json ha-mcp $J --scope local"`; `not_called "--scope user"`; `has "claude mcp add: ha-mcp (local: $CFGP)"`; rc 0.
  - **b** user entry `TOK`, no local → exactly two calls in order: line 1 `mcp add-json ha-mcp $J --scope local` (run in `$CFGP`), line 2 `mcp remove ha-mcp --scope user`; `has "claude mcp remove: ha-mcp (user scope)"`; `hasnt`/`not_called` `SECRET-TOKEN-123`; rc 0.
  - **c** `.projects[$CFGP]` = `{"allowedTools":[]}` (no `mcpServers`) → local add called; rc 0.
  - **d** `LOC $CFGP`, no user entry → `has "claude mcp present: ha-mcp (local: $CFGP)"`; `not_called "mcp "`; rc 0.
  - **e** `LOC $CFGP` plus user entry `TOK` → the only call is `mcp remove ha-mcp --scope user`; rc 0.
  - **f** user entry `TOK`, no local, `MOCK_CL_MCP_RC=1` → add attempted; `not_called "mcp remove ha-mcp --scope user"`; `has "failed to add claude mcp: ha-mcp"`; token absent from output and calls; rc 1.
  - **g** local entry differs (command `uvx`) → line 1 `mcp remove ha-mcp --scope local`, line 2 `mcp add-json ha-mcp $J --scope local`, both `called_in "$CFGP"`; `has "claude mcp replace: ha-mcp (local: $CFGP)"`; rc 0.
  - **h** `claude_mcp ha-mcp ~/nope` with user entry `TOK` → `has "claude mcp: directory not found for ha-mcp: $CFG/nope"`; `not_called "mcp "`; rc 1.
  - **i** manifest errors, each with `not_called "mcp "` and rc 1: `claude_mcp ha-mcp sub` and `claude_mcp ha-mcp ~other` → `has "claude_mcp directory must be"`; `claude_plugin foo@m extra` → `has "expected 2 fields, got 3"`; `claude_mcp ha-mcp ~ extra` → `has "expected 2 or 3 fields, got 4"`.
  - **j** `mkdir "$CFG/sub"`; `claude_mcp ha-mcp ~/sub` and `claude_mcp ha-mcp $CFG/sub` (separate runs) → `called_in "$CFGP/sub" "mcp add-json ha-mcp $J --scope local"`. `claude_mcp ha-mcp ~ # home` (inline comment) → add in `$CFGP`, rc 0.
  - **k** `ln -s "$CFG/sub" "$CFG/link"`; `LOC "$CFGP/sub"`; `claude_mcp ha-mcp ~/link` → `has "claude mcp present: ha-mcp (local: $CFGP/sub)"`; `not_called "mcp "`.
  - **l** `LOC $CFGP` plus `.projects["/elsewhere"].mcpServers["ha-mcp"]` → `has "claude mcp: ha-mcp is also registered for /elsewhere (local scope) — left as-is"`; `not_called "mcp "`; rc 0.

- [ ] **Step 3: Run to verify H3 fails**

Run (sandbox disabled): `./tests/run.sh reconcile-agents`
Expected: H3 cases FAIL; A–H2 and I pass.

- [ ] **Step 4: Implement in `.scripts/reconcile-agents.sh`**
  - `parse_manifest`: accept 3 fields only for `claude_mcp`, and validate field 3 with `expand_mcp_dir`. Push the result, or `""` for no third field, onto `claude_mcp_dirs` in step with `claude_mcps`. Duplicate detection stays by name.
  - `reconcile_claude_mcp`: lines with no directory go through today's flow, refactored onto `mcp_entry_state`. A line with a directory follows spec §2 steps 1–4 in order:
    1. Resolve the directory with `cd` and `pwd -P`; a missing one gets the warning and `continue`.
    2. Local state, then remove (on `differs`) and add. Both run as `( cd "$dir" && claude mcp … --scope local )`.
    3. Only if step 2 succeeded or the entry already matched, remove the user-scope entry when `mcp_entry_state` reports it present (`match` or `differs`).
    4. Use jq to list `.projects` keys other than `$dir` whose `mcpServers` has the name, and warn once per key.
  - Header comment: one line saying a `claude_mcp` line may name a directory, which puts the server in local scope there and removes its user-scope entry.

- [ ] **Step 5: Update `dot_config/agents/plugins.conf`.** In the header, document the optional third field (`claude_mcp <name> [<dir>]`: `~`, `~/<path>` or absolute; local scope for that directory, and the user-scope entry is removed). Change the line to `claude_mcp          ha-mcp    ~`.

- [ ] **Step 6: Run to verify all pass**

Run (sandbox disabled): `./tests/run.sh reconcile-agents`
Expected: every case passes. Also `bash -n .scripts/reconcile-agents.sh` with `/bin/bash` (3.2) prints nothing.

- [ ] **Step 7: Commit** (controller): `git add .scripts/reconcile-agents.sh dot_config/agents/plugins.conf tests/reconcile-agents.test.sh && git commit -m "Register ha-mcp only for sessions started in ~"`

---

## After the batch (controller)

- Full suite: `./tests/run.sh`, then `./tests/run.sh reconcile-agents` with the sandbox disabled. Report passed/total.
- Spec and plan `**Status:** In progress (branch feat/idle-mcp-servers)` at execution start; `Implemented` in the final pre-merge commit.
- Pre-merge cross-review over `main...feat/idle-mcp-servers`, then push the branch. The rollout and acceptance checks in spec §Rollout/§Acceptance are Michael's, after merge.
