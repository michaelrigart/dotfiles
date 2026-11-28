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
**Change, 2026-11-27** (signed off by Michael that evening in the pane, "Sign off"): Michael widened the review in the pane: "create the
rules properly and allow what is need (what not) so I don't get always prompted by Little Snitch.
But you can block rules that are specifically for tracking and such." §3 gains what the fenrir
rebuild measured. A review script in the repository, widened to match, did not converge in three
cold review rounds; Michael dropped it ("Drop the script"): the periodic review in §5 is now an
agent-run private builder, with what it aims at written down, and the alerts that remain are
accepted ("Accept both"). §5's 1Password clause gives the read-back to Michael, because the
agents' permission check refuses `op document get`; §8 records the rebuild. Later that evening the
plan review found that neither of Michael's checks before a periodic restore sees a setting other
than Terminal access; he added a settings `diff` to §5's step 3 ("Add the diff"). Its re-review
found that agents can write the backup it compares against, so step 1 now has Michael note that
backup's hash, which step 3 checks before the `diff`.
**Change, 2026-11-28** (Codex's plan review; signed off by Michael in the pane, "Sign off"): step 3 read that backup
twice, once for the hash and once for the `diff`, so it now copies it once into `/tmp` and checks
and compares the copy. Step 4's fresh backup passed through the folder agents can write before it
was stored, so Michael now stores it himself with the README's *Refresh* step, and no read-back is
needed. The `diff` compares a number beyond 2^53 by its text, since a double cannot hold it. A
restore that fails after Terminal access was turned on for it is followed by turning it off.
Codex's second round found the same gap at step 1 (his backup was hashed only once it sat in that
folder) and problems in the first round's fixes; Michael replaced the checks ("Assemble it"): his
backup stays in `/tmp`, which sandboxed agents cannot write, the agent writes only a rules array,
and he builds the file he restores from his own backup with one `jq` line, so every setting is his
by construction. The hash, the settings `diff` and its number handling are gone. Its third round
found that a rule or setting Michael changes by hand during the review is lost just as an answered
alert is, so step 3's condition names both (signed off by Michael in the pane, "Sign off").
**Source:** Michael, 2026-11-25: "Can you work on Little Snitch for me? I would like you to review
my current rules and optimize everything. At the same time, I would also want to know, once we have
a good rule set, if we could include it in our privisioning scripts." Relayed in the driver's brief
(chezmoi-94) of the same day. Approach A picked by Michael in the line's pane: "lets go with A then".
**Size:** about 6 lines of non-test code, in `.scripts/machine-checklist.tsv` (the two Little
Snitch rows move up and `little-snitch-rules` gets a new step), and a README section of about 60
lines (docs, not counted). One increment. Until 2026-11-27 it also held a review script of about
300 lines; dropped (see the change note).
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
  Homebrew tool whose rule checks its identity (§3) and per mise tool whose version moved. Each machine gets its own rules. The alerts of
  the tools the checklist and the README's first-use step exercise come while Michael is at the
  machine. Nothing private enters this public repository.
