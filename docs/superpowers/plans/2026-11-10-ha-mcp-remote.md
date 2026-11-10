# Home Assistant MCP Away From Home Implementation Plan

**Status:** In progress (branch `feat/ha-mcp-remote`; the dotfiles have no MR)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The ha-mcp launcher uses the home address when it answers and the Nabu Casa address otherwise, with the token handling of the 2026-10-23 design intact.

**Architecture:** A second chezmoi template renders `~/.config/ha-mcp/env-remote` (remote URL, same token). The POSIX launcher clears inherited `HOMEASSISTANT_*` variables, probes the home URL from `env` with `curl`, and exports `HAMCP_ENV_FILE` as `env` or `env-remote`. The Claude settings deny the new file in the sandbox credential list.

**Tech Stack:** POSIX sh on macOS (BSD `sed`, `/usr/bin/curl`), chezmoi templates, jq (settings tests).

**Spec:** `docs/superpowers/specs/2026-11-10-ha-mcp-remote-design.md` (Approved).

## Global Constraints

- No secret and no real address in the repo. Templates use only `onepasswordRead "op://Private/Home Assistant MCP/<field>" | squote`; tests use `http://h:8123` (home), `https://r.example` (remote) and the token sentinel `SECRET-TOKEN-123`.
- No test, launcher line or log prints the token; every new case asserts it is absent from stdout and stderr.
- No `HOMEASSISTANT_URL` or `HOMEASSISTANT_TOKEN` in any child of the launcher (`sed`, `curl`, `mise`).
- The launcher stays POSIX `sh` (`#!/bin/sh`, `sh -n` clean) and calls `sed` and `curl` by name.
- Exact strings from the spec: the probe is `curl -k -s -o /dev/null --connect-timeout 1 --max-time 2 "<home url>/"`; the stderr line is `ha-mcp: home address unreachable; using env-remote`.
- Never run `op`, never read anything under `~/.config/ha-mcp`, and never run a chezmoi command that renders templates (`apply`, `cat`, `diff`, `status`, `execute-template`): rendering calls 1Password and prints the token. The suites' own `chezmoi --source <checkout> managed` (`tests/claude-settings.test.sh` section X) lists target paths without rendering contents and stays allowed. `chezmoi apply` is Michael's, after merge.
- Suites are executed directly (`./tests/<name>.test.sh`), never through an interpreter. Report results as passed/total.
- Never start a Bash call with `cd`; use absolute paths or `git -C`.
- Implementers do not commit. They run only their task's suites and report back; the controller commits each task.

## Review Focus

1. Home Assistant at home behind HTTPS with a certificate curl cannot verify: the launcher must still choose `env` (`-k` pinned in the probe arguments, Task 2).
2. `HOMEASSISTANT_URL`/`HOMEASSISTANT_TOKEN` inherited from the app's environment: cleared before the first child process, seen by neither `curl` nor `mise` (Task 2).
3. `env-remote` present but unreadable: `env`, no probe (Task 2).
4. A home URL with a trailing slash: the probe gets exactly one `/` (Task 2).
5. `env` without a `HOMEASSISTANT_URL=` line: `env`, no probe, so ha-mcp reports its own configuration error as today (Task 2).

---

### Task 1: Remote env template and sandbox entry

**Depends on:** none.

**Files:**
- Create: `dot_config/private_ha-mcp/private_env-remote.tmpl`
- Modify: `dot_claude/modify_private_settings.json` (`sandbox.credentials.files`, after the `~/.config/ha-mcp/env` entry)
- Test: `tests/ha-mcp.test.sh` (section E), `tests/claude-settings.test.sh` (`EXP_CREDENTIALS`)

**Interfaces:**
- Produces: `~/.config/ha-mcp/env-remote`, the file Task 2 selects.

- [ ] **Step 1: Write the failing tests.**
  - `tests/ha-mcp.test.sh`: add `TPL_REMOTE="$SRC/dot_config/private_ha-mcp/private_env-remote.tmpl"` beside `TPL`, with the same missing-file guard (exit 2). In section E add:
    ```bash
    EXPECTED_REMOTE='HOMEASSISTANT_URL={{ onepasswordRead "op://Private/Home Assistant MCP/remote_url" | squote }}
    HOMEASSISTANT_TOKEN={{ onepasswordRead "op://Private/Home Assistant MCP/credential" | squote }}'
    check "remote template references the remote_url and credential fields" "$EXPECTED_REMOTE" "$(cat "$TPL_REMOTE")"
    ```
  - `tests/claude-settings.test.sh`: add `"~/.config/ha-mcp/env-remote",` to `EXP_CREDENTIALS` after `"~/.config/ha-mcp/env",`.
- [ ] **Step 2: Run them to see them fail.** `./tests/ha-mcp.test.sh` exits 2 (missing template); `./tests/claude-settings.test.sh` fails "credential path set matches the approved inventory exactly".
- [ ] **Step 3: Implement.** Create the template with exactly the two lines of `EXPECTED_REMOTE` (trailing newline, as `private_env.tmpl`). Add `{ "path": "~/.config/ha-mcp/env-remote", "mode": "deny" },` after the `env` entry, columns aligned with its neighbours.
- [ ] **Step 4: Run them to see them pass.** `./tests/ha-mcp.test.sh` and `./tests/claude-settings.test.sh`: all pass.
- [ ] **Step 5: Commit** (controller): `git -C <checkout> add dot_config/private_ha-mcp/private_env-remote.tmpl dot_claude/modify_private_settings.json tests/ha-mcp.test.sh tests/claude-settings.test.sh`; `git -C <checkout> commit -m "Render a remote ha-mcp env file and deny it to the sandbox"`.

