# Little Snitch provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: the `plan-run` skill (it overrides
> superpowers:subagent-driven-development); about 6 lines of non-test code plus a README section,
> but it changes how a security control is restored, so it keeps its spec and plan.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (branch `feat/little-snitch-rules`)

**Goal:** A reinstalled Mac restores its Little Snitch rules from its own 1Password backup, before
the first login, by a checklist step that points at one README procedure, which also gives
Michael's side of the periodic rule review.

**Architecture:** Two manual `you` rows of the machine checklist move up and one gets a new step;
a README section holds the procedure. No script touches Little Snitch or 1Password, and the
periodic review's builder stays private (spec §5).

**Tech Stack:** the TSV checklist, `README.md`, `jq`, `./tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-25-little-snitch-provisioning-design.md`

## Global Constraints

- Start only after both: `feat/script-provisioning-rows` has merged (it edits
  `.scripts/machine-checklist.tsv`; rebase onto `origin/main` first), and Codex has reviewed the spec
  and this plan (its limit resets 2026-11-28 09:29), with any spec change signed by Michael.
- Touch `.scripts/machine-checklist.tsv`, `README.md`, the spec's rebase note (Task 1, Step 4) and,
  at the finish, the spec's and this plan's Status lines. Nothing else in the repository.
- Public repository: nothing from the private review, its builder or a backup. The only names are
  the item names `Little Snitch backup <machine>`, the folder `~/Code/.metrics/little-snitch/`, and
  what the spec already states (hercules' incoming sshd rule, hercules-agent-machine section 8 G).
- Never run `op`, `sudo` or `littlesnitch`, and never change Little Snitch. Storing a backup in
  1Password is outside this plan: only on Michael's request in the pane, under spec §5's clause.
- One temporary path throughout: `/tmp/little-snitch.lsbackup`.
- `git branch --show-current` before each commit; no agent attribution.

## Review Focus

- The checklist is tab-separated with five columns; a stray tab or a line break in the new step
  breaks the row. `provisioning` lints it.
- Order: `op-ssh-agent-off`, then `little-snitch-extension`, then `little-snitch-rules`, then
  `claude-login`. After the rebase `netbird-up` and `syncthing-settings` are `script` rows above
  every `you` row; `netbird-old-peer`, `syncthing-old-device` and `syncthing-folders` stay after the
  Little Snitch rows (Task 1, Step 3).
- README commands are pasteable as written: the CLI path is quoted (it has spaces), `$(id -u)` sits
  inside double quotes, every command uses `/tmp/little-snitch.lsbackup`, and
  `--preserve-terminal-access` appears only as "never pass it" (Task 2, Step 2).
- The README's `jq` check is exactly the spec's: `[true,[501]]` on a stub with Terminal access on,
  `[0,[501]]` on one without the key, root's uid `0` left out of both (Task 2, Step 2).
- The *Periodic review* part leaves every Little Snitch and 1Password check with Michael: he copies
  the agent's output to `/tmp` himself, runs the `jq` check on that copy, restores only if he has
  answered no alert since his backup, and compares both hashes himself (Task 2, Step 2).

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

**Interfaces:**
- Consumes: Task 1's step text, which sends the reader to "the README's Little Snitch section".

- [ ] **Step 1: Write the section.** A short intro: each machine's backup is the 1Password Document
  `Little Snitch backup <machine>` in Private; it is made with Settings › Security › "Allow access
  via Terminal" off; it is plain text, so it exists outside 1Password only in `/tmp` for the
  minutes a backup or restore takes, and during a periodic review in `~/Code/.metrics/little-snitch/`;
  no script touches Little Snitch; link the spec. Then the six numbered parts of spec §5 (Restore,
  Check, First use, Refresh, Never restore onto a machine in use, Periodic review), with these
  commands verbatim:

  ```
  op document get "Little Snitch backup <machine>" --vault Private --out-file /tmp/little-snitch.lsbackup
  jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid | select(. != 0)]]' /tmp/little-snitch.lsbackup
  sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model -l /tmp/little-snitch.lsbackup
  sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model --map-users "0 > 0, <backup uid> > $(id -u)" /tmp/little-snitch.lsbackup
  op document edit "Little Snitch backup <machine>" --vault Private /tmp/little-snitch.lsbackup
  op document create /tmp/little-snitch.lsbackup --title "Little Snitch backup <machine>" --vault Private
  rm /tmp/little-snitch.lsbackup
  cp <the review's output> /tmp/little-snitch.lsbackup
  shasum -a 256 <the backup you saved>
  op document get "Little Snitch backup <machine>" --vault Private | shasum -a 256
  ```

  The `jq` expectation: `[0,[<the output of id -u>]]`; a first value of `1` or `true` means the
  backup turns Terminal access on: neither restore nor store it. The two `restore-model` lines are
  only for a user-ID mismatch (`-l` lists the backup's users), with Terminal access turned on
  first; never pass `--preserve-terminal-access`. *First use* names both alert kinds: Homebrew
  tools (a changed identity) and mise tools whose version moved (a new path). `--vault Private` on
  `get` and `edit` is the plan's tightening of the spec's commands (§6 names Private as the trust
  boundary). *Periodic review* gives Michael's side of spec §5's four steps, in order: save a
  backup into `~/Code/.metrics/little-snitch/` and name its path to an agent; when the agent hands
  over its output and log, delete any leftover `/tmp/little-snitch.lsbackup`, copy the output there,
  run the `jq` check on the copy, restore it only if no alert was answered since the backup (else
  ask for a rebuild from a fresh backup), delete the copy; save a fresh backup into the folder and
  name its path; once the agent has stored it, run the two `shasum` lines and compare, and tell the
  agent so it deletes the review's files. It points to spec §5 for what the review aims at and
  names no rule, host or builder.
- [ ] **Step 2: Check.**
  - In `$TMPDIR`, a stub `{"globalDefaults":{"allowCommandLineAccess":true},"users":[{"uid":0},{"uid":501}]}`
    gives `[true,[501]]` under the README's `jq` line, and `{"globalDefaults":{},"users":[{"uid":0},{"uid":501}]}`
    gives `[0,[501]]`.
  - `rg -F -c "jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid | select(. != 0)]]'" README.md`:
    at least 1, so the README carries the exact check.
  - `rg -n 'preserve-terminal-access' README.md`: one line, the "never".
  - `rg -o '/tmp/[a-z.-]+' README.md | sort -u`: only `/tmp/little-snitch.lsbackup`.
  - `rg -c 'shasum -a 256' README.md`: at least 2.
  - After `git add`, `git diff --cached | rg '^\+' | rg -o '[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+' | sort -u`
    lists only file names (`little-snitch.lsbackup`, `Snitch.app` from the CLI path and the like)
    and nothing that names a server.
- [ ] **Step 3: Commit.** "Document restoring and refreshing the Little Snitch backup".

Task 3 (a review script) was dropped on 2026-11-27 with the spec change Michael signed that day:
the periodic review stays an agent-run private builder (spec §5).

## Finish

`./tests/run.sh --changed`; the final whole-branch review (`sp-architect`) and Codex's pre-merge
review; record the `--vault Private` tightening and the rebase note under Rulings in the PR; in the
final pre-merge commit, the spec's Status `Implemented` with the PR, and this plan's Status
`Implemented` with "do not run this plan again"; push; the PR through the `merge-request` skill,
ready for review and assigned to Michael; the final report to the driver (chezmoi-94).
