# Complete provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: the `plan-run` skill (it overrides
> superpowers:subagent-driven-development). Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented (the pull request of branch `feat/complete-provisioning`). Completed 2026-11-22: do not run this plan again.

**Goal:** A wiped fenrir or hercules that runs `.scripts/provision.sh` ends with every scriptable
step done and one ordered, checked list of what is left; the same list checks a live machine; a
suite keeps new setup from bypassing provisioning.

**Architecture:** `.scripts/machine-checklist.tsv` lists what a finished machine has, each row with
a read-only verify command; `.scripts/machine-check.sh` runs them. `provision.sh` gains the missing
scripted steps and ends with `machine-check.sh --todo`. LaunchAgents load through one loader,
`.scripts/load-launchagents.sh`, called by `configure.sh` and by a `run_onchange_after_` script at
`chezmoi apply` (D1). `tests/provisioning.test.sh` enforces the rule.

**Tech Stack:** zsh (`provision.sh`, `configure.sh`, `machine-check.sh`), bash 3.2
(`load-launchagents.sh`, `reconcile-agents.sh`, suites), chezmoi templates, launchd.

**Spec:** `docs/superpowers/specs/2026-11-22-complete-provisioning-design.md` (signed 2026-11-22:
D1 yes, D2 both, D3 fallback until Michael names the 1Password items).

## Global Constraints

- Read `tests/AGENTS.md` before editing anything under `tests/`. Execute suites
  (`./tests/x.test.sh`), never `bash tests/x.test.sh`. Run only the suites your task names, never
  `./tests/run.sh` without a filter. `reconcile-agents` must run outside the sandbox.
- Never run `provision.sh`, `configure.sh`, `install-claude-managed-settings.sh`,
  `launchctl bootstrap|bootout|kickstart`, `brew bundle install` or `chezmoi apply` for real. Suites
  stub them. Read-only probes (`launchctl print`, `herdr plugin list`, `machine-check.sh`) may run
  outside the sandbox when a task says so.
- Public repository: nothing private (no hostnames beyond `machines.toml`, no account names, no
  vault content). No agent attribution anywhere. Implementers do not commit; the controller does.
- New scripts and suites are mode 755 (`git add --chmod=+x`). The checklist is 644.
- No `rm` through a variable; name literal paths. Use `git -C <checkout>`, never `cd … &&`.
- A suite exits 2 when its subject is missing (a `guard` row in `tests/subjects/<suite>.tsv`).
  Every new or newly loaded file gets its subject row in the same commit (`file<TAB>lang<TAB>role`,
  lang `bash|zsh|sh|py|prose|data|deployed`, role `-|own|guard|own,guard`, rows sorted
  `LC_ALL=C`).
- `AGENTS.md` stays at or under 240 lines (238 today).
- Never weaken an existing assertion; extend a case before adding one.

## Review Focus

- A verify command that is not read-only, prompts (sudo, Touch ID, a TCC dialog) or hangs: the
  lint (Task 2) and the 30 s timeout (Task 1) must catch it.
- A partial check: a row whose verify passes while an action its step names is undone (spec §1's
  rule). Read every row against its step.
- Re-running on a set-up machine: no codex-app-server reload, no reload of an unchanged plist, no
  Codex pin when a daemon package exists, no NetBird reinstall, no duplicate plugin link.
- The unattended run: no Apple Event and no prompt after the preflight when `configure.sh` has
  `--hostname`.
- `PROVISION_REF` outside a VM, and a branch ref reaching anything but the clone.

---

### Task 1: `machine-check.sh` and its suite

**Depends on:** nothing

**Files:**
- Create: `.scripts/machine-check.sh` (zsh, `#!/bin/zsh`)
- Create: `tests/machine-check.test.sh`, `tests/subjects/machine-check.tsv`
  (`.scripts/machine-check.sh	zsh	own,guard`)

