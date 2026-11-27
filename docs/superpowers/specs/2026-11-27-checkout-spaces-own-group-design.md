# Check 5's group read keeps its own `ps` out of the group it reads

**Status:** Approved
**Date:** 2026-11-27
**Sign-off:** Michael, 2026-11-27, in the line's own pane: "D1. ok / D2. skip codex" (the design
as written; no Codex review at any checkpoint of this line).
**Branch:** `fix/checkout-spaces-own-group`, in the `wt` checkout
`~/.local/share/chezmoi-fix-checkout-spaces-own-group`
**Source:** Michael hit the refusal on fenrir on 2026-11-27; briefed by the driver (chezmoi-9f).
**Builds on:** `docs/superpowers/specs/2026-11-15-wt-rm-app-spaces-design.md`, "Amendment
(2026-11-15)", whose check 5 group read this corrects. That spec stays as written apart from a
dated pointer to this one.
**Review:** Codex's spec review was refused (usage limit until 2026-11-28 09:29); Michael,
2026-11-27: "skip codex". A cold Claude review (sp-architect) ran instead: no blocking finding;
its two should-fix findings (the second new assertion's revert check, Retire) and its nit
(fixture group 777) are folded in below. Cold Claude reviews stand in at the plan and pre-merge
checkpoints too.
**Size:** about 5 lines of non-test code: one line and its comment in `group_folders`
(`dot_config/herdr-app/bin/executable_checkout-spaces`). Tests: about 3 lines in the `ps` stub
and about 15 in `tests/herdr-app.test.sh`.
**Provisioning:** none — a fix to a helper `chezmoi apply` already deploys; no machine setup.

## Why

From a Herdr app terminal (t10t, in the main checkout's space):

```
λ wt-rm chore/gitlab-ssh-row
checkout-spaces: refusing — cannot tell where terminal t10t (chezmoi / runtime) is: hc get gave no folder and its foreground group could not be read
wt-rm: the Herdr app's spaces for /Users/michael/.local/share/chezmoi-chore-gitlab-ssh-row are not all closed (its Herdr workspaces are) — nothing was removed.
```

`wt-rm`'s first `check` passed; the re-check inside `close` refused. Workaround until this merges:
run `wt-rm` from a terminal outside the Herdr app.

## Cause

Check 5 asks `hc get` about every terminal of every other local space, the caller's own included.
While a command runs in it, the caller's terminal mostly answers with no folder (7 in 10, measured
2026-11-15), so its foreground group is read instead (`group_folders`). That read refuses when
any process of the group belongs to another user, from one `ps -A -o uid=,pgid=` snapshot,
because `lsof` cannot read such a process's folder.

`/bin/ps` is setuid root (`-rwsr-xr-x root`), so it runs with effective uid 0 and lists itself
as uid 0. `wt-rm` is a shell function, so the helper is its own foreground job in the caller's
terminal, and the group being read is the helper's own. Retire trips the same way by another
route: the menu runs `retire <top>` as its tab's command, and nothing under it uses job control,
so `retire`, its subshell, `~/.local/bin/wt-rm`, `tee` and the helper all share the tab's
foreground group. Either way the snapshot `ps` is a member of the group it reads, and the check
refuses itself.

Measured 2026-11-27 (unsandboxed, in a pty whose foreground group the helper shares with the
shell that started it, as under Retire; real `ps` and `lsof`, `herdr-app` and `hc` stubbed so
`hc get` answers live with no folder):

- today's helper refuses 8 times in 8 with Michael's message;
- the group as the helper sees it: the pty's `zsh`, the helper, its `group_folders` subshell
  (uid 501) and `ps` (uid 0, its parent that subshell) — the only process of another uid.

## Design

The snapshot `ps` runs in a process group of its own, so it is never a member of the group it
reads:

```zsh
procs=$(/usr/bin/perl -e 'setpgrp(0, 0) and exec @ARGV; exit 1' ps -A -o uid=,pgid= 2>/dev/null) && [[ -n $procs ]] || return 1
```

Nothing else changes: the uid test, its parsing and its refusal stay as they are, every member of
the group is still read, and the caller still gets no exception. A `setpgrp` or `exec` that fails
exits 1 and the read refuses, as an unreadable snapshot does today. The new group cannot take the
number of the group being read, which still exists. `ps` writes only to the pipe and reads no
input, so running outside the terminal's foreground group stops nothing (no SIGTTOU or SIGTTIN).

Measured the same way with this change: 10 passes in 10; with a setuid `top` (uid 0, real uid
501) started in that same group, 3 refusals in 3.

**Considered and declined.**

- Excusing the caller's own group from the uid test (the group read is the helper's own). It
  misses another user's process in the caller's own job, which the setuid `top` above stands
  for; the 2026-11-15 amendment already declined excusing the caller's group.
- Comparing the real uid (`ps -o ruid=`). Measured: setuid `top` lists uid 0, real uid 501, and
  `lsof -a -p <its pid> -d cwd` names no folder and exits 1. Its folder would go unseen.
- Dropping the snapshot's own row by pid. The same effect, but it needs the pid of the process
  that becomes `ps`, a third column and a parse change; the design changes one line.
- Dropping rows named `ps`. A name vouches for nothing.
- `pgrep -g` (not setuid, never lists itself) for the members, then `ps -p` for their uids. Two
  snapshots and a second tool for one fact.

## Tests (`tests/herdr-app.test.sh`)

The `ps` stub's `-A -o uid=,pgid=` answer gains the row the real one prints for itself: uid 0 in
the stub's own process group (`perl -e 'print getpgrp'`; the sandbox denies the real setuid
`ps`). The existing `group` and `group-café` cases move their fixed group from 777 to 100777,
above macOS's largest pid (99999), so that row can never land in it.

One new case beside `group`, for the caller t9 whose foreground group is the suite's own (the
helper inherits it, as under Retire), read with `perl -e 'print getpgrp'`:

- every member of the helper's user, folders outside the checkout: `check` passes. Its revert
  check: with the helper's line reverted it fails, because the stub, run from the helper, lists
  itself as uid 0 in that group;
- the same with another user's process added to that group: `check` refuses. Reverting this
  change only adds refusals, so this assertion cannot fail on revert; it guards the first declined
  alternative instead, and its check is that mutation (the uid test skipped for the helper's own
  group makes it fail, while the existing case in group 100777 still passes).

The existing "another user's process in the group" case still refuses.

## Acceptance

Mine, before the pre-merge review: the measurement above, rerun on the final commit.

Michael's, read-only, from a Herdr app terminal (optional before merge, since it runs the
branch's file):

```zsh
for h in ~/.config/herdr-app/bin/checkout-spaces ~/.local/share/chezmoi-fix-checkout-spaces-own-group/dot_config/herdr-app/bin/executable_checkout-spaces; do
  for i in {1..10}; do $h check /nonexistent/checkout 2>&1 | grep -c "$HC_TERMINAL_ID" ; done | sort | uniq -c; done
```

The deployed helper names this terminal in some runs (about 7 in 10); the branch's in none. After
merge and `chezmoi apply`, each with no "gave no folder" refusal:

- `wt-rm` of a scratch `wt` line, from an app terminal in another space, removes it;
- Retire worktree on a second scratch line removes it and closes its tab.
