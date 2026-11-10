# Home Assistant MCP server away from home

**Status:** Approved
**Date:** 2026-11-10
**Branch:** `feat/ha-mcp-remote`
**Amends:** [`2026-10-23-ha-mcp-design.md`](2026-10-23-ha-mcp-design.md) §1 to §3

## Why

ha-mcp reaches Home Assistant at the home address stored in 1Password
(`op://Private/Home Assistant MCP/hostname`). Away from home that name does not resolve, so
every Home Assistant tool fails: on 10 November 2026 each call returned `[Errno 8] nodename
nor servname provided, or not known`. Home Assistant Cloud (Nabu Casa) remote access has been
on since 25 October 2026 and serves the same API, WebSocket included, at
`https://<id>.ui.nabu.casa`. Michael wants the home address when he is home and the remote
address when he is away, without editing files.

## Goals

- At home, the server uses the home address, exactly as today.
- Away, it uses the remote address with the same token, with no file edits.
- The token handling of the 2026-10-23 design holds: the token lives only in 0600 files
  rendered from 1Password, never in a process's launch environment, and sandboxed Claude
  sessions cannot read it.
- Neither address enters this public repo.

## Non-goals

- Switching while the server runs. The address is chosen when the server starts; after
  moving between home and away, reconnect it (Claude Code `/mcp`, Claude Desktop: restart).
- Always using the remote address: at home, Home Assistant would then depend on the internet
  and Nabu Casa.
- The UniFi MCP server (`~/.config/unifi-network/env`); it has no remote path today.
- The Companion app and Home Assistant's own remote-access settings.

## Design

### 1. Remote address in 1Password

The item `Private / Home Assistant MCP` gains a text field `remote_url`: the full remote URL,
`https://<id>.ui.nabu.casa`, with no path and no trailing slash. Michael adds it (Migration).

### 2. A second env file

`dot_config/private_ha-mcp/private_env-remote.tmpl` renders `~/.config/ha-mcp/env-remote`
(0600 through `private_`, in the existing 0700 directory):

```sh
HOMEASSISTANT_URL={{ onepasswordRead "op://Private/Home Assistant MCP/remote_url" | squote }}
HOMEASSISTANT_TOKEN={{ onepasswordRead "op://Private/Home Assistant MCP/credential" | squote }}
```

Same token, same quoting as `env`. Nabu Casa's remote access proxies the whole Home
Assistant HTTP and WebSocket API and accepts long-lived tokens, so ha-mcp needs nothing else.
`onepasswordRead` fails on a missing field, which stops `chezmoi apply`; that is why the field
comes first in the Migration.

### 3. The launcher chooses the file

`dot_local/bin/executable_ha-mcp` keeps its five steps. Between step 1 (`env` unreadable →
error) and step 2 (export `HAMCP_ENV_FILE`) it chooses which file to export:

1. `env-remote` unreadable or absent → `env`, without a probe. This is today's behaviour, so
   a machine without the remote field works as before.
2. Read the home URL from `env`'s `HOMEASSISTANT_URL=` line with `sed`, stripping the single
   quotes `squote` adds and one trailing slash. The launcher never sources the file and never
   reads the token line. No such line, or an empty value → `env`, without a probe; ha-mcp
   then reports its own configuration error, as today.
3. Probe the home URL: `curl -k -s -o /dev/null --connect-timeout 1 --max-time 2 "<url>/"`.
   Any HTTP answer (curl exits 0, whatever the status) means home is reachable → `env`. The
   probe sends no token and discards its output. `-k` because it only asks whether something
   answers: a home certificate curl cannot verify must not send Michael to the remote address
   while he is home.
4. Any other exit (no DNS answer, refused, timed out) → `env-remote`, and one line on stderr:
   `ha-mcp: home address unreachable; using env-remote`. The line names no address; stderr
   goes to the MCP log.

