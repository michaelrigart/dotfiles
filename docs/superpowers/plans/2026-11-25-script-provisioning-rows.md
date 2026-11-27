# Script provisioning's NetBird, Syncthing, Vorta and login-item rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: the `plan-run` skill (it overrides
> superpowers:subagent-driven-development). Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Completed (PR #54); do not run it again. Michael chose on 2026-11-25 to execute Tasks
2–7 before Codex's reviews, then on 2026-11-27 to skip Codex's reviews, and so Task 1, for a full
review later.

**Goal:** A reinstalled fenrir or hercules ends `provision.sh` with NetBird joined by setup key,
Syncthing configured before its first start, Vorta holding its profile, and the login apps started
by a LaunchAgent; each of those rows is `script` with a check, and a re-run changes nothing.

**Architecture:** The preflight (new step 5c) reads three 1Password items, only for the steps a
read-only test finds not done, into unexported variables; steps 8c (NetBird), 8d (Syncthing) and
15b (Vorta) hand them to their command on stdin or in a mode-600 file and unset them. A plain
LaunchAgent, `be.netronix.login-apps`, opens the login apps; `configure.sh`'s loader loads it.

**Tech Stack:** zsh (`provision.sh`), bash 3.2 (the suites), jq, sqlite3, xmllint, launchd.

**Spec:** `docs/superpowers/specs/2026-11-25-script-provisioning-rows-design.md` (signed off
2026-11-25: D1 LaunchAgent, D2 Vorta's export as a Document, D3 the item names, D4 a VM run).

## Global Constraints

- Read `tests/AGENTS.md` before editing under `tests/`. Execute suites (`./tests/x.test.sh`),
  never `bash tests/x.test.sh`. Run only the suites your task names.
- Never run `provision.sh`, `configure.sh`, `netbird up|service`, `op`, `syncthing generate`
  against the real home, `open`, `launchctl bootstrap|bootout`, `security` or `chezmoi apply`
  for real. The suites stub them.
- Public repository: no secret, account, vault content or private host in any file; test secrets
  are the marker strings below. No agent attribution. Implementers do not commit; the controller
  does, after `git -C <checkout> branch --show-current` reads `feat/script-provisioning-rows`.
- Secrets never reach a command's arguments or environment, and are never printed or logged. They
  reach commands only through zsh's `print -r --` (a builtin) on a pipe, or the Vorta file.
- Every external command a new step runs without a secret reads `</dev/null`.
- Every new step is safe to re-run: a done step reads no item and changes nothing.
- 1Password item names (D3), exactly: `NetBird setup key` (field `credential`), `Syncthing GUI`
  (fields `username`, `password`), `BorgBase <machine>` (a Document: Vorta's export with its
  password). Vault: `${PROVISION_OP_VAULT:-Private}`.
- Test markers, used only in `tests/provision.test.sh`: `MARK-NB-KEY-7f3a`, `MARK-ST-PW-91c2`,
  `MARK-VORTA-PW-d4e8` (the export's `password`). The Syncthing user is `st-user`.
- Mode 755 for scripts and suites; the checklist and plists 644. New files a suite loads get their
  `tests/subjects/<suite>.tsv` row in the same commit (rows sorted `LC_ALL=C`).
- `AGENTS.md` stays at 240 lines (`tests/agent-instructions.test.sh`).
- No `rm` through a variable; literal paths. `git -C <checkout>`, never `cd … &&`.

## Rulings taken in this plan (inside the spec; they go under "Rulings" in the PR)

1. One seam, `PROVISION_APPLICATIONS` (default `/Applications`), replaces the spec's
   `PROVISION_SYNCTHING_BIN`: it locates both Syncthing's bundled binary and Vorta.app.
2. Step 15b also requires `Vorta.app` to be installed. Without it no start could import the file,
   so the secret would stay on disk indefinitely (spec §4's lifetime bound).
3. The login apps are one list on both machines; the job's `[ -d ]` test skips an app the machine
   lacks (Elgato Control Center's cask is fenrir's only). So the job is a plain `.plist`, not a
   per-machine template.
4. The preflight's sub-steps are renumbered: 5c secrets, 5d sudo refresh, 5e summary, 5f identity.
5. Step 8c waits up to 30 s for the just-started daemon to answer `netbird status --json`.
6. The secret variables are declared `typeset +x`, so a caller that exported the same names cannot
   make them reach a child's environment.

## Review Focus

1. A caller's environment already exports `PV_NETBIRD_KEY` (or another secret variable's name):
   the secret must still reach no child's environment (Task 2).
2. A secret with shell-special content (`-n`, `$(…)`, backslashes, a trailing space) reaches the
   command's stdin byte for byte, and nothing in it runs (Tasks 3 and 4).
3. `~/.vorta-init.json` is a dangling symlink: nothing is written, through it or anywhere (Task 5).
4. `netbird status --json` prints something without `daemonStatus` (an older client, garbage):
   that is "unreadable", so the preflight reads the key and step 8c warns instead of joining
   (Tasks 2 and 3).
5. Syncthing.app or Vorta.app is missing because its cask failed: the step warns and writes nothing
   (Tasks 4 and 5).

---

## Order

Tasks 2–7 run first (Michael, 2026-11-25). Then, on or after 2026-11-28 09:29, the reviews below,
then Task 1, then Task 8.

## Codex's reviews (controller, on or after 2026-11-28 09:29)

In order, each through the `cross-review` skill with `xreview -C <checkout>`, `round --reset`
between checkpoints:

1. `--checkpoint spec` on the committed spec. A finding that would change it goes to Michael.
2. `--checkpoint plan` on this plan. A plan finding is fixed in the plan and in the code Tasks 2–7
   wrote, before each re-dispatch.
3. `--checkpoint pre-merge` on #46's `5a86be4..4c57690` and #47's `187ad97..0643bbe` together
   (two `--diff` arguments if `xreview` takes them, else two dispatches back to back). If #47 has
   not merged by then, its findings go to the driver (chezmoi-94), not into this line. If it has,
   rebase this branch onto `origin/main` first.

### Task 1: Fix Codex's findings on #46 and #47

**Depends on:** the reviews above (so it runs after Task 7).

One commit per verified finding (or per shared cause), test first where its bug could return, each
message stating the invariant restored. Record their non-test size under the spec's `**Size:**`;
past about 150 lines, stop and ask Michael whether they move to a line of their own. Suites: the
ones whose subjects the fixes touch, then `./tests/run.sh --changed`.

### Task 2: The preflight reads the setup secrets (step 5c)

**Depends on:** nothing.

**Files:**
- Modify: `.scripts/provision.sh` (knobs near `BREW_BIN`; new 5c after the machine name; summary;
  the `PROVISION_REF`-style refusal)
- Modify: `AGENTS.md` (the "Never commit a secret" bullet)
- Test: `tests/provision.test.sh` (stubs, `reset`, `run`, new section `U`)

**Interfaces:**
- Produces, in `provision.sh`: `OP_VAULT`, `APPS="${PROVISION_APPLICATIONS:-/Applications}"`,
  `ST_BIN="$APPS/Syncthing.app/Contents/Resources/syncthing/syncthing"`,
  `ST_HOME="$HOME/Library/Application Support/Syncthing"`,
  `VORTA_DB="$HOME/Library/Application Support/Vorta/settings.db"`,
  `VORTA_INIT="$HOME/.vorta-init.json"`; `netbird_state` (prints `daemonStatus`, returns 1 when
  the status cannot be read or has no `daemonStatus`); `vorta_state` (prints `absent`, `none`,
  `configured` or `unreadable`; `none` only when `sqlite3 -readonly` succeeds and
  `select count(*) from backupprofilemodel where repo_id is not null` is 0); `NEED_NETBIRD`,
  `NEED_SYNCTHING`, `NEED_VORTA` (0 or 1); `typeset +x PV_NETBIRD_KEY PV_ST_USER PV_ST_PASSWORD
  PV_VORTA_EXPORT`, empty when not read.
- Produces, in the suite: `$T/op-items/<vault>/<item>/<field>` (a Document's content in
  `.../document`) answer `op read op://<vault>/<item>/<field>` and `op document get <item> --vault
  <vault>`; a missing file makes op exit 1. `$T/netbird-status` is what `netbird status --json`
  prints (absent: `{"daemonStatus":"Connected","management":{"connected":true}}`). `reset` leaves
  a set-up machine: `config.xml` in `$T/home/Library/Application Support/Syncthing`, and a real
  `settings.db` (made with `/usr/bin/sqlite3`) holding one profile with `repo_id` 1. Helpers
  `items_all` (writes all four items with the markers) and `fresh_steps` (removes `config.xml`
  and `settings.db`, sets `NeedsLogin`). `run` passes `PROVISION_OP_VAULT` and
  `PROVISION_APPLICATIONS` (default `$T/apps`, checked with `assert_inside`).

- [ ] **Step 1: Write the failing tests (section `U. the preflight reads only what a step needs`)**
  - `fresh_steps; items_all; run 'hercules\ny\n'`: `called "op read op://Private/NetBird setup
    key/credential"`, `called "op read op://Private/Syncthing GUI/username"`, `…/password`,
    `called "op document get BorgBase hercules --vault Private"`; each `op read`/`op document`
    line number below the first `scutil --set ComputerName` line.
  - Default `reset` (all done): `not_called "op read"`, `not_called "op document"`, and the
    summary has `Setup secrets ...... none needed`.
  - Each item missing in turn (and one whose value is `"  \n"`): `rc_is 0`; the summary line
    `Not read from 1Password  <item>` and the closing list's `⚠ 1Password item '<item>' could not be
    read from Private:` both name it.
  - `fail-netbird` (status unreadable) and `$T/netbird-status` = `{"version":"0.20"}`: the key is
    read. `LoginFailed`: read. `SessionExpired`, `Idle`, `Connecting`: not read.
  - `settings.db` replaced by the bytes `not a database`: the BorgBase item is not read, and
    `has "Vorta's settings could not be read"`.
  - `PROVISION_OP_VAULT=Test HV=1`: reads use `op://Test/…` and `--vault Test`; the summary shows
    `1Password vault .... Test`. `PROVISION_OP_VAULT=Test HV=0`: `rc_is 1`, `not_called "sudo -v"`,
    `has "PROVISION_OP_VAULT"`.
  - With `PV_NETBIRD_KEY=decoy` exported into the run and `NeedsLogin`: no `netbird-env` line in
    `$CALLS` carries `PV_NETBIRD_KEY` (Review Focus 1).
  - Section T: the preflight's `netbird status --json`, `op read` and `op document get` read
    `/dev/null` (a new `read-stdin-op` marker for the `op` stub's `read` and `document`): a call
    that did not would eat the answer to "Proceed?".
- [ ] **Step 2: Run `./tests/provision.test.sh`; expect the new section's assertions to FAIL and
  every older one to pass.**
- [ ] **Step 3: Implement step 5c, the knobs and the summary in `provision.sh`.** The
  `PROVISION_OP_VAULT` refusal sits beside `PROVISION_REF`'s, before `sudo`. 5c runs the three
  done-tests, then `op read … </dev/null 2>/dev/null` / `op document get … </dev/null
  2>/dev/null` into the `PV_*` variables through `$(…)`; a failed read or a value empty once
  `[[:space:]]` is removed adds the item to `UNREAD_ITEMS` and empties its variable. The summary
  gains `Setup secrets ...... read: <items>` or `none needed`, and for unread ones
  `Not read from 1Password  <items> — answer n, add or unlock them in 1Password (<vault>) and run
  again; y skips their steps`. Each unread item `warn`s `1Password item '<item>' could not be read from <vault>: <what>
  skipped — see the <row> row` after the confirmation. A `vorta_state` of `unreadable` warns
  `Vorta's settings could not be read: no profile imported — see the vorta row`.
- [ ] **Step 4: Rewrite the forge-token exception in `AGENTS.md` as two exceptions:** the forge
  tokens as today, and `provision.sh`'s preflight, which reads the setup items with `op` and hands
  them to their command on stdin (spec 2026-11-25-script-provisioning-rows §1). Same line count.
- [ ] **Step 5: Run `./tests/provision.test.sh` and `./tests/agent-instructions.test.sh`; expect
  all to pass.**
- [ ] **Step 6: Commit** `Read provisioning's setup secrets at the preflight, only for steps not done`.

### Task 3: NetBird joins with the setup key (step 8c) and its rows

**Depends on:** Task 2 (`PV_NETBIRD_KEY`, `NEED_NETBIRD`, `netbird_state`, the netbird stub).

**Files:**
- Modify: `.scripts/provision.sh` (8c after 8b), `.scripts/machine-checklist.tsv`, the spec's
  `**Provisioning:**` line
- Test: `tests/provision.test.sh` (section `V`; section `T`)

**Interfaces:**
- Consumes: Task 2's names. Produces: the stub's `$T/netbird-up-stdin` (what `up` read) and
  `netbird-env <VAR=value>` lines in `$CALLS` for every netbird call.

- [ ] **Step 1: Write the failing tests (section `V. NetBird joins with the setup key`)**
  - `NeedsLogin` and `LoginFailed`: `called "netbird up --no-browser --setup-key-file /dev/stdin"`,
    `not_called "sudo netbird up"`, `$T/netbird-up-stdin` is exactly `MARK-NB-KEY-7f3a`.
  - A key of `-n $(touch $T/pwned) \x` arrives byte for byte; `$T/pwned` does not exist.
  - `Connected`, `Idle`, `Connecting`, `SessionExpired`, and no key read: `not_called "netbird up"`.
  - `NeedsLogin` with `fail-netbird-up` (a new marker failing only `up`): `rc_is 0`, `has "netbird
    up (SSO login)"`.
  - Status unreadable at 8c (`fast-sleep`, `fail-netbird`): `not_called "netbird up"`, a warning
    naming the SSO fallback, and `sleep` called (the 30 s wait).
  - Section T: the `read-stdin-netbird` cases still pass; `netbird status --json` reads `/dev/null`.
- [ ] **Step 2: Run the suite; expect section V to FAIL.**
- [ ] **Step 3: Implement 8c:** when `NEED_NETBIRD` and the key are set, wait up to 30 s (`sleep 2`)
  for `netbird_state`; on `NeedsLogin`/`LoginFailed` run `print -r -- "$PV_NETBIRD_KEY" |
  /usr/bin/timeout -k 5 120 netbird up --no-browser --setup-key-file /dev/stdin`, else log the
  state and skip. Failure or no state: `warn "NetBird did not join with the setup key — run: netbird
  up (SSO login); on hercules then turn Session Expiration off (netbird-session-expiry row)"`.
  `unset PV_NETBIRD_KEY` after.
- [ ] **Step 4: Change the rows** (spec §2, §6), the `script` ones moved above the first `you` row,
  after `netbird-service`:
  - `netbird-up all script` `provision.sh joins NetBird with the setup key in 1Password's "NetBird
    setup key" (fallback: netbird up and the SSO login)`, verify unchanged.
  - `netbird-session-expiry hercules you` `Only if hercules joined with SSO: NetBird dashboard,
    Peers, hercules, Session Expiration off (section 8 B3)`, verify `s=$(netbird status --json
    2>/dev/null) && print -r -- "$s" | /usr/bin/jq -e '.daemonStatus == "Connected" and
    .management.connected == true and (has("sessionExpiresAt") | not)' >/dev/null`.
  - New, after it: `netbird-old-peer all you` `On a reinstalled machine: delete its old peer in the
    NetBird dashboard, then put its new NetBird IP in the other machine's Syncthing address for it
    (section 8 E2) and, for hercules, in the SSH config note (section 2)`, verify `-`.
  - The spec's `**Provisioning:**` line gains `netbird-old-peer`.
  - Before writing the session-expiry verify, confirm the field names read-only on fenrir, outside
    the sandbox: `netbird status --json | jq '{d: .daemonStatus, m: .management.connected, k: keys}'`.
- [ ] **Step 5: Run `./tests/provision.test.sh`, `./tests/provisioning.test.sh` and
  `./tests/machine-check.test.sh`; expect all to pass.**
- [ ] **Step 6: Commit** `Join NetBird with the setup key during provisioning`.

### Task 4: Syncthing's config is generated before its first start (step 8d)

**Depends on:** Task 2 (`PV_ST_USER`, `PV_ST_PASSWORD`, `NEED_SYNCTHING`, `ST_BIN`, `ST_HOME`).

**Files:**
- Modify: `.scripts/provision.sh` (8d after 8c), `.scripts/machine-checklist.tsv`
- Test: `tests/provision.test.sh` (section `W`)

**Interfaces:**
- Produces, in the suite: a stub at `$T/apps/Syncthing.app/Contents/Resources/syncthing/syncthing`
  that logs its arguments and `syncthing-env` lines, writes its stdin to `$T/syncthing-stdin`, and
  for `generate --home <dir>` writes `<dir>/config.xml` (mode 600) in the shape `generate` wrote on
  fenrir: `<configuration version="52">`, a `<gui>` with `<user>` and a `$2a$10$…` `<password>`,
  and in `<options>`, each on its own line indented eight spaces,
  `<globalAnnounceEnabled>true</globalAnnounceEnabled>`, `<localAnnounceEnabled>true</…>`,
  `<relaysEnabled>true</…>`, `<natEnabled>true</…>`. `fail-syncthing` exits 1 writing nothing.

- [ ] **Step 1: Write the failing tests (section `W. Syncthing's config before its first start`)**
  - `fresh_steps; items_all`: `called "syncthing generate --home $T/home/Library/Application
    Support/Syncthing --gui-user st-user --gui-password=-"`; `$T/syncthing-stdin` is exactly
    `MARK-ST-PW-91c2`; `xmllint --xpath` reads `false`, `false`, `false`, `true` for the four
    options; the file's mode is 600 with the run under `umask 022`.
  - A password of `-n $(touch $T/pwned) \x` arrives byte for byte; nothing runs.
  - `config.xml` present: `not_called "syncthing generate"`, the file is byte-identical (`cmp`).
  - `fail-syncthing`: `rc_is 0`, a warning naming the `syncthing-settings` row.
  - No stub binary (`$T/apps/Syncthing.app` removed): `has "Syncthing.app is not installed"`, no
    generate.
  - A stub variant without `<relaysEnabled>` (`$T/st-no-relays`): a warning naming the options not
    set.
- [ ] **Step 2: Run the suite; expect section W to FAIL.**
- [ ] **Step 3: Implement 8d:** skip unless `NEED_SYNCTHING`, both values and no `config.xml`;
  `[ -x "$ST_BIN" ]` else warn; `mkdir -p -m 700 "$ST_HOME"`; `print -r -- "$PV_ST_PASSWORD" |
  /usr/bin/timeout -k 5 60 "$ST_BIN" generate --home "$ST_HOME" --gui-user "$PV_ST_USER"
  --gui-password=-`; then one `sed -i ''` turning `<x>true</x>` into `<x>false</x>` for the three
  options; then `xmllint --xpath "string(//options/<x>)"` for all four, warning `Syncthing's options
  <names> are not as section 8 E1 wants — set them in Syncthing's GUI`. Failure warns `Syncthing's
  config was not generated — see the syncthing-settings row`. Unset both variables after.
- [ ] **Step 4: Change the row:** `syncthing-settings all script` `provision.sh generates Syncthing's
  config before its first start: the GUI login from 1Password's "Syncthing GUI"; Global Discovery,
  Relaying and NAT traversal off, Local Discovery on (fallback: section 8 E1 by hand)`, verify
  unchanged, placed after `netbird-up`.
- [ ] **Step 5: Run `./tests/provision.test.sh` and `./tests/provisioning.test.sh`; expect all to
  pass.**
- [ ] **Step 6: Commit** `Generate Syncthing's config with its GUI login before its first start`.

### Task 5: Vorta imports its own export (step 15b)

**Depends on:** Task 2 (`PV_VORTA_EXPORT`, `NEED_VORTA`, `vorta_state`, `APPS`, `VORTA_INIT`).

**Files:**
- Modify: `.scripts/provision.sh` (15b between 15 and 16), `.scripts/machine-checklist.tsv`
- Test: `tests/provision.test.sh` (section `X`; section `T`)

**Interfaces:**
- Produces, in the suite: `$T/apps/Vorta.app/` (a directory); the `open` stub, with
  `$T/vorta-imports`, copies `~/.vorta-init.json` to `$T/vorta-init-seen` with its mode in
  `$T/vorta-init-mode`, then deletes it; the `pgrep` stub exits 0 for `-x vorta-darwin` when
  `$T/vorta-running` exists. The export fixture: `{"id":1,"name":"Default","SchemaVersion":
  {"version":23},"repo":{"url":"ssh://nobody@127.0.0.1:9/./repo"},"password":"MARK-VORTA-PW-d4e8"}`.

- [ ] **Step 1: Write the failing tests (section `X. Vorta imports its own export`)**
  - `fresh_steps; items_all; : > $T/vorta-imports; : > $T/fast-sleep`, run under `umask 022`:
    `called "open -g -a Vorta"`, `$T/vorta-init-mode` is `600`, `$T/vorta-init-seen` equals the
    fixture byte for byte, the file is gone, and `open` comes before `configure.sh --hostname`.
  - Without `vorta-imports`: `rc_is 0`, the file stays, `has "answer macOS's prompt to open Vorta"`.
  - Nothing written and `open` not called when: `settings.db` holds a profile with a repository; it
    is not a database; `vorta-running` (and `has "quit Vorta, then run provision.sh again"`);
    `~/.vorta-init.json` exists (its content unchanged); it is a dangling symlink to `$T/elsewhere`
    (and `$T/elsewhere` does not exist after); `$T/apps/Vorta.app` is missing; the export is `[]`,
    not JSON, or has an empty `password` (and no marker in `$OUT`).
  - Section T: `pgrep` and `open` read `/dev/null` (new `read-stdin-pgrep`, `read-stdin-open`).
- [ ] **Step 2: Run the suite; expect section X to FAIL.**
- [ ] **Step 3: Implement 15b:** in this order of guards: `NEED_VORTA` and the export;
  `vorta_state` still `absent` or `none`; `[ -d "$APPS/Vorta.app" ]`; `pgrep -x vorta-darwin`
  fails; neither `-e` nor `-L` on `$VORTA_INIT`; `print -r -- "$PV_VORTA_EXPORT" | jq -e 'type ==
  "object" and (.id|type) == "number" and (.name|type) == "string" and
  (.SchemaVersion.version|type) == "number" and (.repo.url|type) == "string" and (.password|type)
  == "string" and (.password|length) > 0' >/dev/null 2>&1`. Then `( umask 077; set -o noclobber;
  print -r -- "$PV_VORTA_EXPORT" > "$VORTA_INIT" )`, `/usr/bin/timeout -k 5 60 open -g -a Vorta
  </dev/null`, and up to 120 s (`sleep 5`) for the file to go. Warnings as spec §4 words them.
  `unset PV_VORTA_EXPORT` on every path.
- [ ] **Step 4: Change the row:** `vorta all script` `provision.sh hands Vorta this machine's
  profile, the export in 1Password's Document "BorgBase <machine>" (fallback: this machine's
  BorgBase repository and a schedule, set up in Vorta)`, verify the current one plus `&& [ ! -e
  "$HOME/.vorta-init.json" ] && security find-generic-password -s vorta-repo >/dev/null 2>&1`,
  placed after `syncthing-settings`.
- [ ] **Step 5: Run `./tests/provision.test.sh` and `./tests/provisioning.test.sh`; expect all to
  pass.**
- [ ] **Step 6: Commit** `Hand Vorta this machine's profile from its 1Password export`.

### Task 6: The login apps' LaunchAgent (D1)

**Depends on:** nothing in this plan (it shares the checklist with Tasks 3–5, so it runs after them).

**Files:**
- Create: `Library/LaunchAgents/be.netronix.login-apps.plist` (mode 644)
- Modify: `.scripts/machine-checklist.tsv`, `tests/subjects/provision.tsv`
- Test: `tests/provision.test.sh` (section `Y`)

**Interfaces:**
- Produces: the job `be.netronix.login-apps`: `ProgramArguments` `/bin/zsh`, `-fc`, `for a; do [ -d
  "/Applications/$a.app" ] && /usr/bin/open -g -a "$a"; done; exit 0`, `login-apps`, then one
  string per app: `Syncthing`, `Vorta`, `Alfred 5`, `1Password`, `Linger`, `Tafl`, `Micro Snitch`,
  `Proton Drive`, `Elgato Control Center`. `RunAtLoad` true, no `KeepAlive`, standard out and error
  `/dev/null`. A header comment like `be.netronix.ssh-agent.plist.tmpl`'s, naming the spec and
  ruling 3.

- [ ] **Step 1: Write the failing tests (section `Y. the login apps' LaunchAgent`)**
  - `plutil -lint` passes; `Label` is `be.netronix.login-apps`; `RunAtLoad` is true; no
    `KeepAlive`.
  - The `-c` script, taken with `plutil -extract ProgramArguments`, run with `/Applications`
    replaced by `$T/apps` and `/usr/bin/open` by the `open` stub, and `$T/apps/Syncthing.app` and
    `$T/apps/Vorta.app` present: `called "open -g -a Syncthing"`, `called "open -g -a Vorta"`,
    `not_called "open -g -a Elgato Control Center"`; it exits 0.
  - The arguments after `login-apps` are exactly the nine apps above, in order.
- [ ] **Step 2: Run the suite; expect section Y to FAIL.**
- [ ] **Step 3: Create the plist and its subject row** (`Library/LaunchAgents/be.netronix.login-apps.plist
  data -`).
- [ ] **Step 4: Change the row:** `login-items all script` `The be.netronix.login-apps LaunchAgent opens
  Syncthing, Vorta, Alfred and the menu-bar apps at each login (its list: Library/LaunchAgents/
  be.netronix.login-apps.plist)`, verify `launchctl print "gui/$(id -u)/be.netronix.login-apps"
  >/dev/null 2>&1`, placed after `vorta`.
- [ ] **Step 5: Run `./tests/provision.test.sh`, `./tests/provisioning.test.sh` (its section 4
  checks the label) and `./tests/load-launchagents.test.sh`; preview with `command chezmoi --source
  <checkout> apply --dry-run --verbose ~/Library/LaunchAgents/be.netronix.login-apps.plist`; expect
  all to pass and the preview to show only the new file.**
- [ ] **Step 6: Commit** `Open the login apps from a LaunchAgent`.

### Task 7: No secret escapes; the README

**Depends on:** Tasks 2–6.

**Files:**
- Modify: `README.md` (the provisioning list; "Testing a reinstall")
- Test: `tests/provision.test.sh` (section `Z`)

- [ ] **Step 1: Write the failing test (section `Z. no secret leaves its stdin or file`)**: one
  fresh run (`fresh_steps; items_all; : > $T/vorta-imports; : > $T/fast-sleep`) with
  `PV_NETBIRD_KEY=decoy PV_ST_PASSWORD=decoy` exported into the run's environment, and the
  `configure.sh` and `machine-check.sh` stubs logging their environment to `$CALLS`: no marker in
  `$CALLS` (every stub's arguments and environment) or `$OUT`; each marker in its one place
  (`$T/netbird-up-stdin`, `$T/syncthing-stdin`, `$T/vorta-init-seen`); `decoy` reaches no stub's
  environment. A second run on the machine the first left (status `Connected`, `config.xml`, a
  profile, and `settings.db` updated by the test as Vorta's import would): no `op read`, no `op
  document`, no `netbird up`, no `generate`, no `open -g -a Vorta`, and no new warning.
- [ ] **Step 2: Run the suite; a failure here is a leak to fix in its task's step, not in the test.**
- [ ] **Step 3: Update `README.md`:** the provisioning list gains the secrets read at the
  preflight, the NetBird join, Syncthing's config and Vorta's import; "Testing a reinstall" gains
  the test vault of spec §8 (three items under the D3 names; an ephemeral NetBird key with its own
  group; the placeholder repository) and `PROVISION_OP_VAULT=<test vault>` beside `PROVISION_REF`,
  and its last line says to run the VM only with that vault, never with Michael's own items.
- [ ] **Step 4: Run `./tests/run.sh --changed` and the linters the repository runs; expect every
  suite to pass (report passed/total).**
- [ ] **Step 5: Record the real size in the spec's `**Size:**` line** (`git diff --stat
  main...HEAD -- . ':!tests' ':!docs'`), then commit `Pin that provisioning's secrets stay on
  stdin, and document the test vault`.

### Task 8: Finish (controller)

**Depends on:** Task 7, Codex's reviews and Task 1.

- [ ] A whole-branch review by `sp-architect`, its findings handled by the Fix-now rule.
- [ ] Codex's pre-merge review of `origin/main...feat/script-provisioning-rows`, to approval.
- [ ] Set the spec's Status to `In progress (PR #<n>)`, push, and open the PR (the `merge-request`
  skill) assigned to Michael, with its Rulings (this plan's six plus the reviews'), and its merge
  state on hold "until Michael reports the VM run of spec §8 (D4)".
- [ ] After his report: fix any failure on the branch, set Status `Implemented` (PR cited), run a
  fresh full-range pre-merge review, update the merge state, and send the final report to the
  driver (PR link, full head SHA, receipts, totals, merge state, after-merge commands, `wt-rm
  feat/script-provisioning-rows`).
