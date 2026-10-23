# Home Assistant MCP server in the dotfiles

**Status:** In progress (branch `feat/ha-mcp`; the dotfiles have no MR)
**Date:** 2026-10-23
**Branch:** `feat/ha-mcp`

## Why

Michael added the Home Assistant MCP server ([ha-mcp](https://pypi.org/project/ha-mcp/)) to
Claude Code and Claude Desktop by hand. Neither registration is in the dotfiles, so a fresh
machine doesn't get it. Both also hold the Home Assistant long-lived token in plaintext:

- `~/.claude.json` (user scope, `uvx ha-mcp`) is mode 0644 and readable by every sandboxed
  Claude Code session.
- `~/Library/Application Support/Claude/claude_desktop_config.json` (`Home Assistant`,
  `uvx --python 3.13 --refresh ha-mcp@latest`) is 0600.

Both hold the same token. VM.Portal also has a local-scope `ha-mcp` entry with no token, which
takes precedence over the user-scope entry in that repository. `uv`/`uvx` in `~/.local/bin`
came from the standalone installer and are declared nowhere.

## Goals

- Both apps get the server from `chezmoi apply` plus the existing provisioning steps.
- The token never enters this public repo, and sandboxed Claude sessions can't read it.
- Upgrading Python in mise moves ha-mcp to it; ha-mcp itself stays current without a pin to
  maintain.
- As simple as possible: easy to upgrade, debug and reinstall.

## Non-goals

- Codex. It reviews, and has no use for Home Assistant.
- Keeping the token from Codex. Codex's sandbox reads every file, so it can read the SSH keys,
  the bundler token and the kube config today, and this token joins them. Codex 0.164 has a
  `deny_read` list in its permission profiles; a Codex read boundary for all secrets is its own
  piece of work (Michael's decision, 2026-10-23).
- Home Assistant's built-in MCP integration. It has far fewer tools than ha-mcp.
- Managing any other MCP server. The mechanisms below handle a second server if one is ever
  added, but nothing is built for that now.

## Design

Six pieces. The token lives in one file, read by one launcher; both apps point at the launcher
and carry no secret.

### 1. Token file

`dot_config/private_ha-mcp/private_env.tmpl` renders `~/.config/ha-mcp/env` (dir 0700, file
0600):

```sh
HOMEASSISTANT_URL=<onepasswordRead "op://Private/Home Assistant MCP/hostname">
HOMEASSISTANT_TOKEN=<onepasswordRead "op://Private/Home Assistant MCP/credential">
```

The same pattern as the bundler token. The URL comes from 1Password too, so the repo carries no
internal hostname. The item is an API Credential named `Home Assistant MCP` in the Private
vault; Michael creates it (see Migration).

### 2. Launcher

`dot_local/bin/executable_ha-mcp`, a POSIX `sh` script:

1. If the env file is unreadable, print `ha-mcp: <path> is missing or unreadable — run chezmoi
   apply` to stderr and exit 1.
2. Export only `HAMCP_ENV_FILE=<that path>`. ha-mcp loads the file itself (python-dotenv,
   then pydantic-settings), so the token sits in no process's launch environment. That
   matters because a sandboxed shell can read another process's launch environment with
   `sysctl KERN_PROCARGS2`, without `ps` (found in the final review; Michael's decision,
   2026-10-23). `HAMCP_ENV_FILE` is in ha-mcp's code (8.7.0) but not its README: if a
   release drops it, the server stops at start with ha-mcp's configuration error naming
   `HOMEASSISTANT_URL`.
3. `cd "$HOME"`, so mise resolves the **global** Python. A project's own `mise.toml` (the
   server starts in whatever directory the session runs) neither changes the Python nor trips
   paranoid mode's untrusted-config refusal.
4. Resolve `mise which python`; if mise has no Python for `$HOME`, print
   `ha-mcp: mise has no Python for $HOME — run mise install` to stderr and exit 1 (mise's own
   message points at `mise use`, the wrong fix).
5. `exec mise exec uv -- uvx --python "<that python>" ha-mcp@latest`, with Homebrew's
   bin on PATH because Claude Desktop starts servers without the shell's PATH. Naming `uv`
   matters: a bare `mise exec --` first installs every missing tool in the config, so a
   Ruby bump not yet installed would make the server compile Ruby before it starts.

`--python` takes the interpreter's full path, so uv uses exactly mise's Python rather than any
other it finds (Homebrew currently has 3.15 as `python3`; ha-mcp requires `>=3.13,<3.15`).
`@latest` makes uv check PyPI for a newer ha-mcp at each start; no `--refresh`, which would
discard every cached download.

### 3. Claude sessions can't read the token

`dot_claude/modify_private_settings.json` gains `Read(~/.config/ha-mcp/**)` and
`Edit(~/.config/ha-mcp/**)` in its deny list. A `Read()` deny is also copied into the sandbox
read-deny list, so sandboxed Bash can't read the file either. MCP servers start outside the
Bash sandbox, so ha-mcp still can; the acceptance checks confirm both. The file entry also
goes in `sandbox.credentials.files`, as `~/.aws/credentials` and `~/.config/op/config` do.
Launching with `HAMCP_ENV_FILE` (§2) keeps the token out of process environments too.

### 4. Claude Desktop

`Library/Application Support/Claude/modify_private_claude_desktop_config.json`, built like
`modify_private_settings.json`: start from the current file on stdin (empty → `{}`), refuse to
overwrite invalid JSON or more than one document, and set only
`.mcpServers["Home Assistant"] = {"command": "$HOME/.local/bin/ha-mcp"}`. Preferences, other
servers and every other key survive. The name `Home Assistant` is kept, so nothing visible
changes in Desktop.

### 5. Claude Code

`~/.claude.json` is 200 KB of state that every running session rewrites, so chezmoi doesn't
manage it. Instead `dot_config/agents/plugins.conf` gains:

```
claude_mcp          ha-mcp
```

and `.scripts/reconcile-agents.sh` learns the `claude_mcp` kind. The value is the server name;
its command is the launcher of the same name, `$HOME/.local/bin/<name>`, with no args and no
env. The reconciler reads `.mcpServers[<name>]` from `~/.claude.json` and:

- absent → `claude mcp add-json <name> '<json>' --scope user`;
- present with exactly that command, no args, no env → reported present;
- present but different → `claude mcp remove <name> --scope user`, then add. This replaces the
  current plaintext-token entry.

Unlike plugins, a differing entry is replaced, not left as-is: the declared command is the
whole definition, and a hand-edited entry is what leaks the token. Other user-scope servers are
untouched, as with plugins. Local- and project-scope entries are out of its reach.

### 6. uv from mise

`uv = "latest"` in `dot_config/mise/config.toml`, with a one-line comment: the launcher runs
uvx through mise, so Python and uv upgrade together with `mise up`. Ansible and pipx already sit
there as tools rather than runtimes.

## Upgrading, reinstalling, debugging

- **Python:** change it in mise and run `mise install`; the next server start uses it. Moving mise past ha-mcp's
  supported range (3.15 today) stops the server, with uv naming the Python mismatch.
- **ha-mcp:** automatic at the next server start. Trade-off accepted by Michael: a new release
  runs with the Home Assistant token without review. Desktop already worked this way.
  `@latest` needs PyPI at every start (measured: uv sends a revalidation request each run and
  exits 2 when it can't connect, even with the package cached). A PyPI outage, or Little Snitch
  holding a newly upgraded uv, stops the server with uv's connection error. Claude itself
  needs the internet, so there is no offline fallback.
- **uv:** `mise up`.
- **Token rotation:** replace it in 1Password, `chezmoi apply`, restart the apps.
- **Fresh machine:** no new steps. `provision.sh` already runs `chezmoi apply`,
  `reconcile-agents.sh` and `mise install`.
- **Debugging:** run `ha-mcp` in a terminal; it either waits for MCP input on stdin or prints
  its error. Status: Claude Code `/mcp`. Logs: Claude Code
  `~/Library/Caches/claude-cli-nodejs/<cwd-slug>/mcp-logs-ha-mcp/`, Desktop
  `~/Library/Logs/Claude/mcp-server-Home Assistant.log`.

## Tests

- `tests/claude-settings.test.sh`: the two deny rules are present.
- New `tests/claude-desktop-config.test.sh`: sets the entry on empty input and on a populated
  file; keeps preferences and other servers; replaces a stale `Home Assistant` entry (with env)
  wholesale; refuses invalid JSON and two documents; idempotent.
- New `tests/ha-mcp.test.sh`: missing env file → exit 1 with the message on stderr; with a
  stub `mise` on a temp HOME, the launcher execs `mise exec uv -- uvx --python <stub python>
  ha-mcp@latest` from `$HOME` with `HAMCP_ENV_FILE` set and no `HOMEASSISTANT_*` variable in
  its environment; mise without a Python → the `mise install` message.
- `tests/reconcile-agents.test.sh`: `claude_mcp` absent → add, matching → no-op, stale (env
  present, different command) → remove + add, other servers untouched, wrong field count
  rejected.

## Migration (one time, after merge)

1. Michael creates a new long-lived token in Home Assistant and stores it as
   **Private / Home Assistant MCP** (API Credential): token in `credential`,
   the Home Assistant URL (scheme, host and port) in `hostname`.
2. Michael runs `chezmoi apply`, then `mise install`.
3. Delete the standalone `~/.local/bin/uv`, `~/.local/bin/uvx` and `~/.config/uv/uv-receipt.json`:
   `~/.local/bin` precedes mise's shims on PATH. Needs Michael's OK at the time.
4. Run `.scripts/reconcile-agents.sh` (replaces the user-scope entry; the plaintext token
   leaves `~/.claude.json`).
5. In VM.Portal: `claude mcp remove ha-mcp --scope local` (approved by Michael).
6. Restart Claude Desktop; start a new Claude Code session.
7. Once both work, Michael revokes the old token in Home Assistant. It sat in a 0644,
   agent-readable file and is in the Borg archives.

Until step 7, the old token also surfaces in: `chezmoi diff`, `cat` and `apply --verbose` of
the Desktop target (a removed line), so nobody previews that target first; and
`~/.claude/backups/`, which `claude mcp remove` writes. Revocation is the real control.

## Acceptance

- `~/.claude.json` (every scope) and the Desktop config hold the launcher path and no old
  token (checked by count, never printed).
- No running ha-mcp process has a `HOMEASSISTANT_TOKEN` in its launch environment (counted,
  never printed).
- Claude Code `/mcp` and Claude Desktop both show the Home Assistant server connected, and
  `ha_get_overview` answers.
- In a new Claude Code session, sandboxed Bash `cat ~/.config/ha-mcp/env` and the Read tool
  are both denied.
- In VM.Portal, `claude mcp get ha-mcp` resolves to the user-scope entry.
- `./tests/run.sh` passes; `reconcile-agents` runs unsandboxed (`./tests/run.sh reconcile-agents`).

## Calls made by Claude Code

- 1Password item name, vault and fields.
- Keeping each app's existing server name (`ha-mcp`, `Home Assistant`).
- Launcher name equals server name, so the manifest line needs no command.
- Replacing a drifted MCP entry, where plugins are add-only.
- `cd "$HOME"` in the launcher rather than `mise -C`.

## Rulings during implementation

- `mise exec uv --`, not a bare `mise exec --`, which first installs every missing tool in
  the config (a Ruby bump would make the server compile Ruby before it starts).
- `claude_mcp` names are ASCII `[A-Za-z0-9._-]` checked in the C locale, and may not start
  with `.` or `-` (a leading `-` would reach `claude mcp` as an option).
- The env file also gets a `sandbox.credentials.files` entry, matching the repo's other
  single credential files.
- Launching with `HAMCP_ENV_FILE` instead of exporting the token (Michael's decision).
