# Little Snitch provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: the `plan-run` skill (it overrides
> superpowers:subagent-driven-development); about 310 lines of non-test code, so not a small change.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (branch `feat/little-snitch-rules`)

**Goal:** A reinstalled Mac restores its Little Snitch rules from its own 1Password backup, before
the first login, by a checklist step that points at one README procedure; an agent can rerun the
rule review from a backup with one script.

**Architecture:** Two manual `you` rows of the machine checklist move up and one gets a new step;
a README section holds the procedure. No script touches Little Snitch or 1Password.

**Tech Stack:** the TSV checklist, `README.md`, Python 3 (standard library only), bash,
`./tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-25-little-snitch-provisioning-design.md`

## Global Constraints

- Start only after both: `feat/script-provisioning-rows` has merged (it edits
  `.scripts/machine-checklist.tsv`; rebase onto `origin/main` first), and Codex has reviewed the spec
  and this plan (its limit resets 2026-11-28 09:29), with any spec change signed by Michael.
- Touch `.scripts/machine-checklist.tsv`, `README.md`, `.scripts/little-snitch-review.py`,
  `tests/little-snitch-review.test.sh`, `tests/subjects/little-snitch-review.tsv`,
  `tests/provisioning.test.sh` (the ad-hoc entry only), `AGENTS.md` (the `.scripts/` list only),
  the spec's rebase note (Task 1, Step 4) and, at the finish, the spec's and this plan's Status
  lines. Nothing else in the repository. Task 3 may start before the dependency merges: it touches
  none of that line's files.
- The private decisions file `~/Code/.metrics/little-snitch/decisions-fenrir.json` (mode 600) is
  written outside the repository and never committed; no test reads it.
- Public repository: nothing from the private review or a backup. The only names are the item names
  `Little Snitch backup <machine>` and what the spec already states (hercules' incoming sshd rule,
  hercules-agent-machine section 8 G).
- Never run `op`, `sudo` or `littlesnitch`, and never change Little Snitch. The 1Password upload of
  spec §8 step 2 is outside this plan: only on Michael's request in the pane, under spec §5's
  clause. Reading the private
  backup in `~/Code/.metrics/little-snitch/` with `jq` is allowed; its output is never committed.
- One temporary path throughout: `/tmp/little-snitch.lsbackup`.
- `git branch --show-current` before each commit; no agent attribution.

## Review Focus

- Task 3: `tool_sources` and `agent_terminals` are separate: a tool seen only under Ghostty still
  gets herdr core's "via -> any" rule, and Ghostty gets none (`tool_from_other_source_terminal_added`).
- Task 3: protected, factory, rule-group, hidden and OS-update entries come out byte-identical even
  where a pass would otherwise hit them (`untouchable_entries_identical`).
- Task 3: a rerun on the script's own output changes nothing (`rerun_on_output_changes_nothing`).
- Task 3: added rules take the backup's own user ID, not 501 (`added_rules_take_backup_uid`).
- Task 3: nothing private reaches the repository (Step 6).

- The checklist is tab-separated with five columns; a stray tab or a line break in the new step
  breaks the row. `provisioning` lints it.
- Order: `op-ssh-agent-off`, then `little-snitch-extension`, then `little-snitch-rules`, then
  `claude-login`. After the rebase `netbird-up` and `syncthing-settings` are `script` rows above
  every `you` row; `netbird-old-peer`, `syncthing-old-device` and `syncthing-folders` stay after the
  Little Snitch rows (Task 1, Step 3).
- README commands are pasteable as written: the CLI path is quoted (it has spaces), `$(id -u)` sits
  inside double quotes, and every command uses `/tmp/little-snitch.lsbackup` (Task 2, Step 2).
- `--preserve-terminal-access` appears only as "never pass it" (Task 2, Step 2).
- The README's `jq` check is exactly the spec's and prints `[1,[501]]` on the 2026-11-25 backup
  (Task 2, Step 2).

---

### Task 1: Checklist rows

**Depends on:** none (after the rebase).

**Files:**
- Modify: `.scripts/machine-checklist.tsv` (rows `little-snitch-extension`, `little-snitch-rules`)

**Interfaces:**
- Produces: the row step names "the README's Little Snitch section", which Task 2 creates.

- [ ] **Step 1: Rebase.** `git -C <checkout> fetch origin`, confirm `origin/main` carries the
  `feat/script-provisioning-rows` merge, then `git -C <checkout> rebase origin/main`.
- [ ] **Step 2: Edit.** Move both rows, unchanged except as below, to directly after
  `op-ssh-agent-off`. Set the step column of `little-snitch-rules` to exactly:

  ```
  Enter the Little Snitch licence, then restore this machine's 1Password backup as the README's Little Snitch section says. A machine without a backup of its own: the closest machine's, plus the rules of hercules-agent-machine section 8 G on hercules; then save its own
  ```

  Its id, machines (`all`), by (`you`) and verify (`-`) stay; `little-snitch-extension` is only
  moved.