**Interfaces:**
- Produces: `machine-check.sh [--machine <name>] [--todo]`. Reads
  `$DOTFILES/.scripts/machine-checklist.tsv` and `$DOTFILES/.chezmoidata/machines.toml`, where
  `DOTFILES=${0:A:h:h}`. Exit 0 all checks pass, 1 one fails, 2 usage, unknown machine or malformed
  list. `MACHINE_CHECK_TIMEOUT` (seconds, default 30) is the only environment knob.

- [x] **Step 1: Write the suite first.** It copies the script into `$T/src/.scripts/`, writes a
  fixture `$T/src/.chezmoidata/machines.toml` (`known_hostnames = ["alpha", "beta"]`,
  `research_host = "alpha"`) and a fixture checklist, and stubs `scutil` on `PATH`. Cases:
  - marks: a `true` row prints `✓ <id>`, a `false` row `✗ <id>: <step>`, a `-` row `· <id>: <step>`;
    then a summary line `<d> done, <t> to do, <n> without a check`; exit 1 with a `✗`, 0 without.
  - scoping on `--machine alpha`: rows for `all`, `alpha` and `research_host` run, `beta` rows do
    not appear; on `beta` the `research_host` row does not appear.
  - `--todo`: header `Still to do on alpha:`, then only `✗` and `·` rows as `  <k>. <step> [<id>]`
    (`·` rows end ` (no check)`), numbered in file order; with nothing open it prints
    `Nothing left to do on alpha.`
  - environment: the verify sees `MACHINE=alpha`, `DOTFILES` (the copied tree), `KNOWN_HOSTNAMES`
    (`alpha beta`), `HOME`, the strict XDG variables and a fixed `PATH`
    (`$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`),
    and not a variable the caller exported (`LEAKME`); stdin is `/dev/null` (`read x` fails fast).
  - timeout: with `MACHINE_CHECK_TIMEOUT=2`, a `sleep 10` row is `✗` within 5 s.
  - default machine from the `scutil --get ComputerName` stub; an unknown name exits 2 naming the
    known ones.
  - malformed list, each exit 2 with `machine-check: <file>:<line>: <problem>`: four fields, six
    fields, `by` not `script|you`, `machines` not `all|research_host|<known>`, a duplicate id, an id
    outside `[a-z0-9-]+`, an empty verify, `-` on a `script` row.
  - the guard: a missing `machine-check.sh` exits 2.
- [x] **Step 2: Run it** (`./tests/machine-check.test.sh`): fails, no script.
- [x] **Step 3: Implement.** Parse and validate the whole list before running anything. Run each
  verify as `env -i <the environment above> /usr/bin/timeout "$t" /bin/zsh -f -c "$verify"
  </dev/null >/dev/null 2>&1`. Parse `machines.toml` with the same `sed` as `provision.sh:167`, plus
  `research_host`.
- [x] **Step 4: Run it**: passes.

### Task 2: The checklist and its lint

