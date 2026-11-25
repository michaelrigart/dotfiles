# Script provisioning's NetBird, Syncthing, Vorta and login-item rows

**Status:** In progress (signed off by Michael on 2026-11-25, with D1–D4 as recommended)
**Date:** 2026-11-25
**Branch:** `feat/script-provisioning-rows`, in the `wt` checkout
`~/.local/share/chezmoi-feat-script-provisioning-rows`
**Source:** Michael, 2026-11-24, in the `feat/complete-provisioning` pane: script `netbird-up` and
hercules' `netbird-session-expiry` (setup key), `syncthing-settings` (`syncthing generate`),
`vorta` (`~/.vorta-init.json`) and `login-items` (System Events). Relayed in the driver's brief
(chezmoi-94) of 2026-11-25, with Codex's review of #46's unreviewed commits.
**Size:** about 215 lines of non-test code: `.scripts/provision.sh` about 150 (the preflight's
reads and their guards 45, NetBird 20, Syncthing 35, Vorta 40, the VM vault knob 10), login items
about 35 (D1: a LaunchAgent template and its loop), the checklist about 10, `README.md` about 20,
`AGENTS.md` 1. Comparable: #46's NetBird daemon and Codex pin steps. Not yet counted: the fixes from
Codex's review of #46 (§7). About 400 lines of test code, `tests/provision.test.sh` extended. One
increment. Real size, before §7's fixes (2026-11-25): 275 lines of non-test code (`provision.sh` 214,
the login-apps plist 49, the checklist 12; `change-facts`), 534 of test code; README 37, AGENTS.md 18.
**Provisioning:** `netbird-up`, `netbird-session-expiry`, `netbird-old-peer`, `syncthing-settings`,
`vorta`, `login-items`

## Why

After #46 a reinstalled machine's closing list still hands Michael four steps a script can do:
an SSO login for NetBird (and on hercules a dashboard toggle so its login never expires),
Syncthing's GUI user and network options, Vorta's repository, and the login items. Each is a GUI
or browser step today, and each needs a secret or a consent that provisioning did not have.

**Out of scope** (the brief): OrbStack, restoring Syncthing's identity, Little Snitch's
`restore-model`, token logins, and the agent-plugins hang (its own line,
`fix/codex-plugin-list-hang`).

## Design

### 1. Secrets: read at the preflight, never on a command line

`op` authorizes a terminal session and lapses after 10 minutes idle. The Brewfile alone runs
longer, so a read after it would open a 1Password prompt mid-run, which #46's anti-goals rule out.
The reads therefore move to the preflight:

- **Step 5c, after the machine name.** Each of the three steps has a read-only "already done"
  test, and only a step that is not done reads its item:
  - NetBird: done unless `netbird` is missing, its status cannot be read, or
    `netbird status --json` has `daemonStatus` `NeedsLogin` or `LoginFailed` (the field exists in
    0.83.2, read on fenrir).
  - Syncthing: done when `~/Library/Application Support/Syncthing/config.xml` exists.
  - Vorta: not done only when `settings.db` is absent, or `sqlite3 -readonly` succeeds and counts
    no profile with a repository. Any other result (a query error, a locked or renamed table)
    counts as done and warns, because Vorta's start-up import overwrites a profile of the same
    name: a guard that fails open would replace a configured profile.
- **What is read:** `op read "op://<vault>/NetBird setup key/credential"`,
  `op read "op://<vault>/Syncthing GUI/username"` and `…/password`, and
  `op document get "BorgBase <machine>" --vault <vault>` (D2, D3). Each value goes into an
  unexported shell variable through `$(…)`. A read that fails, or a value that is empty once
  trimmed, counts as not found: the summary before "Proceed?" names the item and says to answer
  no and add it now, because once this run has started Syncthing.app or Vorta (D1's LaunchAgent
  starts both) that step is manual; going on skips the step, the end of the run warns, and the row
  stays open. A re-run on a set-up machine reads nothing.
- **Never on a command line or in an environment.** NetBird takes the key on stdin
  (`--setup-key-file /dev/stdin`), Syncthing the password on stdin (`--gui-password=-`), and jq
  checks the Vorta export on stdin. They are written with zsh's `print`, a builtin, so no process
  carries a value in its arguments. Each variable is unset once its step has run. No log line
  prints a value; logs name items only.