As its first action, before any external command, the launcher unsets any inherited
`HOMEASSISTANT_URL` and `HOMEASSISTANT_TOKEN`, so no child (`sed`, `curl`, `mise`) inherits
them. python-dotenv does not override variables already set, and pydantic-settings prefers the
process environment over the file, so an inherited value would otherwise beat the chosen file.

`curl` is called by name: `/usr/bin` is already on the launcher's PATH, and a test stub
can stand in for it. If the remote address fails as well, ha-mcp reports its connection error,
as it does today for the home address.

Cost: at home the probe answers in milliseconds. Away, a name that does not resolve fails at
once; an address that does not answer costs at most 2 seconds at server start.

### 4. Sandbox

`Read(~/.config/ha-mcp/**)` and `Edit(~/.config/ha-mcp/**)` already cover `env-remote`.
`dot_claude/modify_private_settings.json` adds
`{ "path": "~/.config/ha-mcp/env-remote", "mode": "deny" }` to `sandbox.credentials.files`,
next to the `env` entry.

## Tests

`tests/ha-mcp.test.sh` gains a stub `curl` in `$T/bin` that appends its arguments and its
`HOMEASSISTANT_URL` and `HOMEASSISTANT_TOKEN` values to a log and exits `MOCK_CURL_RC`
(default 0). The existing cases keep passing unchanged; case B has
no `env-remote`, so `curl` must not run there. New cases:

- **No `env-remote`:** exports `env`; `curl` never ran; stderr empty.
- **`env-remote` present but unreadable (mode 000):** exports `env`; `curl` never ran.
- **Home answers** (`MOCK_CURL_RC=0`): exports `env`; stderr empty.
- **Home does not answer** (`MOCK_CURL_RC=6`, and again with `28`): exports `env-remote`;
  stderr is exactly the line in §3; the exec line is otherwise unchanged and the
  environment still holds no `HOMEASSISTANT_*` variable.
- **Probe arguments:** `curl` received the home URL from `env` without its quotes, followed by
  `/`, plus `-k`, `--connect-timeout 1` and `--max-time 2`; its arguments never contain the
  token or the remote URL. A home URL with a trailing slash still gives a single `/`.
- **No URL line in `env`:** exports `env`; `curl` never ran.
- **Inherited variables:** with `HOMEASSISTANT_URL` and `HOMEASSISTANT_TOKEN` set in the
  caller's environment, neither the `curl` stub nor `mise` sees either variable, both when
  home answers and when it does not.
- **Template:** `private_env-remote.tmpl` is exactly the two lines in §2.
- In every case, neither stdout nor stderr contains the token.

`tests/claude-settings.test.sh`: the credential-file list includes
`~/.config/ha-mcp/env-remote` as `deny`, and the counts that pin the list move with it.

## Migration (after merge)

1. Michael adds the field `remote_url` to `Private / Home Assistant MCP`.
2. Michael runs `chezmoi apply`.
3. Reconnect ha-mcp in Claude Code (`/mcp`); restart Claude Desktop.
4. If Little Snitch asks about `curl` reaching the home address, or Python reaching
   `*.ui.nabu.casa`, Michael allows it.

## Acceptance

- Away from home (or with the home address unreachable): after the reconnect, a read such as
  `ha_get_state` works, and the MCP log has the `using env-remote` line.
- At home: after a reconnect, the same read works and the log has no such line.
- A sandboxed `cat ~/.config/ha-mcp/env-remote` is denied.

## Known limits

- The address is chosen at server start only; a reconnect is needed after moving.
- A foreign network that happens to answer HTTP at the home address makes the launcher choose
  `env`; ha-mcp then fails to connect or authenticate until a reconnect elsewhere.
- Away, every call goes through Nabu Casa: slower, and down when their service is.
- A firewall rule that blocks the probe at home sends the server to the remote address. It
  still works, only slower, and the `using env-remote` line in the MCP log shows it.

## Calls made while writing, not by Michael

- `-k` on the probe, and stripping one trailing slash from the home URL (§3).
- The Little Snitch step in the Migration, and the firewall limit above.
