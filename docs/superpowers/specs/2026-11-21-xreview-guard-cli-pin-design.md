# Pre-merge gate: weigh `gh event` and move the CLI pin

**Status:** Implemented (the pull request of branch `fix/xreview-guard-cli-pin`)
**Date:** 2026-11-21
**Sign-off:** Michael, 2026-11-21, with the recommendation of §4. Spec review: approve in round 1,
no findings (`xr-1795221938-6e3797c7`).
**Branch:** `fix/xreview-guard-cli-pin`, in the `wt` checkout
`~/.local/share/chezmoi-fix-xreview-guard-cli-pin`, from `main` at `430fd6d`
**Related:** `2026-11-12-xreview-trust-design.md` §5.5 (the canary and its procedure), §5.2 (the
deny rules), §7 (accepted limits)

## 1. Intent

`tests/xreview-guard-cli.test.sh` is the canary for the CLI surface the pre-merge gate
(`dot_claude/xreview-guard.py`) was measured on. Since the Homebrew upgrades it exits 2
(INCONCLUSIVE) on `main` and on every branch, so `./tests/run.sh` gives no verdict on it. The
procedure the suite prints: read each new command's `--help`, then gate it, deny it or leave it, in
the change that updates the pin. This line does that.

## 2. What was measured (2026-11-21, this checkout)

Pinned on glab 1.130.0, gh 2.103.3, az 2.90.0 with azure-devops 1.0.8. Installed: glab 1.131.0,
gh 2.105.0, az 2.93.0 with azure-devops 1.0.8.

The suite compares all seven groups in one run and reports every one that differs; it does not stop
at the first. Its only `INCONCLUSIVE:` line (the versions and the procedure follow it):

```
INCONCLUSIVE: gh top level: added event; removed none
```

So six groups equal the pin: `glab mr`, glab top level, `gh pr`, `az repos pr`, the `glab api`
flags and the `gh api` flags. Nothing was removed anywhere.

Also read, outside what the suite pins:
- `gh api --help` and `glab api --help`: the options that take a value are the ones in
  `GH_API_VALUE` and `GLAB_API_VALUE`; no option changed kind.
- `gh help reference`: the aliases of the gated `gh pr` verbs are unchanged (`gh pr new`), and
  `gh event` has one alias, `gh event subscription ls`.

Not read: the flags of the gated verbs. The suite does not pin them, by design: a flag outside a
verb's allowlist is denied by name.

## 3. The new command: `gh event` (preview, github.com only)

| Command | What it does, per `--help` |
|---|---|
| `gh event listen` | Creates or reuses a subscription on one pull request and waits. Prints each event to stdout as one CloudEvent JSON line; exits after the first unless `--count`, `--follow` or `--timeout` say otherwise. Flags: `--resource`, `--event`, `--subscription`, `--count`, `--follow`, `--timeout`, `--jq`, `--template`. |
| `gh event subscription create` | Creates a subscription (resource and event types) on the account, without listening. Idempotent. |
| `gh event subscription delete <id>` | Deletes one of the account's subscriptions. |
| `gh event subscription list`, `view <id>` | Read the account's subscriptions. |

The five event types: a review was submitted, the PR's state changed, its head changed, it has a
merge conflict, a check suite completed. Events are "thin": a type and `data.api_url` pointing at
the object that changed, plus `data.conclusion` for a check suite. Subscriptions expire after 24
hours and count against a per-account limit.

No `gh event` command proposes a change, lands one, pushes, approves, or writes to a repository.
Its only writes are the account's own event subscriptions.

## 4. Decision: leave it

`gh event` is neither gated nor denied. The gate's subject is commands that propose or land a
change (trust spec §3.3); `gh event` does neither.

Two things were checked before settling on that.

**Waiting, then merging.** `gh event listen` makes "wait for the checks, then merge" a one-liner.
The gate already refuses it, because a gated verb must be a plain command. Measured against the
source guard:

| Command | Gate |
|---|---|
| `gh event listen --resource <pr-url> --event <type>` | allowed (the fast path passes it; a type or URL holding a trigger word, such as `merge_conflict`, sends it to the grammar, which finds no gated verb) |
| `gh event subscription create --resource <pr-url> --event <type>` | allowed (`create` sends it to the grammar, which finds no gated verb) |
| `gh event subscription delete sub_1` | allowed |
| `gh event listen … && gh pr merge 1 --merge` | denied (not the plain form) |
| `gh event listen …; gh pr create --fill` | denied (not the plain form) |

Run as two commands, the merge is judged on its own, pinned and by receipt, as today.

**Untrusted input.** What `gh event listen` prints is forge data: an agent that reads it is reading
text it did not write. That is already true of commands the setup leaves open, which carry far more
attacker-written text: `gh pr view`, `gh pr checks`, `gh api repos/…/pulls/<n>/comments`. An event
carries a type, a URL and a conclusion; the free text sits behind `data.api_url`, and fetching it is
one of those existing reads. `--jq` and `--template` format output and run nothing. So `gh event`
opens no input channel that is not open, and a deny rule for it would not close one. (The event
payload beyond what `--help` describes was not observed: the preview needs an enabled account.)

The remaining cost is the account's subscription limit, which an agent could fill. They expire in 24
hours, and nothing in the workflow depends on them.

## 5. Approaches

| | Approach | Trade-off |
|---|---|---|
| A | **Leave `gh event`; move the pin.** (chosen) | One file. The decision is recorded here and in the commit. |
| B | A, plus rows in `tests/xreview-guard.test.sh` for the five commands of §4. | Pins behaviour no code in this change produces: no fix to revert against. The chained denials are the plain-form rule the suite already covers. |
| C | A, plus a silent deny `Bash(gh event*)` in `modify_private_settings.json`, as for `gh agent-task create`. | Removes a polling replacement agents could use, to close a channel that §4 shows stays open through `gh pr view` and `gh api`. `gh agent-task create` was denied because it makes a PR; this makes none. |
| D | Gate `gh event listen` in `xreview-guard.py`. | It is no proposing or landing verb; there is no receipt to check it against. |

## 6. The change

`tests/xreview-guard-cli.test.sh` only:
- `PIN_VERSIONS`: `glab 1.131.0`, `gh 2.105.0`, `az 2.93.0, azure-devops 1.0.8`;
- `PIN_GH_TOP`: add `event`, in sorted position (between `discussion` and `extension`).

Not touched: `dot_claude/xreview-guard.py`, `executable_xreview-guard.sh`, the settings, any other
suite, `subjects.tsv` (no file is added or moved), `AGENTS.md`.

**Done when:** `./tests/xreview-guard-cli.test.sh` exits 0 with seven `PASS` lines, and
`./tests/run.sh --changed` shows no `FAIL` and no `????` row this change causes.

## 7. Non-goals and limits

- No change to what the gate gates. The limits of trust spec §7 stand, including "a new verb that
  arrives between a CLI upgrade and the next canary run".
- The comment above `GH_API_VALUE` still reads "gh 2.102's and glab 1.130's `--help`". It is left:
  correcting it edits the gate, and §2 found the sets it describes unchanged.
- `gh event` is a preview; its commands may change. A new top-level name trips the canary again; a
  new subcommand under `gh event` does not, as for every other unpinned group.
