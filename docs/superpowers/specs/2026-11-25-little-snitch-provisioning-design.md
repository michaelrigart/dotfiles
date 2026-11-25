# Little Snitch rules on a reinstalled Mac: a per-machine backup in 1Password

**Status:** In progress (branch `feat/little-snitch-rules`)
**Date:** 2026-11-25
**Branch:** `feat/little-snitch-rules`, in the `wt` checkout
`~/.local/share/chezmoi-feat-little-snitch-rules`
**Sign-off:** Michael, 2026-11-25, in the line's own pane: "ok, I want to sign off, but are you
simply going to take a backup of the current rules? Because the current rules need optimizing." The
answer, now explicit in §8: the stored backup is made only after the review's changes. Two Claude
review rounds (sp-architect, then sp-reviewer: approve) are folded in; Codex reviews the spec after
its usage limit resets (2026-11-28 09:29), and any change it brings returns to Michael. Later the
same day, in the pane, Michael added the periodic review (§5, *Periodic review*): "lets go with A.
But I want you to review everything by the end of the week and put it in 1Password for me please".
**Source:** Michael, 2026-11-25: "Can you work on Little Snitch for me? I would like you to review
my current rules and optimize everything. At the same time, I would also want to know, once we have
a good rule set, if we could include it in our privisioning scripts." Relayed in the driver's brief
(chezmoi-94) of the same day. Approach A picked by Michael in the line's pane: "lets go with A then".
**Size:** about 310 lines of non-test code: about 6 in `.scripts/machine-checklist.tsv` (the two
Little Snitch rows move up and `little-snitch-rules` gets a new step) and about 300 for
`.scripts/little-snitch-review.py` plus its ad-hoc entry, estimated from the private builder it
generalises (about 330 lines, its machine-specific decisions moving to a private file, plus
decision validation and the invariants). A README section of about
45 lines (docs, not counted). One increment.
**Provisioning:** `little-snitch-extension`, `little-snitch-rules`

## 1. Problem