- **Non-goals.** The rules themselves (private: the review and its periodic rerun hand Michael a
  file he restores). Approving the
  network extension without a click (that needs an MDM profile). Keeping fenrir and hercules in sync
  between reinstalls (approach C below; revisit if hercules' alerts become the pain).
- **Anti-goals.** Anything that writes Little Snitch's live rules, preferences or rule groups. The
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
- Precedence: priority first, then how specific the server is, then port, protocol, a named program
  over any program, a via-construction (program via tool) over a single program, a named owner over
  a global rule, direction, and deny over allow over ask. Among domains the one with fewer labels
  ranks higher, so without priority an app's allow for `example.com` outranks a deny for
  `metrics.example.com`. [docs] A domain rule covers its subdomains; a host rule covers that name
  only. [docs]
- A rule belongs to a user (`uid`), to the system (`owner: system`, no `uid`: a program that runs
  as root) or, among Little Snitch's factory rules, to neither. fenrir's root daemons, NetBird among
  them, have only system rules. [app] A user's rule does not match a root daemon's connections.
  [inferred] A restore keeps `priority: high` and `owner: system`: the rebuilt set restored on
  2026-11-27 came back rule for rule. [app]
- A command an agent runs outside its sandbox is its own process, not a via of its terminal: on
  2026-11-27 an unsandboxed `tsh ssh` raised an alert seconds after it ran. [app]
- A re-signed app changes its code identity and keeps its executable: ChatGPT.app is now signed
  `com.openai.codex`, and the backup records the executable each identity was last seen at. [app]

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
through File › Create Backup…, never a file the review's builder wrote nor a review input; the `jq`
check prints `[0,[<id -u>]]`; the agent reports the file's SHA-256. The read-back is Michael's,
because the agents' permission check refuses `op document get`:
`op document get "Little Snitch backup <machine>" --vault Private | shasum -a 256` prints the same
hash as `shasum -a 256 <the path he named>`, both run by Michael.

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
   `jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid | select(. != 0)]]'`: expect `[0,[<id -u>]]` (root, uid `0`, is in a backup made once the filter has run, and maps to itself);
   a first value of `1` or `true` means the backup turns Terminal access on, so do not restore it.
   Then File › Restore from Backup… › Browse… (⇧⌘G `/tmp`). From another machine's backup, delete
   that machine's own rules afterwards (hercules' incoming sshd rule) and, on hercules, add §8 G's.
   If the user ID differs, turn
   Terminal access on and run
   `sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model --map-users
   "0 > 0, <backup uid> > $(id -u)" /tmp/little-snitch.lsbackup` (root's mapping as in the docs'
   example; `restore-model -l <file>` lists the backup's users). That restore turns Terminal access off
   again, because the backup was made with it off; if it fails or is abandoned, turn Terminal access
   off by hand. Never pass `--preserve-terminal-access`.
2. *Check.* Settings › Registration shows the licence; Settings › Security has Terminal access off;
   the rules list shows the user's rules. Delete the file in `/tmp`.
3. *First use.* Answer the alerts for Homebrew tools (a changed identity) and mise tools whose
   version moved (a new path) as they come; on hercules,
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
6. *Periodic review:* Michael's side of the steps below, pointing to this spec's §5 for what the
   review aims at.

**Periodic review** (approach A of 2026-11-25: an agent runs it, Michael restores). Every month or
two, and after a burst of alerts:

1. With Terminal access off, Michael saves a backup to `/tmp/little-snitch-base.lsbackup`
   (File › Create Backup…, deleting a leftover first), runs `chmod 600` on it and asks an agent for
   the review. Sandboxed agents can read `/tmp` but not write it, so the file stays his; a restart
   clears it, and the review then starts again here.
2. The agent reviews it with the machine's private builder, kept in `~/Code/.metrics/little-snitch/`
   (directory 700; it holds the machine's own decisions, so it never enters the repository), and
   writes there the reviewed rules as one JSON array, `review-rules.json`, and `review-log.md`, a
   log of every rule it adds, removes, narrows or makes permanent. The builder checks its own result
   before writing (no temporary rule left, each agent workspace with its rules, each block present,
   Little Snitch's own entries unchanged) and changes nothing when run on its own output; a review
   that needs a new kind of decision extends it. A machine without a builder starts from fenrir's
   (hercules at its first review); a lost builder is rebuilt from the aims below. At each machine's
   next review (fenrir's next, hercules' first) the agent also reports the backup's top-level key
   names (`jq -r 'keys[]'`) and whether the rule-group subscriptions, the DNS servers and the
   operating mode sit outside `.rules`, where step 3 keeps them from Michael's backup; one inside is
   reported to Michael as resting on the builder, like the rules.
3. Michael builds the file he restores himself: the README's assembly line writes his backup from
   step 1, with only `.rules` replaced by the array in `review-rules.json`, to
   `/tmp/little-snitch.lsbackup`, readable only by him (deleting a leftover first); a rules file
   that holds anything but exactly one array gives an empty result, which is not restored. Every setting therefore
   comes from his own backup, number for number. He runs the README's `jq` check on it
   (`[0,[<id -u>]]`), reads the log and goes on only if he accepts every change it lists, then
   restores the file and deletes both files in `/tmp`. He restores only if Little Snitch's
   configuration has not changed since step 1 (no alert answered, no rule or setting changed by
   hand); otherwise the review starts again from step 1, because a restore discards every change
   made since its source backup.
4. He stores a fresh backup himself with the README's *Refresh* step; the agent then deletes
   `review-rules.json` and `review-log.md`.

What the review aims at (Michael, 2026-11-27: "create the rules properly and allow what is need
(what not) so I don't get always prompted by Little Snitch. But you can block rules that are
specifically for tracking and such"):

- *Agent workspaces never alert* (Michael, 2026-11-25: "What I don't want is being asked while my
  AI agents are working"). The terminals and apps agents work in (herdr core, Ghostty and the Codex
  app today) keep one permanent allow-any, plus one "via <tool> -> any" for each ad-hoc or unsigned
  tool seen under them: a rule without a via covers only signed tools. Programs whose servers no
  list can name (Claude Code and OrbStack among them) keep an allow-any of their own. The agents'
  network boundary is their sandboxes and Claude Code's permission rules.
- *Everything else per server,* answered alerts made permanent and narrowed to what the alert
  named; a vendor's apps share that vendor's servers (the Microsoft 365 apps); servers a program
  needs for what it already does are allowed before it first reaches them (a tool's downloads, an
  app's update hosts). No interpreter's own process gets an allow-any, and a shared hosting domain,
  where anyone can host, is never spread across programs.
- *Trackers blocked:* ad, analytics and telemetry hosts get high-priority deny rules, because a
  vendor's broad allow would otherwise outrank them (§3); a block for every program is two rules,
  one for the user and one with `owner: system`, so root daemons are blocked too. A service
  Michael's own products report to (error or performance monitoring) is blocked per program, never
  for every program, so his development tools keep reaching it.
- *Housekeeping:* rules of programs gone or of an app's old code identity removed, unused and
  redundant rules removed, rules added for a root daemon owned by the system. Settings are not the
  review's: Terminal access is off in Michael's backup, and "mark new rules as unapproved" is his
  own setting. Little Snitch's own entries (protected, factory, rule-group, hidden, OS-update) pass through
  unchanged.

*The alerts that remain,* accepted by Michael on 2026-11-27: a command an agent runs outside its
sandbox is its own process (§3), so it alerts on a server its rules do not name (its rules stay per
server, because an allow-any would cover every use of the tool); and after a `brew upgrade` (an
ad-hoc tool's identity changes) or a `mise upgrade` (a new versioned path), the first connection
through that tool alerts until it is answered once at the machine.

## 6. Security

- Nothing an agent runs reads or writes Little Snitch's live configuration: Terminal access stays
  off, so its command line is closed, and every restore is Michael's, by hand, behind an admin
  password.
- The repository gains only an item name per machine and the steps above.
- Whoever can edit a backup document controls that machine's whole Little Snitch configuration
  after the next restore: allow rules, Terminal access, the operating mode, the DNS encryption
  servers and the rule-group subscriptions (remote rule sources). That is the Private vault's
  trust boundary, which already guards the SSH keys and forge tokens. An agent writes one only at
  Michael's request, and only his own unchanged backup (§5).
- The periodic review's rules are a file any agent session can write, because `~/Code` is in the
  sandbox's write scope, so they are only as trustworthy as those sessions. Michael's backup stays
  in `/tmp`, which sandboxed agents cannot write, and he builds the file he restores from it with
  his own `jq` line, so every setting outside `.rules` is his own; the `jq` check confirms Terminal
  access off, and the log lists every rule the review adds or removes for him to read. The log is
  the agent's, so the rules themselves rest on trusting the builder (approach A).
- The stored backup is made with Terminal access off and checked (`jq`) before it is stored and
  before it is restored, so a restore turns Terminal access off rather than on.
- The plain-text backup exists outside 1Password only in `/tmp`: for the minutes a backup or
  restore takes, and from step 1 to step 3 of a periodic review. The review's rules and log, which
  name every rule's hosts as the backup does, sit in `~/Code/.metrics/little-snitch/` (directory
  700, files 600) until step 4 deletes them.

## 7. Checks

- `./tests/run.sh provisioning machine-check`: the edited rows are well formed, the
  `**Provisioning:**` line names real rows, and machine-check accepts the list.
- The README's `jq` check, run on 2026-11-25: `[1,[501]]` on fenrir's current backup (Terminal
  access on), and on stubs `[0,[501]]` for the key absent, `0` or `false`, `[true,[501]]` for
  `true`. It is run again on the first backup made with Terminal access off (§8), which settles the
  encoding (run on 2026-11-27: first value `0`; that backup, made with the filter on, also lists
  root, so the check leaves uid `0` out); if its first value is anything but `0`, the README's expectation is corrected before
  the backup is stored.
- The README's assembly line, on stubs: the result equals the base except `.rules`, with each
  number's text kept (`1.000`, an integer beyond 2^53); a rules file holding an object instead of
  an array gives an empty result. Where the settings sit in a real backup is checked at the next
  review (§5, step 2).
- The checklist and README changes get no new test: they are the order and wording of manual
  steps, and no suite pins either.
- Before the PR: `./tests/run.sh --changed`.

## 8. After the merge

On each machine already set up (fenrir now, hercules when Michael has access to it; until then
hercules relies on the row's fallback):

1. Apply the review's changes, including Settings › Security › "Allow access via Terminal" off.
   On fenrir, at Michael's request ("optimizing is something YOU need to do"), the line built an
   optimised copy of a fresh backup (private, outside the repository), and Michael restores it
   once: a restore onto a machine in use, as §5 allows, made from a backup taken right
   before it so no rule is lost. The stored backup is this reviewed rule set; the backup taken for
   the review (before its changes, with Terminal access on) is never stored.
2. Store the backup as the README's *Refresh* step says, creating the item with
   `op document create /tmp/little-snitch.lsbackup --title "Little Snitch backup <machine>"
   --vault Private`. For fenrir, the line does this at Michael's request by the end of the week of
   2026-11-23, after one more review of the alerts answered since the restore: outside the plan,
   possibly before the merge, under §5's clause.

Done for fenrir on 2026-11-27. At Michael's request that day the review was widened to the rules
his apps need and to blocking trackers (§5, *What the review aims at*); the rebuilt set,
built from a backup taken right before, was restored, and the backup made after the restore is
stored as `Little Snitch backup fenrir`. Michael compared its read-back hash with his own `shasum`
of the local file the same evening, and they matched (the agent's `op document get` had been
refused by its permission check). The plain-text backups and built files left in
`~/Code/.metrics/little-snitch/` were deleted that evening at Michael's go-ahead (§5, step 4); the
builder and the review notes stay.

## 9. Left to the builder

The exact wording of the row and the README section, within the content above; the README
section's place in the Security part.
