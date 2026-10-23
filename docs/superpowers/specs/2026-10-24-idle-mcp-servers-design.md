# Idle MCP servers: ha-mcp only in home sessions, no REPL servers in Codex

**Status:** In progress (branch `feat/idle-mcp-servers`; the dotfiles have no MR)
**Date:** 2026-10-24
**Branch:** `feat/idle-mcp-servers`
**Builds on:** [2026-10-23 ha-mcp design](2026-10-23-ha-mcp-design.md), whose §5 registers
ha-mcp in Claude Code's user scope. This design narrows that registration to one directory.

## Why

Neither tool starts an MCP server lazily. Claude Code (2.1.309) spawns every registered stdio
server when a session opens; tool deferral only keeps the schemas out of the context. Codex
(0.164) spawns every enabled server each time a thread loads in the daemon. So every session
and every Codex pane carries servers it almost never uses.

Measured 2026-10-24 (`ps` RSS), with 13 Claude sessions and 13 Codex panes open:

| What | Per instance | Instances | Total |
|---|---|---|---|
| ha-mcp: `uv tool uvx` parent (22–34 MB) + `python` (111–118 MB) | ~145 MB | 13, one per `claude` session | ~1.9 GB |
| Codex REPL servers: `node_repl` (19 MB) + `node cua-repl.mjs` (48 MB) + its `node_repl` child (22 MB) | ~90 MB | 13, one per loaded thread | ~1.2 GB |

Every Home Assistant session so far was started in `~` (`/Users/michael`). The Codex panes are
reviewers (`--sandbox read-only`) and never drive a browser or the desktop.

## Goals

- ha-mcp runs only in Claude Code sessions started in `~`. Sessions in a repository, a `wt`
  worktree or any other directory start no ha-mcp process.
- Codex threads start neither REPL server.
- Both stay declarative: `chezmoi apply` plus `reconcile-agents.sh` reach the end state, on
  this machine and on a fresh one.

## Non-goals

- Lazy start. Neither tool supports it, and a stdio proxy that fakes `tools/list` until the
  first call would be fragile against `ha-mcp@latest` and its `skill://` resources.
- A shared ha-mcp instance over HTTP. One unauthenticated localhost endpoint would be reachable
  from every session's sandboxed Bash and would undo the read-deny on `~/.config/ha-mcp/env`.
- Claude Desktop. It runs one ha-mcp while it is open, and stays as it is.
- Trimming the `uv` parent (exec an installed ha-mcp directly). Michael chose scoping instead.
- The Codex daemon's own memory, and the other bundled Codex plugins, which start no process.

## Anti-goals

- HA tools vanishing from sessions started in `~`.
- A config change that leaves Codex unable to start, such as a server entry with no command.
- The token reaching any file, argument or log, as in the ha-mcp design.

## Design

### 1. Codex: REPL servers off

Two sources start the per-thread processes:

- `[mcp_servers.node_repl]` in `~/.codex/config.toml`. ChatGPT.app writes it for browser use;
  it carries `BROWSER_USE_CODEX_APP_VERSION`, so the app regenerates it on update.
- The `cua_repl` server, declared in the `.mcp.json` of the bundled
  `unified-computer-use@openai-bundled` plugin. It starts `node cua-repl.mjs`, which starts
  its own `node_repl`.

`dot_codex/modify_private_config.toml` gains two enforced settings:

- `mcp_servers.node_repl.enabled = false`, set **only when `mcp_servers.node_repl` already
  exists**. A server table holding nothing but `enabled` has no command, which Codex would
  reject; a machine without ChatGPT.app must get no such entry.
- `plugins."unified-computer-use@openai-bundled".enabled = false`.

Every other key in those tables survives, as the template already guarantees for keys it
does not name. Measured 2026-10-24 with `codex mcp list --json` (0.164) and `-c` overrides
against the live home:

- `mcp_servers.node_repl.enabled=false` → `node_repl` listed as disabled.
- `plugins.unified-computer-use@openai-bundled.enabled=false` → `cua_repl` no longer listed.
- A config whose `[mcp_servers.node_repl]` holds only `enabled = false` → Codex fails with
  `invalid transport in mcp_servers.node_repl`. Hence the existence check.
- A plugin entry for a plugin that is not installed → no error.