On a reinstalled Mac the checklist row `little-snitch-rules` says: enter the licence, then add the
rules of hercules-agent-machine §8 G (NetBird, Syncthing, hercules' sshd). Those are three of
several hundred rules; the rest come back one alert at a time over weeks. The review of fenrir's
rules (kept private, outside the repository, because the rule list names hosts and the backup holds
the Mac's location) is how the rule set gets good; this spec is how a good rule set reaches the next
install.

## 2. Goals, non-goals, anti-goals

- **Goals.** A reinstalled Mac gets its rule set back in one restore, leaving one alert per
  Homebrew tool whose rule checks its identity (§3). Each machine gets its own rules. The alerts of
  the tools the checklist and the README's first-use step exercise come while Michael is at the
  machine. Nothing private enters this public repository.
- **Non-goals.** The rules themselves (private: the review and its periodic rerun hand Michael a
  file he restores). Approving the
  network extension without a click (that needs an MDM profile). Keeping fenrir and hercules in sync
  between reinstalls (approach C below; revisit if hercules' alerts become the pain).
- **Anti-goals.** Any script that writes Little Snitch rules, preferences or rule groups. The
  licence, the rule list or a backup in the repository. "Allow access via Terminal" left on, or
  turned back on by a restore.

## 3. Facts this rests on

Evidence strength in brackets: *app* (read from the installed 6.5 app, from fenrir's backup or with
`codesign` on fenrir), *docs* (Objective Development's 6.x help, `lsc-backup` and
`cmd-restore-model`, read 2026-11-25), *inferred*.

- File › Create Backup… writes the whole filter configuration as JSON: rules, profiles, rule
  groups, preferences. File › Restore from Backup… "will restore all rules, profiles, and
  preferences for all users on this computer. A backup of your current configuration will be
  created automatically", behind an administrator password. [app]
- These backups "are not encrypted", and the Restore dialog lists candidates "found via
  Spotlight". [docs] fenrir's backup holds the Mac's location and every rule's hosts: private, not
  a secret. [app]
- The backup holds no licence data: fenrir's backup has no licence or registration key; the licence
  is a separate file under `/Library/Application Support/Objective Development/Little Snitch/`.
  [app] Neither docs page says whether a restore leaves the registration alone, so the restore is
  followed by a look at Settings › Registration. [docs]
- Unlicensed, Little Snitch runs in demo mode and turns its filter off every 3 hours. [docs] So the
  licence goes in before the restore, in the same sitting.
- Users are matched "by their numeric Unix User identifier, not by name". When the IDs differ "you
  need to restore from the command line, passing a user mapping"
  (`littlesnitch restore-model --map-users "<backup> > <local>"`); "Rules and settings from users
  which are not mapped are discarded." [docs] The backup lists its users with their `uid`
  (`.users[].uid`); fenrir's is 501. [app] What the UI restore does with a UID it does not find is
  not documented.
- "Restoring a backup disables command line access if it was disabled at the time the backup was
  made." [docs] The backup records the setting as `.globalDefaults.allowCommandLineAccess`, and
  fenrir's backup of 2026-11-25 has it on (1), so that backup must not be the stored one. [app]
  That a backup made with it on turns it on again is not stated, but follows from "restore all …
  preferences" [inferred], and from the installed CLI's undocumented `--preserve-terminal-access`:
  "If Terminal access is currently enabled, preserve it regardless of imported settings." [app]
  How the backup encodes the setting when off (0, false or absent) has not been seen, so the check
  below treats a missing key as off. [app]
- `restore-model` takes the JSON backup that File › Create Backup… writes: the docs give
  `export-model` as the command-line form of that backup, and their only `restore-model` example is
  an encrypted `.xpl`. [inferred]
- Rules name programs by code-signing identity, so a reinstalled Developer ID or App Store app
  matches its old rules. [docs] Homebrew's bottles are ad-hoc signed (`netbird`, `gh`, `glab`:
  `flags=adhoc,linker-signed`) [app]; an ad-hoc program's identity is a hash of its build [docs].
  The 6.0 change made Homebrew rules independent of the version in the path, not of the build. So
  after a reinstall, a Homebrew tool whose rule checks its identity raises one modification alert,
  as after a `brew upgrade` (hercules-agent-machine's Safety note). [inferred]
- Little Snitch filters incoming connections too: hercules' sshd needs an incoming rule for
  `100.64.0.0/10` (hercules-agent-machine §8 G), which fenrir's backup has no reason to hold.
  [inferred]

## 4. Approaches

| | Approach | On a reinstall | Trade-off |
|---|---|---|---|
| **A (picked)** | Each machine's backup is a 1Password document; the checklist says licence first, then File › Restore from Backup…. | A few minutes, by hand. | Almost no code. The stored backup must be refreshed after rule changes. |
| B | Mass deployment: provisioning writes `/var/root/LittleSnitchMassDeploymentConfiguration.json` (the backup plus the licence key from 1Password) before Little Snitch first launches. | Nothing but the extension click. | About 100 lines and sudo. The licence key sits on disk until used. Honoured only on the very first install; testable only by a real reinstall. Saves a few minutes on a rare event. |
| C | A shared `.lsrules` rule group (NetBird, Syncthing, forge CLIs, Claude Code) served over HTTPS from GitHub. | Subscribe once. | Keeps both Macs in sync, which is a different problem. The shared rules become public, each new rule is a PR, and push access to main becomes control of allow rules on both Macs. New allow rules arrive disabled by default. Whether Homebrew wildcard paths work in an `.lsrules` file is not documented. |

Dropped: a scripted `sudo littlesnitch restore-model`. It needs Terminal access turned on in the UI
first (as many clicks as the manual restore), and leaves a script that changes the firewall. The
command stays as Michael's manual fallback when the user IDs differ (§5). Michael picked A on
2026-11-25.

## 5. Design

**Where the backups live.** One 1Password Document item per machine, in the Private vault, named
`Little Snitch backup <machine>` (`Little Snitch backup fenrir`, `Little Snitch backup hercules`).
Each holds a File › Create Backup… file made with Settings › Security › "Allow access via Terminal"
off. Nothing in the repository reads them; the names appear only in the README and the checklist,
as instructions to Michael. An agent touches them only on Michael's request in its pane, and then
only like this: the item `Little Snitch backup <machine>` in Private, through `op document create`
or `op document edit … --vault Private`; the file is the exact path Michael names, a backup he saved
through File › Create Backup…, never a file the review script wrote nor a review input; the `jq`
check prints `[0,[<id -u>]]`; the agent reports the file's SHA-256 and, after reading the document
back (`op document get … --vault Private` into `/tmp`, deleted afterwards), the read-back's
SHA-256 and `jq` result. Michael compares them with `shasum -a 256 <his file>`.

**The checklist rows.** `little-snitch-extension` and `little-snitch-rules` keep their ids, their
machines (`all`), their `by` (`you`) and their verifies, and move up to sit right after
`op-ssh-agent-off`, before `claude-login`: the first `you` row that connects anywhere. Every later
login and first connection then meets the restored rules while Michael is at the machine, so the
Homebrew identity alerts of §3 come during the reinstall (`forge-logins` exercises `gh` and `glab`),
not later on an unattended hercules. The rows stay before `netbird-up` and the Syncthing rows. The
step of `little-snitch-rules` becomes, in substance:

> Enter the Little Snitch licence, then restore this machine's 1Password backup as the README's
> Little Snitch section says. A machine without a backup of its own: the closest machine's, plus
> the rules of hercules-agent-machine section 8 G on hercules; then save its own.

- The verify stays `-`. Reading the rule model needs root and Terminal access, and the checklist
  lint forbids `sudo` and `op` in a verify.
- The pointer to §8 G stays only for a machine without its own backup: once hercules' backup
  exists it carries those rules.

**The README section** (`### Little Snitch`, under Security) holds the procedure, the one place to
change it:

1. *Restore, on a fresh install only.* Fetch the document with
   `op document get "Little Snitch backup <machine>" --out-file /tmp/little-snitch.lsbackup`
   (mode 0600; `/tmp` is outside the home folder and cleared at restart; the command refuses an
   existing file, so delete a leftover first). Check it with
   `jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid]]'`: expect `[0,[<id -u>]]`;
   a first value of `1` or `true` means the backup turns Terminal access on, so do not restore it.
   Then File › Restore from Backup… › Browse… (⇧⌘G `/tmp`). From another machine's backup, delete
   that machine's own rules afterwards (hercules' incoming sshd rule) and, on hercules, add §8 G's.
   If the user ID differs, turn
   Terminal access on and run
   `sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model --map-users
   "0 > 0, <backup uid> > $(id -u)" /tmp/little-snitch.lsbackup` (root's mapping as in the docs'
   example; `restore-model -l <file>` lists the backup's users). That restore turns Terminal access off
   again, because the backup was made with it off. Never pass `--preserve-terminal-access`.
2. *Check.* Settings › Registration shows the licence; Settings › Security has Terminal access off;
   the rules list shows the user's rules. Delete the file in `/tmp`.
3. *First use.* Answer the changed-identity alerts for Homebrew tools as they come; on hercules,
   before leaving it, check `netbird status`, an ssh login over NetBird, one Vorta backup and one
   agent line, so the tools that later run unattended raise their alerts now.
4. *Refresh.* After a rule review, and after any rule change worth keeping, removals and
   narrowings included (a stale backup brings a removed allow rule back without an alert): with
   Terminal access off, File › Create Backup… to `/tmp`, named `little-snitch.lsbackup` in the save
   dialog, run the `jq` check, replace the document
   (`op document edit "Little Snitch backup <machine>" /tmp/little-snitch.lsbackup`), delete the
   file. A new machine creates its item the same way with `op document create`.
5. *Never restore onto a machine in use* except to roll back or to apply a periodic review (below):
   it discards every rule made since the backup (Little Snitch keeps an automatic copy of what it
   replaced).

**Periodic review** (approach A of 2026-11-25: an agent runs it, Michael restores). Every month or
two, and after a burst of alerts:

1. Michael saves a backup into `~/Code/.metrics/little-snitch/` (directory 700) and names its path.
2. An agent runs `.scripts/little-snitch-review.py <backup> <decisions> <out> <log>` and hands him
   `<out>` and the log.
3. Michael restores `<out>` only if he has answered no alert since step 1; otherwise back to step 1,
   because a restore discards every rule made since its source backup.
4. He saves a fresh backup; it goes to 1Password under the clause above; the review's input,
   output and log are then deleted.

The script reads and writes files only: no subprocess, no `littlesnitch`, `sudo` or `op`.

- *Passes, generic, in the repository.* Each skips protected, factory, rule-group, hidden and
  OS-update entries.
  - Programs gone: a rule whose process or via is a path that no longer exists, or an app bundle
    found in neither `/Applications` nor `~/Applications` (three levels deep). A signed
    command-line tool whose recorded path moved is kept.
  - Unused: last used over 180 days ago, or never used and created over 60 days ago.
  - Redundant: an allow rule covered by a permanent, enabled allow rule of the same scope (process,
    via, direction, ports, protocol, owner, user, priority) that allows any server, or a domain
    containing every host or domain the rule names. Deny and ask rules are never covered.
  - Expired temporary suggestions are removed.
  - Temporary rules the decisions keep become permanent; the rest are removed.
  - The decisions' `narrow` (it may set only the remote, `ports` and `protocol`, and replaces the
    old remote key) and `remove`.
  - `approved: false` keys are removed, `markNewRulesAsUnapproved` is set to 0 and Terminal access
    off; the filter state is left as backed up.
- *The agents' terminals.* Each terminal in `agent_terminals` (herdr core today) keeps exactly one
  permanent outgoing allow-any (a temporary one is promoted, duplicates are removed), plus one
  "via <tool> -> any" for every path-identified tool (a `path.`, script or absolute-path via, never
  an `identifier.` one) seen under a terminal in `tool_sources` and still on disk, so agent work
  never stops on an alert (Michael, 2026-11-25: "What I don't want is being asked while my AI agents
  are working"). Terminals in `keep_any` (Ghostty today) keep their own allow-any. Added rules take
  the user ID of the backup's single non-root user. The agents' network boundary is their
  sandboxes.
- *Decisions, private.* `~/Code/.metrics/little-snitch/decisions-<machine>.json` (mode 600) holds
  `agent_terminals`, `tool_sources`, `keep_any`, `keep_temporary`, `narrow` and `remove`; a matcher
  names process, via, direction and remote (a list-valued remote joined with commas). It names
  hosts, so it never enters the repository. An unknown key or a malformed matcher exits 2. A
  decision that matches nothing is logged as stale; one an agent terminal's tool rule supersedes is
  logged as superseded, not as a change.
- *Log.* The net result per rule (removed, made permanent, narrowed, added), grouped by pass, with
  before and after counts.
- *Invariants,* checked before anything is written (exit 1, nothing written): no temporary rule;
  each agent terminal has exactly one permanent allow-any and one per tool; each `keep_any` terminal
  has its allow-any; every protected, factory, rule-group, hidden and OS-update entry is in the
  output unchanged; the top-level keys equal the input's. Exit 2: usage, an unreadable input, bad
  decisions, more than one non-root user, an output path equal to the input or not writable.
  Output and log are created with mode 600. Run on its own output, the script changes nothing.
- *Test seams:* `LS_REVIEW_NOW` (an ISO time) and `LS_REVIEW_APP_ROOTS` (colon-separated) replace
  the clock and the app folders.

## 6. Security

- No script reads or writes Little Snitch. Every restore is Michael's, by hand, behind an admin
  password.
- The repository gains only an item name per machine and the steps above.
- Whoever can edit a backup document controls that machine's whole Little Snitch configuration
  after the next restore: allow rules, Terminal access, the operating mode, the DNS encryption
  servers and the rule-group subscriptions (remote rule sources). That is the Private vault's
  trust boundary, which already guards the SSH keys and forge tokens. An agent writes one only at
  Michael's request, and only his own unchanged backup (§5).
- The periodic review's output is a file Michael restores by hand; the script cannot reach the
  live rules, and an injected decision shows in the change log he is handed.
- The stored backup is made with Terminal access off and checked (`jq`) before it is stored and
  before it is restored, so a restore turns Terminal access off rather than on.
- The plain-text backup exists outside 1Password only in `/tmp`, for the minutes a backup or
  restore takes, and, during a periodic review, in `~/Code/.metrics/little-snitch/` (directory
  700, files 600) until the fresh backup is stored. Spotlight indexes that folder, so the Restore
  dialog lists its files; the deletion in step 4 keeps that list short.

## 7. Checks

- `./tests/run.sh provisioning machine-check`: the edited rows are well formed, the
  `**Provisioning:**` line names real rows, and machine-check accepts the list.
- The README's `jq` check, run on 2026-11-25: `[1,[501]]` on fenrir's current backup (Terminal
  access on), and on stubs `[0,[501]]` for the key absent, `0` or `false`, `[true,[501]]` for
  `true`. It is run again on the first backup made with Terminal access off (§8), which settles the
  encoding; if its first value is anything but `0`, the README's expectation is corrected before
  the backup is stored.
- The checklist and README changes get no new test: they are the order and wording of manual
  steps, and no suite pins either.
- `tests/little-snitch-review.test.sh`: synthetic backups (no private data), one case per pass,
  per decision kind and per exit code, the invariant check shown failing on an input that trips it,
  a rerun on the script's own output, and a check that the script starts no process. Each case is
  shown able to fail.
- Before the PR: `./tests/run.sh --changed`.

## 8. After the merge

On each machine already set up (fenrir now, hercules when Michael has access to it; until then
hercules relies on the row's fallback):

1. Apply the review's changes, including Settings › Security › "Allow access via Terminal" off.
   On fenrir, at Michael's request ("optimizing is something YOU need to do"), the line built an
   optimised copy of a fresh backup (private, outside the repository), and Michael restores it
   once: the one restore onto a machine in use that §5 allows, made from a backup taken right
   before it so no rule is lost. The stored backup is this reviewed rule set; the backup taken for
   the review (before its changes, with Terminal access on) is never stored.
2. Store the backup as the README's *Refresh* step says, creating the item with
   `op document create /tmp/little-snitch.lsbackup --title "Little Snitch backup <machine>"
   --vault Private`. For fenrir, the line does this at Michael's request by the end of the week of
   2026-11-23, after one more review of the alerts answered since the restore: outside the plan,
   possibly before the merge, under §5's clause.

## 9. Left to the builder

The exact wording of the row and the README section, within the content above; the README
section's place in the Security part; the decisions file's JSON layout and the script's internal
structure, within §5's passes and invariants.
