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

**Tech Stack:** the TSV checklist, `README.md`, `jq`, `awk`, `./tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-25-little-snitch-provisioning-design.md`

## Global Constraints

- Start only after both: `feat/script-provisioning-rows` has merged (it edits
  `.scripts/machine-checklist.tsv`; rebase onto `origin/main` first), and Codex has reviewed the spec
  and this plan, with any spec change signed by Michael. The merge and the rebase happened
  2026-11-28, before Codex's plan review.
- Touch `.scripts/machine-checklist.tsv`, `README.md`, the spec's rebase note (Task 1, Step 4) and,
  at the finish, the spec's and this plan's Status lines. Nothing else in the repository.
- Public repository: nothing from the private review, its builder or a backup. The only names are
  the item names `Little Snitch backup <machine>`, the folder `~/Code/.metrics/little-snitch/`, and
  what the spec already states (hercules' incoming sshd rule, hercules-agent-machine section 8 G).
- Never run `op`, `sudo` or `littlesnitch`, and never change Little Snitch. Storing a backup in
  1Password is outside this plan: only on Michael's request in the pane, under spec §5's clause.
- Two temporary paths, no others: `/tmp/little-snitch.lsbackup` and, during a periodic review only,
  `/tmp/little-snitch-base.lsbackup`.
- `git branch --show-current` before each commit; no agent attribution.

## Review Focus

- The checklist is tab-separated with five columns; a stray tab or a line break in the new step
  breaks the row. `provisioning` lints it.
- Order: `op-ssh-agent-off`, then `little-snitch-extension`, then `little-snitch-rules`, then
  `claude-login`. `netbird-up` and `syncthing-settings` are `script` rows above every `you` row;
  `netbird-old-peer`, `syncthing-old-device` and `syncthing-folders` stay after the Little Snitch
  rows (Task 1, Step 3).
- README commands paste as written once each placeholder is filled: a placeholder appears only as
  the right side of an assignment (`name=<…>`), holds no quote character, and is used afterwards
  as `"$name"`; the CLI path is quoted (it has spaces); `$(id -u)` sits inside double quotes;
  `--preserve-terminal-access` appears only in prose, as "never pass it" (Task 2, Steps 1 and 2).
- The README's `jq` check is exactly the spec's: `[true,[501]]` on a stub with Terminal access on,
  `[0,[501]]` on one without the key, root's uid `0` left out of both (Task 2, Step 2).
- The *Periodic review* part leaves every Little Snitch and 1Password step with Michael: he copies
  his own backup and the agent's output into `/tmp` himself, readable only by him, checks the hash
  on the copy of his backup, runs the `jq` check and the settings `diff` on the copies, reads the
  log, restores only if he has answered no alert since his backup, and stores the fresh backup
  himself with *Refresh* (Task 2, Step 1).

---

### Task 1: Checklist rows

**Depends on:** none (after the rebase).

**Files:**
- Modify: `.scripts/machine-checklist.tsv` (rows `little-snitch-extension`, `little-snitch-rules`)

**Interfaces:**
- Produces: the row step names "the README's Little Snitch section", which Task 2 creates.

- [ ] **Step 1: Rebase.** Done 2026-11-28. `git -C <checkout> fetch origin`; if `origin/main` has
  moved, `git -C <checkout> rebase origin/main`. `git -C <checkout> merge-base --is-ancestor
  00835fc7d0ef32d13e71c83338d35cccc913dcef HEAD` (the `feat/script-provisioning-rows` merge) exits 0.
- [ ] **Step 2: Edit.** Move both rows, unchanged except as below, to directly after
  `op-ssh-agent-off`. Set the step column of `little-snitch-rules` to exactly:

  ```
  Enter the Little Snitch licence, then restore this machine's 1Password backup as the README's Little Snitch section says. A machine without a backup of its own: the closest machine's, plus the rules of hercules-agent-machine section 8 G on hercules; then save its own
  ```

  Its id, machines (`all`), by (`you`) and verify (`-`) stay; `little-snitch-extension` is only
  moved.
- [ ] **Step 3: Check the order.** Write this program to `$TMPDIR/ls-order.awk` and run
  `awk -F'\t' -f "$TMPDIR/ls-order.awk" .scripts/machine-checklist.tsv`. Expected: no output, exit
  0. Before Step 2 it prints `not consecutive` and exits 1 (checked 2026-11-28 on the rebased
  checklist; a simulated edit passed).

  ```awk
  !/^#/ && NF { n++; p[$1] = n }
  END {
    split("op-ssh-agent-off little-snitch-extension little-snitch-rules claude-login netbird-up syncthing-settings netbird-old-peer syncthing-old-device syncthing-folders", ids, " ")
    for (i in ids) if (!(ids[i] in p)) { print "missing: " ids[i]; bad = 1 }
    o = p["op-ssh-agent-off"]
    if (p["little-snitch-extension"] != o + 1 || p["little-snitch-rules"] != o + 2 || p["claude-login"] != o + 3) { print "not consecutive"; bad = 1 }
    if (p["netbird-up"] > o || p["syncthing-settings"] > o) { print "script rows after"; bad = 1 }
    if (p["netbird-old-peer"] < o || p["syncthing-old-device"] < o || p["syncthing-folders"] < o) { print "pairing rows before"; bad = 1 }
    exit bad
  }
  ```
- [ ] **Step 4: Spec note.** Under spec §5's checklist paragraph, add one paragraph headed
  "Rebase note": `feat/script-provisioning-rows` made `netbird-up`, `syncthing-settings` and `vorta`
  `script` rows that run before any `you` row, so NetBird and Syncthing first connect during
  `provision.sh`, before the filter is on; they meet the restored rules once it is, while Michael is
  still at the machine. `provision.sh` starts Vorta only to import its profile; Vorta reaches its
  repository at its first backup (its schedule, or the one *First use* runs on hercules). The
  sentence "The rows stay before `netbird-up` and the Syncthing rows" now holds for
  `netbird-old-peer` and the Syncthing pairing rows only. No design change.
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
  Check, First use, Refresh, Never restore onto a machine in use, Periodic review), no subheadings.
  Every command sits in a fenced code block, one command per line, no comments or blank lines
  inside; the section's code blocks hold exactly these lines, each at least once, and nothing else:

  ```
  machine=<the machine name, as in machines.toml>
  rm -f /tmp/little-snitch.lsbackup
  op document get "Little Snitch backup $machine" --vault Private --out-file /tmp/little-snitch.lsbackup
  jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid | select(. != 0)]]' /tmp/little-snitch.lsbackup
  sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model -l /tmp/little-snitch.lsbackup
  backup_uid=<the user ID that restore-model -l lists>
  sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model --map-users "0 > 0, $backup_uid > $(id -u)" /tmp/little-snitch.lsbackup
  rm /tmp/little-snitch.lsbackup
  chmod 600 /tmp/little-snitch.lsbackup
  op document edit "Little Snitch backup $machine" --vault Private /tmp/little-snitch.lsbackup
  op document create /tmp/little-snitch.lsbackup --title "Little Snitch backup $machine" --vault Private
  base=<the backup you saved for the review>
  shasum -a 256 "$base"
  out=<the output the agent names>
  rm -f /tmp/little-snitch.lsbackup /tmp/little-snitch-base.lsbackup
  (umask 077; cp "$base" /tmp/little-snitch-base.lsbackup && cp "$out" /tmp/little-snitch.lsbackup)
  shasum -a 256 /tmp/little-snitch-base.lsbackup
  ls_settings='del(.rules, .globalDefaults.allowCommandLineAccess, .users[].defaults.markNewRulesAsUnapproved) | walk(if type == "number" and fabs < 9007199254740992 then . + 0 else . end)'
  diff <(jq -S "$ls_settings" /tmp/little-snitch-base.lsbackup) <(jq -S "$ls_settings" /tmp/little-snitch.lsbackup)
  rm /tmp/little-snitch.lsbackup /tmp/little-snitch-base.lsbackup
  ```

  `machine=` is set once at the top of the section (another machine's name when restoring its
  backup); `scutil --get LocalHostName` is not used, because a machine set up before provisioning
  set it can differ. *Restore* deletes a leftover, fetches, runs the `jq` check, then File ›
  Restore from Backup… › Browse… (⇧⌘G `/tmp`). The `jq` expectation: `[0,[<the output of id -u>]]`;
  a first value of `1` or `true` means the backup turns Terminal access on: neither restore nor
  store it. The two `restore-model` lines are only for a user-ID mismatch (`-l` lists the backup's
  users), with Terminal access turned on first; if that restore fails or is abandoned, turn
  Terminal access off by hand, and *Check* always looks; never pass `--preserve-terminal-access`.
  *Check* ends with the plain `rm`. *First use* names both alert kinds: Homebrew tools (a changed
  identity) and mise tools whose version moved (a new path). *Refresh*: File › Create Backup… to
  `/tmp`, named `little-snitch.lsbackup` in the save dialog, then `chmod 600`, the `jq` check,
  `op document edit` (or `create` for a new machine), the plain `rm`. `--vault Private` on `get`
  and `edit` is the plan's tightening of the spec's commands (§6 names Private as the trust
  boundary). *Periodic review* gives when (every month or two, and after a burst of alerts) and
  Michael's side of spec §5's four steps, in order: save a backup into
  `~/Code/.metrics/little-snitch/` (directory 700), set `base`, note `shasum -a 256 "$base"` and name
  the path to an agent; when the agent hands over its output and log, set `base` again if the
  shell is new and `out`, delete leftovers, make both private copies, check that the copy of his
  backup has the noted hash (agents can write the folder), run the `jq` check on the output's copy,
  set `ls_settings` and run the settings `diff` (no output; a changed hash or any output means no
  restore, because only the rules and the two settings the filter leaves out may change; it
  compares numbers by value where a double holds them exactly and by their text beyond 2^53),
  read the log and go on only if he accepts every change it lists, restore the output's copy only
  if no alert was answered since the backup (else ask for a rebuild from a fresh backup), delete
  both copies; then store a fresh backup with *Refresh* and tell the agent, which deletes the
  review's input, output and log. It points to spec §5 for what the review aims at and names no
  rule, host or builder.