**Depends on:** Task 1 (its format and `machine-check.sh` to measure the rows), Task 3 (the
`agent-plugins` row runs `reconcile-agents.sh --check`; before Task 3 that flag is ignored and the
script installs, so Step 3's live run must not happen earlier)

**Files:**
- Create: `.scripts/machine-checklist.tsv`
- Create: `tests/provisioning.test.sh` (section 1 only), `tests/subjects/provisioning.tsv`
  (`.chezmoidata/machines.toml	data	-`, `.scripts/machine-checklist.tsv	data	own,guard`)

**Interfaces:**
- Produces: the row ids of spec §1, final list below; Task 8's spec check reads them.

- [x] **Step 1: Write section 1 of `tests/provisioning.test.sh`** against the real checklist: five
  fields per row; unique ids `[a-z0-9-]+`; `machines` in `all`, `research_host` or
  `known_hostnames`; `by` in `script|you`; `-` only on `you` rows; `zsh -n -c "$verify"` parses;
  no verify contains `sudo`, `op read`, `op inject`, `op run`, `rm `, `kickstart`, `bootstrap`,
  `bootout`, `defaults write`, ` > ` or `>>` (a redirect to a file; `>/dev/null` and `2>&1` are
  allowed). A negative fixture per rule (a throwaway list) proves each check can fail. Every
  `machine-check.sh` validation the lint repeats must agree with Task 1's.
- [x] **Step 2: Write the checklist** with spec §1's rows, in its order, with these changes from the
  spec table (D3 fallback): `borg-key` becomes `borg-key-fenrir` (fenrir, `you`: put
  `borg-fenrir`, `borg-append-only-fenrir` and `huginn` in `~/.ssh` from where they are kept;
  verify all three files exist) and `borg-key-hercules` (hercules, `script`: chezmoi renders
  `borg-hercules`; verify the file exists). Verify commands implement exactly the conditions in the
  spec's table; the measured facts they rest on (2026-11-22, fenrir):
  - `claude auth status --json` has `.loggedIn`; `codex login status`; `hc machine ls --json` has
    `.machines[].name`; `netbird status` prints `Management: Connected`.
  - Syncthing: `~/Library/Application Support/Syncthing/config.xml`, read with
    `xmllint --xpath 'string(…)'`; `//gui/user`, `//options/globalAnnounceEnabled|relaysEnabled|
    natEnabled|localAnnounceEnabled`, `//folder[@id="…"]/@path|@type`, `…/versioning/@type`,
    `…/device`. The peer folders use every name in `KNOWN_HOSTNAMES` but `MACHINE`.
  - Alfred: `prefs.json`'s `localhash`; `defaults read …/preferences/local/<hash>/features/clipboard/prefs
    autoExpandSnippets`; `sqlite3 -readonly …/Databases/snippets.alfdb` table `snippets`, column
    `collection`, value `Relay`; `powerpack.*.dat` in Alfred's folder.
  - Vorta: `sqlite3 -readonly ~/Library/Application\ Support/Vorta/settings.db`, table
    `backupprofilemodel`, columns `repo_id`, `schedule_mode` (`interval` today; `off` is unset).
  - sshd: `launchctl print-disabled system` lines `"com.openssh.sshd" => enabled|disabled` and
    `"com.apple.screensharing" => …`; `/usr/sbin/sshd -G` runs unprivileged and prints keywords in
    mixed case (`PasswordAuthentication yes`), so match case-insensitively.
  - Codex: `codex-daemon real-bin`; `"$real" app-server daemon version` prints one JSON line with
    `status`, `cliVersion`, `appServerVersion`; `current` is a symlink into `releases/local-<sha>-…`.
  - hercules' host key: `ssh-keygen -F hercules -f "$HOME/.ssh/known_hosts"` (offline).
  - `brew bundle check --no-upgrade --file "$HOME/.config/homebrew/Brewfile"` with
    `HOMEBREW_NO_AUTO_UPDATE=1`; `mise ls --missing` run in `$HOME`.
- [x] **Step 3: Measure on fenrir**, outside the sandbox: `./.scripts/machine-check.sh --machine
  fenrir`. Expected `✗` on fenrir today, from the spec: `codex-daemon-pin` (CLI 0.170.0, daemon
  0.169.0) and `sshd-key-only`. Any other `✗` on a fenrir row is either a wrong verify (fix it) or
  drift (list it in the report with the evidence). Hercules rows are measured by Michael (Task 9).
- [x] **Step 4: Run** `./tests/provisioning.test.sh` and `./tests/machine-check.test.sh`: pass.

### Task 3: `reconcile-agents.sh --check`

**Depends on:** nothing (Task 2's `agent-plugins` row calls it; the flag is fixed here)

**Files:**
- Modify: `.scripts/reconcile-agents.sh`, `tests/reconcile-agents.test.sh`

**Interfaces:**
- Produces: `reconcile-agents.sh --check`: same queries, no state change, prints
  `missing: <what>` or `differs: <what>` per item, exit 1 when any, 0 when none; an unknown option
  exits 2.

- [x] **Step 1: Extend the suite** (its stubs already log every `add`/`install`/`mcp` call to
  `$CALLS`): `--check` with a missing Claude marketplace, plugin, MCP server, an MCP entry that
  differs, a missing Codex marketplace and plugin: each reported, exit 1, `$CALLS` empty. `--check`
  with everything present: exit 0, no output lines starting `missing:`. A failed query still exits 1
  under `--check`.
- [x] **Step 2: Run** it outside the sandbox: the new cases fail.
- [x] **Step 3: Implement** one `mutate <description> <command...>` through which every
  state-changing call goes (`claude plugin marketplace add`, `claude plugin install`,
  `claude mcp add-json`, `claude mcp remove`, `codex plugin marketplace add`, `codex plugin add`);
  under `--check` it prints `missing:`/`differs:`, sets `status=1` and does not run the command.
- [x] **Step 4: Run** it outside the sandbox: passes.

### Task 4: The LaunchAgent loader and `configure.sh`

**Depends on:** nothing (Task 5 calls the loader; Task 6 tests `configure.sh` through
`provision.test.sh`)

**Files:**
- Create: `.scripts/load-launchagents.sh` (bash 3.2, `#!/bin/bash`)
- Create: `tests/load-launchagents.test.sh`, `tests/subjects/load-launchagents.tsv`
- Modify: `.scripts/configure.sh` (LaunchAgents block 382-399, Alfred 337-380, wallpaper 314-335,
  power 216-226, closing list 416-421)
- Modify: `tests/provision.test.sh` (sections H to L; a file-backed `launchctl` stub),
  `tests/subjects/provision.tsv` (`.scripts/load-launchagents.sh	bash	-`)

**Interfaces:**
- Produces: `load-launchagents.sh` (no arguments). For each `$HOME/Library/LaunchAgents/be.netronix.*.plist`,
  records under `${XDG_STATE_HOME:-$HOME/.local/state}/launchagents/<label>.plist`:
  - not loaded (`launchctl print gui/<uid>/<label>` fails): bootstrap; on success copy the plist to
    the record; prints `  loaded <label>`.
  - loaded, record identical (`cmp -s`): nothing; `  unchanged <label>`.
  - loaded, record missing or different: bootout, bootstrap, record; `  reloaded <label>`.
  - `be.netronix.codex-app-server` loaded: never bootout, no record;
    `  unchanged be.netronix.codex-app-server (never reloaded here: a reload disconnects every Codex session)`.
  - bootstrap failure: `  could not load <label> — run: launchctl bootstrap gui/<uid> <plist>`, no
    record, exit 1 at the end. No plists: exit 0.

- [x] **Step 1: Write `tests/load-launchagents.test.sh`** with a temporary `HOME` and a `launchctl`
  stub backed by a file of loaded labels (`print` exits 0 iff listed, `bootstrap` adds unless
  `FAIL_BOOTSTRAP` names the label, `bootout` removes, every call logged). One case per bullet
  above, plus: a second run right after a first changes nothing (no `bootout` logged); editing one
  plist reloads only that one.
- [x] **Step 2: Run it**: fails.
- [x] **Step 3: Implement the loader.**
- [x] **Step 4: `configure.sh`:**
  - The LaunchAgents block calls `"${0:A:h}/load-launchagents.sh"`, `|| log_warn` naming what to
    rerun, and moves to right after the managed policy, before the Alfred and wallpaper blocks.
  - `--hostname` sets an unattended mode. In it the wallpaper is skipped with
    `log_info "Skipping the wallpaper: it needs Automation consent; run .scripts/configure.sh yourself to set it"`,
    and when Alfred is running its block is skipped with a matching line (the toggle needs Alfred
    quit, by an Apple Event). Without `--hostname` the wallpaper `osascript` gets `|| log_warn`.
  - hercules (every machine but fenrir, as today): `sudo pmset -a autorestart 1 sleep 0 womp 1`.
  - The "Manual tasks still required" list becomes one line pointing at
    `.scripts/machine-check.sh`.
- [x] **Step 5: Extend `tests/provision.test.sh`'s `configure.sh` sections:** replace the
  `launchctl` stub with the file-backed one (Task 6 reuses it); section L asserts the loader runs
  through it (`loaded be.netronix.probe`, then `unchanged` on a second `cfg`); a new case: with
  `--hostname` no `osascript` call is logged even with Alfred "running" (stub `pgrep` to succeed);
  an attended run (no `--hostname`, stdin `fenrir\ny\n` for the name prompt) whose `osascript` stub
  exits 1 for the wallpaper still prints `macOS configuration complete` and a wallpaper warning;
  section J: hercules logs `pmset -a autorestart 1 sleep 0 womp 1`, fenrir no `pmset`. The
  existing "survives an empty glob" case stays.
- [x] **Step 6: Run** `./tests/load-launchagents.test.sh` and `./tests/provision.test.sh`: pass.

### Task 5: Reload changed LaunchAgents at `chezmoi apply` (D1)

**Depends on:** Task 4 (`load-launchagents.sh`)

**Files:**
- Create: `run_onchange_after_load-launchagents.sh.tmpl` (source root)
- Modify: `tests/load-launchagents.test.sh`, `tests/subjects/load-launchagents.tsv`
  (`run_onchange_after_load-launchagents.sh.tmpl	sh	own,guard`, and each
  `Library/LaunchAgents/*.plist.tmpl	data	-`)

**Interfaces:**
- Consumes: `.scripts/load-launchagents.sh`.
- Produces: a rendered `/bin/sh` script holding one comment line per
  `Library/LaunchAgents/*.plist.tmpl` with the sha256 of that template rendered with the current
  data, so a change to any plist changes the script and chezmoi runs it once. Body: exit 0 when
  `DOTFILES_PROVISIONING` is `1`; otherwise exec `{{ .chezmoi.sourceDir }}/.scripts/load-launchagents.sh`.

- [x] **Step 1: Extend the suite.** Render with `chezmoi execute-template --source <copy>
  --config <toml with [data] is_arm = true, name, email> --file <copy>/run_onchange_after_load-launchagents.sh.tmpl`
  on a temporary copy of the source tree (only `.scripts/`, `Library/LaunchAgents/`, the template):
  one hash line per plist template; editing one plist template changes the output; with
  `DOTFILES_PROVISIONING=1` the rendered script exits 0 and a stub loader in the copy is not called;
  without it the stub is called. Changing only a data value a plist uses (`is_arm` true to false,
  which moves the codex-app-server plist's Homebrew paths) with no template edited also changes
  the output, so a hash of the raw template files fails the suite.
- [x] **Step 2: Run it**: fails.
- [x] **Step 3: Write the template.** Hash each template's rendered output (`includeTemplate` or
  `include` plus `tmpl` as chezmoi allows; the test decides), not the raw file, so a data change
  that alters a plist also reloads it.
- [x] **Step 4: Run it**; then, sandboxed, render the real template with `command chezmoi --source
  <checkout> execute-template < <checkout>/run_onchange_after_load-launchagents.sh.tmpl` and record
  the output (five hash lines on fenrir's data, the loader path under the checkout).

### Task 6: `provision.sh`

**Depends on:** Task 1 (`machine-check.sh --todo`), Task 4 (the `launchctl` stub in
`provision.test.sh`)

**Files:**
- Modify: `.scripts/provision.sh`, `tests/provision.test.sh`

**Interfaces:**
- Consumes: `machine-check.sh --todo --machine <name>`; `codex-daemon real-bin`.

- [x] **Step 1: Extend `tests/provision.test.sh`** (new stubs: `netbird`, `nvim`, `herdr`, `sysctl`;
  `$T/home/.local/bin/codex-daemon` printing a stub codex path; a stub `codex` logging its args and
  environment; `machine-check.sh` stubbed by path in `$T/src/.scripts`):
  - NetBird: `sudo netbird service install` and `sudo netbird service start` when
    `launchctl print system/netbird` fails; neither when it succeeds.
  - Plugins: `nvim --headless "+Lazy! sync" +qa`; `herdr plugin link <dir>` for each
    `$XDG_CONFIG_HOME/herdr/plugin-*` folder with a `herdr-plugin.toml` and for
    `$XDG_DATA_HOME/nvim/lazy/smart-splits.nvim` when it has one; not for a folder whose
    `[local:<dir>]` already appears in `herdr plugin list`; not for a folder without a manifest.
  - Codex pin: with no `~/.codex/packages/app-server-daemon/current` before step 16, the stub codex
    gets `app-server daemon update --from-cli --yes`, after `configure.sh`, with an environment
    that has `HOME`, `PATH` and the XDG variables and no `HERDR_PANE_ID` even when the caller set
    one; with `current` present (a `local-` link, and separately a `releases/0.1.0` link) no pin.
  - `chezmoi apply --force` runs with `DOTFILES_PROVISIONING=1` (the `chezmoi` stub logs it).
  - The end calls `machine-check.sh --todo --machine hercules`, and the old "Next steps" Borg,
    Alfred and Herdr lines are gone.
  - `PROVISION_REF=feat/x` with the `sysctl` stub printing 1: `git clone --branch feat/x`, and the
    summary shows `feat/x`; printing 0: exit 1 before `sudo -v` runs, nothing cloned. Unset: clone
    `--branch main`, no branch line in the summary.
- [x] **Step 2: Run it**: the new cases fail.
- [x] **Step 3: Implement** in `provision.sh`: the `PROVISION_REF` check before step 0; `--branch` on
  the clone (step 4) and the summary line; `DOTFILES_PROVISIONING=1` on step 6's apply; NetBird
  after step 8 (`|| warn` with the two commands); plugins after step 12 (`|| warn` each); before
  step 16 record whether `current` exists (`-e` or `-L`), after it pin when it did not, with
  `env -i` and the LaunchAgent's `PATH` (`Library/LaunchAgents/be.netronix.codex-app-server.plist.tmpl`)
  and XDG values, `|| warn` naming the manual command; the end prints `machine-check.sh --todo
  --machine "$MACHINE_NAME" || true` after the existing warnings, keeping "restart your terminal"
  and "logout/restart" lines.
- [x] **Step 4: Run** `./tests/provision.test.sh`: passes.

### Task 7: Tart on fenrir and the README

**Depends on:** nothing

**Files:**
- Modify: `dot_config/homebrew/Brewfile.tmpl` (the fenrir-only block), `tests/provision.test.sh`
  (section F), `README.md`

- [x] **Step 1: Confirm the tap** read-only: `gh api repos/openai/homebrew-tools/contents/Formula`
  lists `tart.rb` (or the name it has); if it does not, stop and report.
- [x] **Step 2: Section F** asserts the fenrir render has `tap "openai/tools", trusted: true` and
  `brew "openai/tools/tart"`, and the hercules render has neither. Run: fails.
- [x] **Step 3: Add both lines** inside `{{ if eq $live "fenrir" -}}`, with a comment: the reinstall
  test VM (spec 2026-11-22-complete-provisioning, D2). Run section F: passes.
- [x] **Step 4: README:** Quick Start's "This will" list gains the NetBird daemon, the Herdr plugins,
  the Codex pin and "prints what is left to do, from `.scripts/machine-check.sh`"; "Re-running
  Scripts" gains `machine-check.sh`; the manual new-machine steps gain the same three commands
  (`sudo netbird service install && sudo netbird service start`, the plugin links, the pin) and end
  with `machine-check.sh`. A new short section "Testing a reinstall" holds D2's VM run: install, the
  image, `tart clone`/`set --disk-size 80`/`run`, running the branch's `provision.sh` with
  `PROVISION_REF`, deleting the VM and its 1Password device.

### Task 8: The rule and the coverage checks

**Depends on:** Tasks 2, 4, 5, 6 (the ids, the loader, the `run_` script and `provision.sh` it
checks)

**Files:**
- Modify: `tests/provisioning.test.sh` (sections 2 to 5), `tests/subjects/provisioning.tsv`
  (`.scripts/provision.sh	zsh	-`, `.scripts/configure.sh	zsh	-`)
- Modify: `AGENTS.md`

- [x] **Step 1: Sections 2 to 5** against the real repository, each with a negative fixture:
  - 2: every `docs/superpowers/specs/YYYY-MM-DD-*.md` dated 2026-11-22 or later with a `#{2,4}`
    heading matching, case-insensitively, `michael.s steps|after[- ]merge|rollout|migration|
    activation|acceptance` has a `**Provisioning:**` line: `none — <reason>` (an em dash and text),
    or one or more backticked ids each in the checklist. This spec passes.
  - 3: each executable regular file directly in `.scripts/` other than `provision.sh` appears by
    name in `provision.sh` or `configure.sh`, or in the suite's ad-hoc table
    (`forge-protection.sh`, `skill-updates.sh`, `measure-interventions.py`, `preflight-ssh-agent.sh`,
    each with its reason).
  - 4: each `Library/LaunchAgents/*.plist*` has a `<key>Label</key>` whose string starts
    `be.netronix.` and equals the file name without `.plist` and `.tmpl` (the loader takes the
    label from the file name).
  - 5: each `dot_config/herdr/plugin-*/herdr-plugin.toml` sits in a folder `provision.sh`'s
    `plugin-*` glob reaches (the glob is in `provision.sh` and the folder name matches it).
- [x] **Step 2: Run** `./tests/provisioning.test.sh`: passes against the repository, each negative
  fixture fails as intended.
- [x] **Step 3: AGENTS.md**, within 240 lines:
  - the `.scripts/` bullet names `machine-check.sh`, `machine-checklist.tsv` and
    `load-launchagents.sh`, and states the rule of spec §5 (lasting setup reaches provisioning in
    the same change; a row with a verify where one exists; `**Provisioning:**` on a spec with
    after-merge steps; after-merge commands are for machines already set up), held by
    `tests/provisioning.test.sh`;
  - its "not `run_once_` scripts" sentence gains the one exception,
    `run_onchange_after_load-launchagents.sh` (a changed `be.netronix.*` plist reloads at apply;
    never codex-app-server; nothing during provisioning's first apply);
  - the `weekly-research` bullet: its LaunchAgent loads at Michael's apply on `research_host`;
    running the job for real stays his.
  Run `./tests/agent-instructions.test.sh`: passes.

### Task 9: Measurement and the full run

**Depends on:** Tasks 1 to 8

- [x] **Step 1:** Controller, outside the sandbox: `./.scripts/machine-check.sh --machine fenrir`;
  every `✗` is drift (listed for Michael with evidence) or fixed in its row now.
- [x] **Step 2:** `./tests/run.sh --changed` and, outside the sandbox, `./tests/run.sh
  reconcile-agents`; report passed/total and the `needs:` lines.
- [x] **Step 3:** Michael's steps before merge go in the PR's merge state (hold) and the report:
  hercules' `machine-check.sh` from a `git archive` copy of the branch, and the VM run (README,
  "Testing a reinstall"). A `✗` that is a wrong row comes back to this line as a fix.