This lives in `config.toml` because a `-c` override makes a TUI leave the shared daemon (the
template's existing comments). The cost: browser and computer use are also off in the Codex
desktop app, which shares `~/.codex` (Michael's decision, 2026-10-24). If ChatGPT.app rewrites
its `node_repl` table on an update, the next `chezmoi apply` turns it off again.

### 2. ha-mcp: registered for one directory

A `claude_mcp` manifest line may name a directory as a third field:

```
claude_mcp          ha-mcp    ~
```

- The directory is `~`, `~/<path>` (expanded against `$HOME`) or an absolute path. Anything
  else is a manifest error: warned, `status=1`, line skipped. Other kinds still take exactly
  two fields, and a `claude_mcp` line takes two or three.
- Without a directory, the line behaves as today: user scope.

For a line with a directory, `reconcile_claude_mcp`:

1. Resolves the directory with `cd` and `pwd -P`. A missing directory is warned, sets
   `status=1`, and changes nothing for that server, the user-scope entry included.
2. Compares `.projects[<dir>].mcpServers[<name>]` in `~/.claude.json` against the same
   definition as today (`{type:"stdio",command:$HOME/.local/bin/<name>,args:[],env:{}}`):
   absent → `claude mcp add-json <name> '<json>' --scope local`; match → reported present;
   differs → `claude mcp remove <name> --scope local`, then add. Both commands run with the
   directory as their working directory, since that is how Claude Code picks the local scope.
3. Only after step 2 succeeds, removes a user-scope `.mcpServers[<name>]` entry if one
   exists, whatever it holds: the declaration owns the name. If step 2 failed, the user-scope
   entry stays, so a failed run never leaves the server registered nowhere.
4. Warns, without changing anything, about local-scope entries of the same name in any
   other directory, naming those directories. They are what a later change of directory
   would leave behind.

Entry contents are only ever compared, never printed, as today.

`plugins.conf` changes its `claude_mcp ha-mcp` line to `claude_mcp ha-mcp ~` and documents
the optional field in its header comment.

Claude Code keys local scope by the exact project directory (`~/.claude.json` holds
`/Users/michael`, `/Users/michael/Documents` and each repository as separate keys), and
`$HOME` is not inside a git repository, so a session started in a subdirectory of `~` gets no
ha-mcp. The acceptance checks confirm this rather than trust it.

## Rollout (Michael's, after merge)

1. `chezmoi apply`.
2. `.scripts/reconcile-agents.sh`: adds the local entry for `~`, then removes the user-scope
   one. It writes `~/.claude.json`, which the sandbox does not allow.
3. `codex-daemon restart`, so new threads load the new config.
4. Running sessions keep their servers until they restart. Close or restart them to reclaim
   the memory.

## Tests

- `tests/codex-config.test.sh`: a live file with a populated `[mcp_servers.node_repl]` comes
  out with `enabled = false` and every other key of that table intact; a file without
  `mcp_servers`, and one with other servers only, gains no `node_repl` entry; the
  `unified-computer-use@openai-bundled` plugin comes out disabled, whether its entry existed
  enabled or not at all; a second pass is a no-op.
- `tests/reconcile-agents.test.sh` (the claude stub also records its working directory):
  - scoped and absent → local add, run in that directory; user-scope entry then removed;
  - scoped and matching, no user entry → no `claude mcp` call;
  - scoped and matching, user entry present → only the user-scope remove;
  - local entry differs → local remove, then add;
  - local add fails → user-scope entry not removed, exit 1;
  - missing directory → warned, exit 1, no `claude mcp` call;
  - relative directory, three fields on another kind, four fields → manifest errors;
  - `~` and `~/sub` expand against `$HOME`;
  - another directory holding a same-named local entry → warned with its path, untouched;
  - an unscoped line keeps today's user-scope behaviour (the existing H2 cases still pass).

## Acceptance

- `codex mcp list --json`, with the real binary (`codex-daemon real-bin`), shows `node_repl`
  and `cua_repl` disabled or absent, and the daemon has no `node_repl` or `cua-repl` child
  after a pane opens a thread.
- `jq` on `~/.claude.json` (counted, never printed): no user-scope `ha-mcp`;
  `.projects["/Users/michael"].mcpServers["ha-mcp"]` holds the launcher definition.
- A new session in `~`: `/mcp` shows ha-mcp connected and `ha_get_overview` answers.
- A new session in a repository and one in `~/Documents`: no ha-mcp child process.
- A second `reconcile-agents.sh` run reports ha-mcp present and calls no `claude mcp`
  add/remove.
- `./tests/run.sh` passes; `./tests/run.sh reconcile-agents` runs unsandboxed.

## Left to the builder

- How the template tests for the `node_repl` table's existence, within chezmoi's template
  functions.
- How the reconciler stub records the working directory.
- Wording of the new log lines.

## Calls made by Claude Code

- `~` as the directory (Michael confirmed): every HA session so far started there.
- Local scope rather than a project `.mcp.json`, which would put a file in `$HOME`.
- Disable the plugin as a whole rather than its `cua_repl` server: a user-config server entry
  without a command would be invalid.
- The plugin switch is set even when its entry is absent; the `node_repl` switch only when its
  table exists.
- Add the local entry before removing the user-scope one, so failure keeps HA reachable.
- Stale local entries elsewhere are warned about, not removed: they may be hand-made, and the
  2026-10-23 design kept local scope out of the reconciler's reach.
- The 2026-10-23 spec stays as written: its status remains `Implemented`, and this spec
  records the narrowed scope.