- **What remains:** the values sit in the provisioning shell's memory until their step runs (an
  hour or more on a fresh machine). Only root, or a debugger with rights macOS does not grant by
  default, can read another process's memory.
- **AGENTS.md** says every secret is a template, with the forge tokens as the one exception. Its
  secrets bullet gains a clause naming these preflight reads as a second exception, so a later
  change does not turn them into templates (rejected: a template renders at every apply, and
  Vorta's file must exist only until its import). It is at its 240-line cap, so the clause
  replaces wording rather than adding a line.
- **`PROVISION_OP_VAULT`**, a test knob that defaults to `Private`, changes the vault for these
  reads only (chezmoi's templates keep `Private`). Like `PROVISION_REF`, it is refused outside a VM
  (`kern.hv_vmm_present`), and the summary shows it when it is set. It exists for §8's VM run.

### 2. NetBird joins with a setup key (step 8c, after the daemon)

- **When:** the daemon runs (step 8b), the key was read, and `netbird status --json` still says
  `NeedsLogin` or `LoginFailed`.
- **How:** `print -r -- "$key" | /usr/bin/timeout -k 5 120 netbird up --no-browser
  --setup-key-file /dev/stdin`, as Michael, without `sudo`. `--no-browser` (in 0.83.2) keeps a key
  the server rejects from turning into a browser SSO login mid-run. The CLI reads the file and
  trims it (`os.ReadFile`, `strings.TrimSpace` in `client/cmd/root.go`); `--setup-key-file` exists
  since 0.29.0. On a
  desktop the daemon makes the console user the owner of its default profile, and the owner may
  run `up` (docs.netbird.io/client/profile-ownership). `sudo` is avoided because macOS keeps
  `HOME` under it, so a root CLI would write root-owned files into Michael's home. This matches
  his SSO `netbird up` today (hercules-agent-machine §8 B2).
- **Re-runs:** any other state skips with a log line: `Connected`, `Connecting` or `Idle` means
  joined; `SessionExpired` is an SSO peer whose login expired, which only an SSO login renews. And
  `up` on a peer the management server already knows logs in as that peer and ignores the key
  (`client/internal/auth/auth.go`: it tries the existing WireGuard key first and registers only
  on PermissionDenied), so a re-run cannot add a second peer for this machine.
- **Failure** (an expired or used-up key, no network) warns with the fallback: `netbird up` with
  SSO, and on hercules the dashboard's Session Expiration off (`netbird-session-expiry` checks it).
- **The key** (Michael's, in the dashboard): reusable, with a usage limit; not ephemeral (an
  ephemeral peer is deleted after 10 minutes offline, which a laptop is often); auto-assigned
  groups that the access policy between fenrir and hercules covers; an expiry of his choice, noted
  in the item. Revoking the key leaves joined peers connected. Accepted trade-off (Michael,
  2026-11-24): anyone holding the key can join, and the peer's groups come from the key, not from
  his SSO user.
- **This supersedes hercules-agent-machine's ruling 2** ("hercules joins NetBird by SSO with
  Session Expiration off, not a setup key") for every join from now on (Michael, 2026-11-24).
  Existing peers stay as they are: fenrir and hercules joined with SSO and read `Connected`.
- **`netbird-session-expiry` gets a check and so leaves the list once true.** "Peers, added with a
  setup key, won't be affected" (docs.netbird.io/how-to/enforce-periodic-user-authentication).
  `netbird status --json` carries `sessionExpiresAt` only when the management server sends a
  deadline, and it sends none for a setup-key peer, an SSO peer with the toggle off, or an account
  with expiry off (`management/server/peer/peer.go` `SessionExpiresAt`, client 0.75.0 and later).
  The row stays a hercules `you` row, worded "only if hercules joined with SSO", verified by
  `daemonStatus` `Connected`, management connected and no `sessionExpiresAt`. So a setup-key join
  reads ✓, and an SSO fallback without the toggle reads ✗ instead of hiding behind `netbird-up`'s
  ✓ (#46 §1: a passing check never hides unfinished work).

### 3. Syncthing's config is generated before its first start (step 8d)

- **When:** `config.xml` does not exist in `~/Library/Application Support/Syncthing`, the folder
  Syncthing.app reads (hard-coded in its `XGSyncthing.m`, and Syncthing's macOS default), the app's
  binary is there, and the user and password were read.
- **How:** `print -r -- "$password" | /usr/bin/timeout -k 5 60 "$ST" generate --home "$ST_HOME"
  --gui-user "$user" --gui-password=-`, with
  `ST=/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing`: the app's own binary
  (2.1.6 on fenrir), so the config's schema is the one the app runs, and no `syncthing` formula is
  added. The timeout covers a Gatekeeper check that waits on a dialog for the quarantined binary
  (unknown until §8's VM run); it ends in a warning, never a stalled run. `PROVISION_SYNCTHING_BIN`
  replaces `ST` for the suite only, like `PROVISION_BREW_BIN`. `generate` stores a bcrypt hash and
  makes a new device identity, so `syncthing-old-device` stays (restoring the identity is out of
  scope). Measured on fenrir in a scratch `--home`: the command above exits 0 and writes a bcrypt
  `<password>` and the user.
- **The four options** are written into the file just generated, before anything has read it:
  `globalAnnounceEnabled`, `relaysEnabled` and `natEnabled` false, `localAnnounceEnabled` true (its
  default, asserted). `generate` has no flags for them, and `syncthing cli` works only against a
  running instance. Each is one `sed -i ''` replacing its `<x>true</x>` element, which `generate`
  writes once each; the row's own `xmllint` check runs next, and a mismatch warns. Measured the same
  way: the file keeps mode 600 and the row's check passes.
- **Re-runs:** an existing `config.xml` is never touched (a second `generate` would re-hash the
  password and rewrite the file).
- **Usage reporting** is left to the app's first start. Ruling: hercules-agent-machine §8 E1 said to
  decline it, but fenrir accepted it (`urAccepted` 3), so the question stays Michael's.
- **`syncthing-settings`** becomes a `script` row with its verify unchanged; its step names the
  manual fallback (§8 E1).

### 4. Vorta imports its own export (step 15b, before `configure.sh`)

- **The item** `BorgBase <machine>` is a 1Password Document holding Vorta's own export (Vorta →
  Export profile, with the password; D2). It carries the repository URL, the passphrase, the
  sources, exclusions, schedule, pruning and the `ssh_key` file name. fenrir's profile today has 7
  sources, about 40 exclusions, an hourly schedule and the append-only key.
- **When:** the export was read; §1's test still finds no profile with a repository (so a
  configured profile is never replaced); Vorta is not running (it reads the file only at its
  start); and `~/.vorta-init.json` does not exist. A running Vorta with no configured profile is a
  warning, "quit Vorta, then run provision.sh again", because D1's LaunchAgent starts Vorta at
  every login and a log line would hide that the step can never run.
- **Checked first,** with jq on stdin: `id` a number, `name` a string, `SchemaVersion.version` a
  number, `repo.url` a string, `password` a non-empty string. Anything else warns and writes
  nothing: Vorta deletes the file only after a successful import (`application.py`); a file it
  cannot import stays on disk and Vorta shows an error at every start.
- **Written** as `( umask 077; set -o noclobber; print -r -- "$export" > ~/.vorta-init.json )`:
  mode 600, never over an existing file.
- **Started:** `/usr/bin/timeout -k 5 60 open -g -a Vorta </dev/null` (Launch Services, not an
  Apple Event, so no Automation consent; the timeout covers an `open` that waits on macOS's
  first-open dialog, unknown until §8's VM run), then up to two minutes' wait for the file to go.
  Gone: ✓. Still there: a warning that names the file and what is left to do: answer macOS's prompt to open Vorta; if Vorta reports "Failed to
  import profile", delete the file and set Vorta up by hand.
- **How long the file lives.** On a machine where Vorta has run before, the seconds until the
  start imports it. On a fresh machine macOS asks before Vorta's first start (Homebrew quarantines
  casks), so the file lives until Michael answers that prompt, which stays on screen; the closing
  list names it too. Ruling: the file is kept, not deleted at the timeout. Deleting it would throw
  the import away and need a re-run. Keeping it is safe enough, because on a fresh machine no agent
  that could read it is signed in yet: the `claude-login` and `codex-login` rows come later.
- **Import behaviour** (Vorta 0.12.2, `profile_export.py`): the start-up import overwrites a
  profile of the same name (a fresh Vorta has none), reuses an existing repository with the same
  URL, and stores the passphrase in the login keychain (service `vorta-repo`). A keychain failure
  is only logged: the import still succeeds and the file is deleted, so the passphrase is then
  nowhere on the machine and every backup fails.
- **Placement:** before `configure.sh`, so a LaunchAgent that opens Vorta (D1) never starts it
  before the file exists. The wait adds at most two minutes, and only on a fresh machine.
- **Drift:** the export is a snapshot. After changing the profile in Vorta, export it to the item
  again; no check sees that drift.
- **`vorta`** becomes a `script` row. Its verify also requires that `~/.vorta-init.json` is gone
  and that the login keychain has a `vorta-repo` item (`security find-generic-password -s
  vorta-repo`, which reads attributes only, never the secret; §8's VM run confirms it never
  prompts).

### 5. Login items (D1)

**Measured on fenrir, 2026-11-25:** login items added through System Events have no read-only
check. `sfltool dumpbtm` needs admin rights ("authorization failed"), and an `osascript` read in
a verify asks for Automation consent on a machine that has not given it, while a verify must never
prompt. Apple Events also run only in Michael's attended `configure.sh`, never in provisioning's.

- **A LaunchAgent (D1):** `be.netronix.login-apps`, `RunAtLoad`, running
  `/bin/zsh -fc 'for a; do [ -d "/Applications/$a.app" ] && /usr/bin/open -g -a "$a"; done'
  login-apps <apps>` with the apps per machine in the template. The loader loads it like every
  `be.netronix.*` job: `configure.sh` at provisioning, the apply hook when it changes. No Apple
  Event, no consent, unattended. `login-items` becomes a `script` row checked by `launchctl print
  gui/$(id -u)/be.netronix.login-apps`: the job is loaded, so it runs at every login (whether
  each app then starts is not checked). Against: the apps show under System Settings → Allow in
  the Background (as the job), not under Open at Login; changing the list is a repository change;
  and each load opens the listed apps (a running app is left alone). On a fresh machine that load
  shows macOS's first-open prompt for each app.
- **Rejected:** System Events in an attended `configure.sh`, as agreed on 2026-11-24.
- **The apps:** on both machines Syncthing, Vorta, Alfred 5, 1Password, Linger, Tafl, Micro Snitch
  and Proton Drive; on fenrir also Elgato Control Center (its cask is fenrir's only). The default
  taken for D1: the Brewfile's menu-bar apps that were running on fenrir on 2026-11-25. Hulder is
  installed but was not running, so it is left out; OrbStack is out of scope.

### 6. The checklist

| Row | Today | After |
|---|---|---|
| `netbird-up` | `you`: `netbird up` and SSO | `script`: provisioning joins with the setup key; fallback in the step text; verify unchanged |
| `netbird-session-expiry` | `you`, hercules, no check | `you`, hercules, "only if hercules joined with SSO"; checked: connected and no `sessionExpiresAt` (§2) |
| `netbird-old-peer` | — | new `you` row, no check: on a reinstalled machine, delete its old peer in the dashboard, then put its new NetBird IP in the other machine's Syncthing address for it (hercules-agent-machine §8 E2) and, for hercules, in the SSH config note (§2). Found in recon: a reinstall makes a new WireGuard key, so a new peer with a new IP, whichever login it uses |
| `syncthing-settings` | `you` | `script`; verify unchanged |
| `vorta` | `you` | `script`; verify adds `[ ! -e "$HOME/.vorta-init.json" ]` and a `vorta-repo` keychain item (§4) |
| `login-items` | `you`, no check | `script`, checked by `launchctl print` (§5) |
| `hercules-autologin` | `you`, hercules, `autoLoginUser` checked | removed (§9) |

The `script` rows move into the `script` block, in run order. The spec's `**Provisioning:**` line
gains `netbird-old-peer` in the commit that adds the row (the suite rejects an id the checklist
does not have yet). `tests/provisioning.test.sh` keeps AGENTS.md's rule unchanged; this spec
satisfies it.

### 7. Codex's review of #46's last commits

After Codex's usage limit resets on 2026-11-28 at 09:29, `xreview -C <checkout> dispatch
--checkpoint pre-merge` with the partial range `5a86be4..4c57690` (Michael merged #46 without that
review on 2026-11-24). A partial range is recorded and never opens a gate. Each verified finding is
fixed on this branch in its own commit, with a test where its bug could return, and its size goes
into this spec's Real size. Those commits come after this line's implementation (Michael,
2026-11-25: build before Codex's reviews), each named as a fix to #46 or #47, so they read as their
own commits in the history and in the PR. If they pass about 150 lines of non-test code, they
move to a line of their own (Michael's call). `xreview round --reset` then separates the review
from this line's own.

The same review also covers PR #47 (`fix/codex-plugin-list-hang`, `187ad97..0643bbe`:
`.scripts/reconcile-agents.sh`, its suite and `AGENTS.md`), opened without Codex's review at
Michael's call (the driver's brief, 2026-11-25). If #47 has merged by then, this branch is rebased
onto main first and its findings are fixed here like #46's; if not, they go to the driver.

Codex is unavailable until then, so this spec's own review, the plan's and #46's and #47's all run
on 2026-11-28. Michael chose on 2026-11-25 to build before them rather than wait: a finding on the
spec or the plan is fixed in the code already written. A Codex finding that would change this spec
comes back to Michael.

### 8. Tests and verification

**Suites.** `tests/provision.test.sh`, extended with its stubs:
- Secrets: each stub logs its arguments and environment. The three fake secrets, distinct marker
  strings, appear in no logged argument or environment and nowhere in the run's own output, only
  on the stdin of the `netbird` and `syncthing` stubs and in `~/.vorta-init.json`.
- Read order: every `op read` and `op document get` comes before `scutil --set ComputerName`, as
  the suite already checks the preflight's order, so no read can drift past the Brewfile.
- The preflight reads only the items of steps not done; a missing item, or one whose value is
  empty or only whitespace, is named in the summary, warned at the end, and its step is skipped
  while the run goes on.
- NetBird: `up` only for `NeedsLogin` and `LoginFailed`, always with `--no-browser`; never for
  `Connected`, `Idle` or `SessionExpired`, nor without a running daemon; a failure warns.
- Syncthing (through `PROVISION_SYNCTHING_BIN`): `generate` only without `config.xml`; the four
  options set; a re-run leaves the file byte for byte; a failing or timed-out `generate` warns.
- Vorta: mode 600 with the run's umask at 022; nothing written when a profile has a repository,
  when the `settings.db` query fails, when Vorta runs (a warning), when the file exists or when the
  export fails its check; `open` called; both outcomes of the wait.
- The new steps' commands that take no secret (`netbird status`, `sqlite3`, `pgrep`, `open`) read
  `/dev/null`, under the suite's stdin-reading stubs.
- `PROVISION_OP_VAULT` is refused outside a VM.
- D1: the LaunchAgent renders per machine (and `provisioning.test.sh` already holds its label).

**A real run (D4), like #46's VM runs.** One run of the branch's `provision.sh` in a Tart VM on
fenrir as hercules, with `PROVISION_REF=feat/script-provisioning-rows` and
`PROVISION_OP_VAULT=<test vault>`. Michael makes the test vault with three items under the same
names: a NetBird setup key that is ephemeral and auto-assigns a group of its own (the VM's peer is
deleted 10 minutes after the VM stops), a throwaway Syncthing GUI login, and `BorgBase hercules`
as a Vorta export whose repository is a placeholder nothing answers
(`ssh://nobody@127.0.0.1:9/./repo`) with a throwaway passphrase, so no backup can reach a real
repository. Pass: `netbird-up`, `netbird-session-expiry`, `syncthing-settings`, `vorta` and
`login-items` ✓ after the run, with no verify prompting; `~/.vorta-init.json` gone; a second run
reads no item, leaves `config.xml` unchanged, keeps the
same NetBird peer and IP and adds no Vorta profile; and none of the three throwaway values is found
in NetBird's logs and config (`/var/log/netbird`, `/var/lib/netbird`), `~/Library/Logs`, Syncthing's
folder (a bcrypt hash only) or Vorta's `settings.db` and log. If the NetBird account's Default
policy (All to All) is on, the VM's peer reaches fenrir and hercules while it exists; the VM holds
Michael's own keys anyway, so that grants nothing new. It also answers what no suite can: whether the
app's quarantined `syncthing` binary runs before the app's first open, and what macOS asks before
Vorta's and the login apps' first starts. About 30 minutes
of Michael's time and two to three hours unattended. The PR opens with its merge state on hold
until he reports the run; a failure is fixed on the branch first.

### 9. `hercules-autologin` leaves the checklist

Michael decided on 2026-11-25, in the `feat/complete-provisioning` pane, that hercules needs no
automatic login (relayed by the driver, chezmoi-94, the same day). The `hercules-autologin` row goes;
no script ever set it. `hercules-power` (`autorestart`) and `filevault-off` stay: NetBird's daemon and
sshd start before anyone logs in, so a remote power-on still reaches hercules. The #46 spec keeps
its row table as it was, with a dated note pointing here.

## Decisions (Michael, 2026-11-25: "signed off, I follow your recommendations")

**D1. Login items: a LaunchAgent** (§5), because only it gives the row a check and runs
unattended. Rejected: System Events, as agreed on 2026-11-24, which keeps the row on the list with
no check. The apps are §5's default, taken from what ran on fenrir; changing them is a template
edit.

**D2. `BorgBase <machine>` holds Vorta's own export, with the password, as a Document** (§4). It
restores the whole profile as it is, keeps the backup layout out of this public repository, and
costs one export per machine. Rejected: the brief's two fields (repository URL, passphrase), with
the rest of the profile tracked per machine in the repository and built with jq.

**D3. The item names**, all in `Private`: `NetBird setup key` (API Credential, field `credential`),
`Syncthing GUI` (Login: `username`, `password`), `BorgBase fenrir` and `BorgBase hercules` (D2).
A missing item only skips its step; nothing fails at apply.

**D4. The VM run before merge** (§8), with its test vault: the steps meet a quarantined app, a real
NetBird server and Vorta's importer, which no stub proves. The PR opens on hold until Michael
reports the run.

## Amendments during the build (2026-11-25)

The text above is as signed; where it differs, these rulings of the build (the plan's "Rulings taken
in this plan", and the final review's fixes) apply.

- §3: one seam, `PROVISION_APPLICATIONS` (default `/Applications`), replaces `PROVISION_SYNCTHING_BIN`;
  it locates Syncthing's bundled binary and Vorta.app.
- §4: step 15b also requires Vorta.app to be installed; without it no start could import the file and
  the secret would stay on disk.
- §4: a `~/.vorta-init.json` (or a dangling symlink) found at the preflight means Vorta's import is
  waiting, not undone: the export is not read again and the closing list says what is left.
- §5, §8: the login apps are one plain plist on both machines, not a per-machine template; the job's
  `[ -d ]` test skips an app the machine lacks.
- §2: at step 8c, Idle and Connecting mean the daemon has not settled (poll up to 30 s, then warn),
  not that it joined; SessionExpired warns with the SSO fallback.
- §1: a read that fails says the item "could not be read", not "not found" (a locked app or a
  dismissed prompt fails the same way as a missing item).
- §1: the preflight's sub-steps are renumbered 5c to 5f, and the secret variables are declared
  `typeset +x`, so a caller's exported name never reaches a child.
- §2: `netbird-session-expiry`'s check keeps its verify. fenrir's SSO peer reports no
  `sessionExpiresAt`, which matches its dashboard setting (Michael, 2026-11-25): Session Expiration
  off for fenrir, the account's expiry on at 24 hours. Its ✗ side (an SSO peer with expiry on
  reporting the field) has not been observed.
- §8: the VM run ends with a restart left at the login screen; the VM's peer must then show as
  connected from fenrir. hercules has no automatic login (§9, Michael: "auto-login is not safe"), so
  a restarted hercules is reached only if NetBird connects before anyone logs in, which no run has
  measured for a peer joined by setup key as the console user.

## Michael's steps after merge

1. Make the items of D3 (the NetBird key in the dashboard first, with §2's settings). Only a
   reinstall needs them; until then every step skips on a set-up machine.
2. `chezmoi apply` (D1's LaunchAgent: its first load opens the listed apps that are not running).
3. On fenrir and hercules: `dotfiles-run machine-check`.

## Left to the builder

- Vorta's process name for the "not running" test.
- The README's provisioning list and its VM section (which today says never to run `netbird up`
  in the VM).