- [ ] **Step 2: Check.**
  - The commands, as a set: write the block above, without its two-space indent, to
    `$TMPDIR/ls-commands.txt`, and this to `$TMPDIR/ls-check.sh`; run
    `bash "$TMPDIR/ls-check.sh" README.md "$TMPDIR"`. Expected: no output, exit 0. Tested
    2026-11-28 on a stub section: a command with `--preserve-terminal-access` appended, or a
    missing command, prints the line and exits 1. (Files throughout: the sandbox denies `/dev/fd`
    and `diff -`.)

    ```bash
    awk '/^### Little Snitch$/ { s = 1; next } s && /^(#|##|###) / { exit } s && /^[[:space:]]*```/ { f = !f; next } s && f && NF { sub(/^[[:space:]]+/, ""); print }' "$1" | sort -u > "$2/ls-readme.txt"
    sort -u "$2/ls-commands.txt" > "$2/ls-expected.txt"
    diff "$2/ls-expected.txt" "$2/ls-readme.txt"
    ```
  - In `$TMPDIR`, a stub `{"globalDefaults":{"allowCommandLineAccess":true},"users":[{"uid":0},{"uid":501}]}`
    gives `[true,[501]]` under the README's `jq` line, and `{"globalDefaults":{},"users":[{"uid":0},{"uid":501}]}`
    gives `[0,[501]]`.
  - The settings filter on stubs: a base
    `{"rules":[{"action":"allow"}],"globalDefaults":{"allowCommandLineAccess":1,"x":1,"big":9007199254740993},"users":[{"uid":0},{"uid":501,"defaults":{"markNewRulesAsUnapproved":1}}]}`;
    a copy with the rules, `allowCommandLineAccess` and `markNewRulesAsUnapproved` changed and `x`
    written as `1.000`; a copy of that with `x` set to `2`; and one with `big` set to
    `9007199254740992`. Write each through `jq -S "$ls_settings"` (the README's value) to a file in
    `$TMPDIR` and `diff` the base's against each: the first exits 0 with no output, the other two
    exit 1 (checked 2026-11-28; without the `fabs` guard the last one exits 0).
  - ``rg -o '/tmp/[^[:space:]`"),;]+' README.md | sed 's/\.$//' | sort -u``: only
    `/tmp/little-snitch-base.lsbackup` and `/tmp/little-snitch.lsbackup` (the class stops only at
    delimiters, so a misspelt path in the prose shows up).
  - After `git add`, read `git diff --cached` once: it names no server, rule or file from
    `~/Code/.metrics/little-snitch/` beyond the folder itself. The final review reads it again.
- [ ] **Step 3: Commit.** "Document restoring and refreshing the Little Snitch backup".

Task 3 (a review script) was dropped on 2026-11-27 with the spec change Michael signed that day:
the periodic review stays an agent-run private builder (spec §5).

## Finish

In this order:

1. `./tests/run.sh --changed`; the final whole-branch review (`sp-architect`); Codex's pre-merge
   review on `origin/main...feat/little-snitch-rules` until it approves.
2. Push; open the PR through the `merge-request` skill, ready for review and assigned to Michael,
   with the `--vault Private` tightening and the rebase note under Rulings.
3. The final pre-merge commit: the spec's Status `Implemented` with the PR, and this plan's Status
   `Implemented` with "do not run this plan again".
4. A fresh full-range Codex pre-merge round on that commit; push; update the PR's merge state for
   the new head.
5. The final report to the driver (chezmoi-94).