### Task 2: The launcher chooses the env file

**Depends on:** Task 1 (both change `tests/ha-mcp.test.sh`).

**Files:**
- Modify: `dot_local/bin/executable_ha-mcp`
- Test: `tests/ha-mcp.test.sh`

**Interfaces:**
- Consumes: `$HOME/.config/ha-mcp/env` and `$HOME/.config/ha-mcp/env-remote` (Task 1).
- Produces: `HAMCP_ENV_FILE` set to one of those two paths; nothing else changes in the exec line.

- [ ] **Step 1: Write the failing tests.**
  - A stub `curl` in `$T/bin` (beside the `mise` stub) appends one line per call to `$T/curl.log`: `"$*|${HOMEASSISTANT_URL-unset}|${HOMEASSISTANT_TOKEN-unset}"`, then exits `${MOCK_CURL_RC:-0}`.
  - A `sed` wrapper in `$T/bin` appends one line per call to `$T/sed.log`, `<url>|<token>`, where each field is `set` or `unset` for `HOMEASSISTANT_URL` and `HOMEASSISTANT_TOKEN` (never the value), then `exec /usr/bin/sed "$@"`.
  - `run()` empties `$T/curl.log` and `$T/sed.log` as it empties `$LOG`. `ENVR="$T/home/.config/ha-mcp/env-remote"`.
  - Case B (no `env-remote`): add `check "curl never ran" "" "$(cat "$T/curl.log")"`.
  - New cases, each writing `env` as `HOMEASSISTANT_URL='http://h:8123'` plus the sentinel token, and `env-remote` as `HOMEASSISTANT_URL='https://r.example'` plus the sentinel, unless stated:
    - **F. `env-remote` unreadable** (`chmod 000`; restore after): mise log's third field is `$T/home/.config/ha-mcp/env`; curl log empty.
    - **G. home answers** (`MOCK_CURL_RC=0`): third field is `env`; stderr empty; curl log is exactly `-k -s -o /dev/null --connect-timeout 1 --max-time 2 http://h:8123/|unset|unset`.
    - **H. home does not answer**, once with `MOCK_CURL_RC=6` and once with `28`: mise log is exactly `$T/home|exec uv -- uvx --python /stub/python ha-mcp@latest|$T/home/.config/ha-mcp/env-remote|unset|unset|1`; stderr is exactly `ha-mcp: home address unreachable; using env-remote`; exit 0.
    - **I. trailing slash:** `env` URL `'http://h:8123/'` → the curl log's URL argument is `http://h:8123/`.
    - **J. no URL line:** `env` holds only the token line → third field is `env`; curl log empty.
    - **K. inherited variables:** run with `HOMEASSISTANT_URL=http://stale HOMEASSISTANT_TOKEN=SECRET-TOKEN-123` in the caller's environment, with `MOCK_CURL_RC=0` and with `6`: the sed log is non-empty and every line is `unset|unset`; the curl log line ends `|unset|unset`; the mise log's fourth and fifth fields are `unset`.
    - In F to K: stdout and stderr never contain the sentinel; the curl log never contains the sentinel or `r.example`.
- [ ] **Step 2: Run them to see them fail.** `./tests/ha-mcp.test.sh`: H, G (curl log), I and K fail.
- [ ] **Step 3: Implement in `dot_local/bin/executable_ha-mcp`.**
  - Right after `set -eu`: `unset HOMEASSISTANT_URL HOMEASSISTANT_TOKEN`.
  - After the existing `env` readability check, choose the file, in this order: `env-remote` not readable → `env`; home URL from the first `HOMEASSISTANT_URL='…'` line of `env` via `sed` (quotes stripped, one trailing `/` removed), empty → `env`; `if curl -k -s -o /dev/null --connect-timeout 1 --max-time 2 "$url/"` → `env`; else `env-remote` and the stderr line. Use `if`, not a bare call, so `set -e` does not end the launcher when curl fails.
  - `HAMCP_ENV_FILE` takes the chosen path; the rest of the launcher is unchanged. Update the header comment's first lines to say the launcher picks `env` or `env-remote`.
- [ ] **Step 4: Run them to see them pass.** `./tests/ha-mcp.test.sh`: all pass, D (`sh -n`) included.
- [ ] **Step 5: Commit** (controller): `git -C <checkout> add dot_local/bin/executable_ha-mcp tests/ha-mcp.test.sh`; `git -C <checkout> commit -m "Fall back to the remote Home Assistant address when home does not answer"`.

### Finish

- [ ] `./tests/run.sh`, then the three heavy suites by exact name (AGENTS.md: before every pre-merge review): `./tests/run.sh xreview git-forge-guard wt-functions`. Report passed/total.
- [ ] Final whole-branch review, then Codex pre-merge on `main...feat/ha-mcp-remote`.
- [ ] Set the spec's and this plan's Status to `Implemented (branch feat/ha-mcp-remote; the dotfiles have no MR)`, mark this plan executed, commit, then `git -C <checkout> push origin feat/ha-mcp-remote`.
- [ ] Final report: the Migration steps for Michael (spec), and the `git worktree` cleanup command for him after merge.