- [ ] **Step 3: Check the order.**
  `awk -F'\t' '!/^#/{print $1}' .scripts/machine-checklist.tsv | rg -n '^(op-ssh-agent-off|little-snitch-[a-z]+|claude-login|netbird-[a-z-]+|syncthing-[a-z-]+)$'`
  Expected (simulated on the dependency's checklist, 2026-11-25): `netbird-service`, `netbird-up`
  and `syncthing-settings` first (script rows); then `op-ssh-agent-off`,
  `little-snitch-extension`, `little-snitch-rules`, `claude-login` on consecutive line numbers;
  then `netbird-session-expiry`, `netbird-old-peer`, `syncthing-old-device`, `syncthing-folders`.
- [ ] **Step 4: Spec note.** Under spec §5's checklist paragraph, add one paragraph headed
  "Rebase note": `feat/script-provisioning-rows` made `netbird-up`, `syncthing-settings` and `vorta`
  `script` rows that run before any `you` row, so NetBird, Syncthing and Vorta first connect during
  `provision.sh`, before the filter is on; they meet the restored rules once it is, while Michael is
  still at the machine. The sentence "The rows stay before `netbird-up` and the Syncthing rows"
  now holds for `netbird-old-peer` and the Syncthing pairing rows only. No design change.
- [ ] **Step 5: Suites.** `./tests/run.sh provisioning machine-check`. Expected: both pass.
- [ ] **Step 6: Commit.** "Restore Little Snitch rules from 1Password before the first login".

### Task 2: README procedure

**Depends on:** Task 1.

**Files:**
- Modify: `README.md`: a new `### Little Snitch` at the end of `## 🔐 Security`, after
  `### macOS Hardening`.

- [ ] **Step 1: Write the section.** A short intro: each machine's backup is the 1Password Document
  `Little Snitch backup <machine>` in Private; it is made with Settings › Security › "Allow access
  via Terminal" off; it is plain text, so it exists outside 1Password only in `/tmp` for the
  minutes a backup or restore takes; no script touches Little Snitch; link the spec. Then the five
  numbered steps of spec §5 (Restore, Check, First use, Refresh, Never restore onto a machine in
  use), with these commands verbatim:

  ```
  op document get "Little Snitch backup <machine>" --vault Private --out-file /tmp/little-snitch.lsbackup
  jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid]]' /tmp/little-snitch.lsbackup
  sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model -l /tmp/little-snitch.lsbackup
  sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model --map-users "0 > 0, <backup uid> > $(id -u)" /tmp/little-snitch.lsbackup
  op document edit "Little Snitch backup <machine>" --vault Private /tmp/little-snitch.lsbackup
  op document create /tmp/little-snitch.lsbackup --title "Little Snitch backup <machine>" --vault Private
  rm /tmp/little-snitch.lsbackup
  ```

  The `jq` expectation: `[0,[<the output of id -u>]]`; a first value of `1` or `true` means the
  backup turns Terminal access on: neither restore nor store it. The two `restore-model` lines are
  only for a user-ID mismatch (`-l` lists the backup's users), with Terminal access turned on
  first; never pass `--preserve-terminal-access`. `--vault Private` on `get` and `edit` is the
  plan's tightening of the spec's commands (§6 names Private as the trust boundary). A sixth part,
  *Periodic review*, gives Michael's side of spec §5's periodic review: save a backup into
  `~/Code/.metrics/little-snitch/`, ask an agent to run the review, restore its file, save a fresh
  backup for 1Password.
- [ ] **Step 2: Check.**
  - `jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid]]' ~/Code/.metrics/little-snitch/fenrir-2026-11-25.lsbackup`
    prints `[1,[501]]`.
  - `rg -F -c "jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid]]'" README.md`:
    at least 1, so the README carries the exact check.
  - `rg -n 'preserve-terminal-access' README.md`: one line, the "never".
  - `rg -o '/tmp/[a-z.-]+' README.md | sort -u`: only `/tmp/little-snitch.lsbackup`.
- [ ] **Step 3: Commit.** "Document restoring and refreshing the Little Snitch backup".

### Task 3: Review script

**Depends on:** none (Codex's review of the spec and plan still comes first).

**Files:**
- Create: `.scripts/little-snitch-review.py` (mode 755, `#!/usr/bin/env -S python3 -I`, standard
  library only)
- Create: `tests/little-snitch-review.test.sh` (mode 755, bash; read `tests/AGENTS.md` first) and
  `tests/subjects/little-snitch-review.tsv` with the row
  `.scripts/little-snitch-review.py<TAB>py<TAB>own,guard`
- Modify: `tests/provisioning.test.sh`: `little-snitch-review.py` in `ADHOC`, reason "Little
  Snitch rule review, run by an agent at Michael's request"; `AGENTS.md`: name the script in the
  `.scripts/` list
- Private, not committed: `~/Code/.metrics/little-snitch/decisions-fenrir.json` (mode 600), from
  the lists in `~/Code/.metrics/little-snitch/optimise.py`

**Interfaces:**
- `little-snitch-review.py <backup> <decisions.json> <out> <log>`, with the passes, decisions,
  invariants, exit codes (0, 1 invariant, 2 input), modes and seams (`LS_REVIEW_NOW`,
  `LS_REVIEW_APP_ROOTS`) of spec §5 *Periodic review*.
- Decisions JSON: `{"agent_terminals": [<code ID>], "tool_sources": [<code ID>], "keep_any":
  [<code ID>], "keep_temporary": [<matcher>], "narrow": [{"match": <matcher>, "set": {...}}],
  "remove": [<matcher>]}`. A matcher is `{"process": <id>, "via": <id> | null, "direction":
  "outgoing" | "incoming" | null, "remote": [<key>, <value>] | null}`; a null field matches any
  value, except that a null `remote` never matches an allow-any. `set` keys: `remote`,
  `remote-hosts`, `remote-domains`, `remote-addresses`, `ports`, `protocol`.

- [ ] **Step 1: Write the failing suite.** Synthetic backups in a temp dir, with app and tool paths
  inside it and `LS_REVIEW_NOW` and `LS_REVIEW_APP_ROOTS` pointing there. One case each:
  - Programs gone: `gone_app_removed`, `moved_app_bundle_kept`, `moved_signed_cli_kept`,
    `missing_path_removed`, `gone_via_removed`.
  - Unused: `unused_180_removed`, `never_used_old_removed`, `never_used_recent_kept`.
  - Redundant: `redundant_under_any_removed`, `redundant_under_domain_removed`,
    `same_domain_twice_kept`, `other_via_not_redundant`, `temporary_broad_covers_nothing`,
    `disabled_any_covers_nothing`, `deny_under_any_kept`.
  - Suggestions: `expired_suggestions_removed`, `os_update_suggestions_kept`.
  - Temporaries and decisions: `keep_temporary_promoted`, `other_temporary_dropped`,
    `narrow_domain_to_host`, `narrow_wider_field_exit_2`, `remove_matcher_applied`,
    `remove_matcher_direction`, `stale_decision_logged`, `superseded_decision_logged`,
    `bad_decisions_exit_2`.
  - Terminals: `agent_terminal_any_added`, `agent_terminal_temporary_promoted`,
    `agent_terminal_duplicate_any_deduped`, `agent_tool_via_any_added`,
    `tool_from_other_source_terminal_added`, `identifier_via_gets_no_tool_rule`,
    `missing_tool_gets_no_rule`, `keep_any_terminal_kept`, `added_rules_take_backup_uid` (uid
    502), `ambiguous_user_exit_2`.
  - Settings and safety: `terminal_access_off`, `approved_keys_removed`, `mark_unapproved_off`,
    `filter_state_unchanged`, `untouchable_entries_identical` (one entry of each kind where each
    pass would hit it), `invariant_failure_writes_nothing` (a `keep_any` terminal without its
    allow-any: exit 1, no files), `bad_input_exit_2`, `out_equals_input_exit_2`,
    `output_mode_600`, `rerun_on_output_changes_nothing`, `no_live_commands` (the script imports
    neither `subprocess` nor `pty` and calls no `os.system`, `os.exec*` or `os.spawn*`, checked
    with `ast`; and a run with recording stubs for `op`, `sudo` and `littlesnitch` first on
    `PATH` records nothing).
- [ ] **Step 2: Run it.** `./tests/run.sh little-snitch-review`: the suite's guard exits 2 on the
  missing script, as `tests/AGENTS.md` requires.
- [ ] **Step 3: Implement** spec §5 *Periodic review*, in the private builder's order: terminals,
  narrowing, temporaries, removals, programs gone, unused, redundant, suggestions, approvals,
  settings, invariants.
- [ ] **Step 4: Suite passes;** then the revert check on `redundant_under_domain_removed`,
  `tool_from_other_source_terminal_added`, `untouchable_entries_identical` and
  `invariant_failure_writes_nothing`: break the code path, see the case fail, restore it.
- [ ] **Step 5: Parity, private.** Write `decisions-fenrir.json`; run the script with
  `LS_REVIEW_NOW=2026-11-25T21:46:00Z` on `~/Code/.metrics/little-snitch/fenrir-pre-restore.lsbackup`
  and compare the whole document with `fenrir-restore-2026-11-25.lsbackup`, ignoring only the added
  rules' creation and modification dates. Report any other difference instead of committing.
- [ ] **Step 6: Private-data check.** Build a pattern file in `~/Code/.metrics/little-snitch/`
  from every host, domain and address in `decisions-fenrir.json` and the backup's rules; after
  `git add`, `git diff --cached | rg -F -f <that file>` prints nothing. The pattern file is never
  committed.
- [ ] **Step 7: Suites.** `./tests/run.sh little-snitch-review provisioning`: both pass.
- [ ] **Step 8: Commit.** "Add a Little Snitch rule review script for periodic clean-ups".

## Finish

`./tests/run.sh --changed`; the final whole-branch review (`sp-architect`) and Codex's pre-merge
review; record the `--vault Private` tightening and the rebase note under Rulings in the PR; in the final pre-merge commit, the spec's Status `Implemented`
with the PR, and this plan's Status `Implemented` with "do not run this plan again"; push; the PR
through the `merge-request` skill, ready for review and assigned to Michael; the final report to
the driver (chezmoi-94).
