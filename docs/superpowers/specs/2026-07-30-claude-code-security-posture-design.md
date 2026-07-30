# Claude Code security posture

**Status:** In progress

Repairs the permission and sandbox boundaries in the chezmoi-managed Claude Code
configuration. The existing `permissions.deny` / `permissions.ask` rules are inert: they
appear to protect credentials and do not.

Written against Claude Code **2.1.220**. Configuration target:
`dot_claude/modify_private_settings.json` (a chezmoi `modify_` script — see *Deployment
constraint* below).

## Problem

`permissions.deny` and `permissions.ask` are written as bare path globs
(`**/.ssh/*_rsa`, `**/*.pem`, `**/Dockerfile*`, …). Permission rules take the tool name in
first position, so each of these parses as an *unknown tool name* and matches nothing.

All 9 deny rules and all 6 ask rules have been non-functional since the managed settings
were introduced on **2026-07-18** (`b342cba`). SSH key material, `~/.aws/credentials`,
`~/.config/op/config`, `*.pem`, `*.key`, `secrets.*.yml`, and `.env.production*` have had
no tool-layer protection.

Even had the rules worked, their coverage was wrong. An inventory of `~/.ssh` finds **10
private keys**; the `id_*` and `*_rsa` patterns match **two** of them:

| | |
|---|---|
| Matched | `michael_rsa`, `viumore_rsa` |
| Missed | `borg`, `borg-append-only`, `borg-append-only-fenrir`, `borg-fenrir`, `borg-hercules`, `borg-synology`, `huginn`, `michael` |

Also unprotected and not previously identified: `borg-config-michelangelo.tar.gz` and
`borg-config-raphael.tar.gz`, Borg configuration archives that may carry repository keys.

Two further gaps compound this:

- **Docker sockets are allowlisted inside the sandbox.** Docker-socket access is
  root-equivalent on the host and largely defeats the sandbox boundary.
- **Egress during auto-mode runs is classifier-mediated rather than deterministically
  restricted.** Non-allowlisted hosts are subject to the auto-mode classifier, which can
  block them, but there is no fail-closed host boundary. `strictAllowlist` converts this
  into one. Measured 2026-07-30 across recorded session transcripts: `permissionMode:
  auto` on 3083 messages versus 235 for `default`, so the auto path is the normal case.

## Evidence

Claims are cited by release rather than line number, since changelog line numbers move.
Anything not verified against a release, a shipped file, or the installed binary is
marked UNVERIFIED and must be confirmed before implementation.

| Release | Statement | Bears on |
|---|---|---|
| 2.1.166 | "Added glob pattern support in deny rule tool-name position (`"*"` denies all tools); allow rules reject non-MCP globs, and unknown tool names in deny rules warn at startup" | First position is the tool name; bare globs are inert |
| 2.1.176 | "Fixed hook `if` conditions for Read/Edit/Write tool paths: documented patterns like `Edit(src/**)`, `Read(~/.ssh/**)`, and `Read(.env)` now match correctly" | Correct rule form |
| 2.1.178 | "Added `Tool(param:value)` syntax for permission rules to match a tool's input parameters (with `*` wildcard), e.g. `Agent(model:opus)` to block Opus subagents" | `Bash(dangerouslyDisableSandbox:true)` is supported |
| 2.1.187 | "Added `sandbox.credentials` setting to block sandboxed commands from reading credential files and secret environment variables" | Credential isolation; covers env vars |
| 2.1.210 | "Added a startup warning for `Write(path)`, `NotebookEdit(path)`, and `Glob(path)` permission rules — use `Edit(path)` or `Read(path)` instead" | Use `Edit(...)`, never `Write(...)` |
| 2.1.219 | "Added `sandbox.network.strictAllowlist` setting to deny non-allowlisted hosts for sandboxed commands without prompting" | Deterministic egress |
| 2.1.97 | "Improved auto mode and bypass-permissions mode to auto-approve sandbox network access prompts" | Why prompting alone is not a control |

Key names additionally confirmed against the Anthropic-shipped example
`plugins/marketplaces/claude-code-plugins/examples/settings/settings-bash-sandbox.json`,
which uses `sandbox.network.allowedDomains` and `sandbox.excludedCommands`.

### `sandbox.credentials` schema — verified

Confirmed against the installed 2.1.220 binary, which contains the literal strings
`sandbox.credentials.files`, `credentials.envVars`, and `sandbox.credentials mask
entries`:

```json
"credentials": {
  "files":   [ { "path": "~/.aws/credentials", "mode": "deny" } ],
  "envVars": [ { "name": "EXAMPLE_TOKEN",      "mode": "deny" } ]
}
```

`files` takes `path` + `mode: "deny"`. `envVars` accepts `deny` or `mask`. **Use `deny`,
not `mask`** — mask introduces TLS-proxy requirements.

`EXAMPLE_TOKEN` above is an illustrative placeholder written for this document — it is not
a literal recovered from the binary schema, and is not a value to deploy. Phase 1
ships **no `credentials.envVars` entries**; the file entries are the whole of layer 2 for
now. Env-var denial is deferred until specific secret-bearing variables are identified.

`sandbox.credentials.allowPlaintextInject` exists as a separate key in the binary. It is
not used here and is recorded only so it is not mistaken for a gap later.

Runtime validation of the schema remains an acceptance test, not an assumption.

## Design

> **CORRECTION (2026-07-30): Read/Edit denials also constrain Bash, but the sandbox has a
> narrower override.** Permission paths merge into the Bash sandbox boundary. The first
> deployment therefore broke SSH commit signing. Anthropic's documented
> `sandbox.filesystem.allowRead` takes precedence inside the sandbox without overriding the
> direct-tool permission decision. The corrected design uses that override for four
> Git-required SSH files; see *Task 5 rollback and repair* below.

Four complementary control layers:

1. **Tool rules** — what Claude's own Read/Edit tools may touch, plus the default
   subprocess boundary formed when those paths merge into the sandbox.
2. **Credential isolation** — what sandboxed subprocesses may read, including env vars.
3. **Network allowlist** — where sandboxed commands may connect, denied without prompt.
4. **Explicit approval for escape routes** — unsandboxed execution and Docker.

### Layer 1 — tool rules

Rewrite all 15 rules into `Tool(spec)` form. `Read` denies exposure, `Edit` denies
mutation; both are required, or a file can be overwritten while unreadable. Never
`Write(...)` (2.1.210).

```
deny:  Read(~/.ssh/**)               Edit(~/.ssh/**)
       Read(~/.aws/credentials)      Edit(~/.aws/credentials)
       Read(~/.config/op/config)     Edit(~/.config/op/config)
       Read(**/secrets.*.yml)        Edit(**/secrets.*.yml)
       Read(**/.env.production*)     Edit(**/.env.production*)
       Read(**/*.key)                Edit(**/*.key)
       Read(**/*.pem)                Edit(**/*.pem)

ask:   Read(~/.kube/config)          Edit(~/.kube/config)
       Edit(**/Dockerfile*)          Edit(**/docker-compose*.yml)
       Edit(**/.github/workflows/**) Edit(**/.gitlab-ci.yml)
       Edit(**/.gitlab/ci/**)        Edit(**/terraform/**)
       Edit(**/ansible/**)
       Bash(dangerouslyDisableSandbox:true)
       Bash(docker *)
```

`.gitlab-ci.yml` and `.gitlab/ci/**` are new — the previous ask list covered GitHub
workflows only, while the primary hosting is GitLab, and GitLab pipelines commonly
`include:` files from `.gitlab/ci/`.

`~/.ssh/**` is denied wholesale at this layer, which is immune to the key-naming drift
that defeated the old globs. **Trade-off:** this intentionally sacrifices direct Claude
inspection of SSH configuration — diagnosing `~/.ssh/config` or `known_hosts` will require
manual paste. The sandbox separately re-admits the minimum files required by Git:
`config`, `known_hosts`, `michael`, and `michael.pub`. This does not restore direct Read,
Edit, or `@file` access.

#### Task 5 rollback and repair (2026-07-30)

Layer 1 was applied and **rolled back the same day**. The deployed
`Read(~/.ssh/**)` blocked git from reading the SSH signing key, and every signed commit
failed with `fatal: failed to write commit object`. Because the git config is global, this
affected every repository, not just this one.

```
gpg.format = ssh   commit.gpgsign = true   user.signingKey = ~/.ssh/michael.pub
```

Git reported `No such file or directory`, which is misleading: the file exists and the read
was denied.

**This contradicts a decision made earlier in this spec.** `**/.ssh/*_rsa.pub` was dropped
on the grounds that public keys are not secret — then `Read(~/.ssh/**)` re-covered every
`.pub` wholesale. Public keys turn out to be load-bearing for signing. The recorded
trade-off ("sacrifices direct Claude inspection of SSH configuration") was far too narrow.

Two initial repairs were rejected:

| Repair | Why it fails |
|---|---|
| Move only the public key out of `~/.ssh` | A controlled test with `SSH_AUTH_SOCK` disabled returned 0 for `~/.ssh/michael.pub`, where the adjacent private key exists, and 255 for a relocated copy. Relocating only the public half therefore breaks the current signing path |
| Replace the rule with a hook | A `PreToolUse` hook can block direct Read/Edit, but Anthropic documents that `@file` references bypass it. A hook alone is not the same boundary |

The repaired configuration keeps `Read(~/.ssh/**)` and `Edit(~/.ssh/**)`, then adds:

```json
"sandbox": {
  "filesystem": {
    "allowRead": [
      "~/.ssh/config",
      "~/.ssh/known_hosts",
      "~/.ssh/michael",
      "~/.ssh/michael.pub"
    ]
  }
}
```

`allowRead` has higher precedence than the merged sandbox denial, so Git can read those
four files. It does not override the permission rule, so Claude's direct Read, Edit, and
`@file` paths remain denied across all of `~/.ssh`. There is no `allowWrite` exception.

This is an explicit residual capability: a sandboxed subprocess can read the `michael`
private key because current signing depends on it. Every other private key and archive
under `~/.ssh` stays denied to both direct tools and sandboxed subprocesses. Moving the
signing operation fully to an allowlistable agent would remove this carve-out, but it is
not a prerequisite for deploying the corrected layer 1.

Pre-deployment acceptance against the emitted settings passed:

- a normally signed disposable commit inside Claude's sandbox, with a `gpgsig` header;
- direct Read and Edit denied against a harmless `~/.ssh` sentinel;
- an `@file` reference to the same sentinel denied.

#### Second rollback (2026-07-31) — the `allowRead` carve-out exposed the primary auth key

A repair attempt added `sandbox.filesystem.allowRead` for `~/.ssh/config`, `known_hosts`,
`michael` and `michael.pub`, restoring commit signing. It was deployed, then **rolled back
the same day**.

`~/.ssh/michael` is a **private authentication key**, not merely the public half. Verified
by constructed-path probe, reporting size only:

```
READABLE  michael      (388 bytes)   <- private auth key
denied    borg-fenrir
denied    huginn
```

**Mechanism:** `sandbox.filesystem.allowRead` overrides the OS-level denial inside the
sandbox. This is not a command-string matching gap — the sandbox does not rely on string
matching for its boundary. The `Read(~/.ssh/**)` deny still governs direct tool use; it
simply does not constrain a subprocess reading a file that `allowRead` has admitted.

**This trade had already been analysed and rejected** earlier in this same effort:
exempting the signing key restores signing while leaving the most important private key
readable by every sandboxed process. It was implemented anyway.

**The test suite pinned the unsafe policy.** An assertion required `allowRead` to equal
exactly those four paths, `michael` included. The suite reported 32/32 — green meant
"matches intent", and the intent contained the exposure. A passing suite is not evidence of
a sound policy when the suite encodes the policy.

**Rollback order matters.** The source commit was reverted *before* the live file was
restored. Reverting only the deployed file would leave a future `chezmoi apply` able to
redeploy the exposure silently.

**Current live state, stated plainly:** the original baseline is restored, whose rules are
the inert bare globs. **No SSH key is protected — all four auth keys read successfully.**
That is strictly more exposure than the reverted state, which protected three of four. The
rollback is not a security improvement; it removes a *misrepresented* control and returns to
the documented, known-unprotected baseline rather than leaving a config that claims
protection it does not provide.

#### Next: a dedicated signing-only key — described accurately

The conflict between "deny `~/.ssh`" and "git must sign" is dissolved by never using an
authentication key for signing. Generate a keypair used **solely** for commit signing, at
`~/.config/git/signing`, and repoint `user.signingKey`.

**Do not overstate this.** If the signing key's private half is allowlisted so sandboxed
git can use it, **it remains extractable by any sandboxed process** — exactly as `michael`
was. The gain is blast radius, not secrecy: a leaked signing-only key permits forged
commits, not server or GitLab authentication. That is **materially safer, not secret**. An
agent-backed signing key, where the private half never becomes readable, is strictly
stronger and remains the better target.

**Acceptance tests required before any redeployment:**

1. Constructed-path reads of `~/.ssh/michael` and every other authentication key **fail**.
2. A normally signed disposable commit succeeds — never `--no-gpg-sign`.
3. If operating without an agent, **only** the dedicated signing key is readable.
4. GitLab recognises the new signing key.
5. Local `allowed_signers` verifies the signature. (Note: `gpg.ssh.allowedSignersFile` is
   currently unset, so signatures have never been locally verifiable — that must be
   configured as part of this work.)
6. Layer 1 and layer 2 changes stay excluded until 1–5 pass.

#### Rule scope: relative patterns are narrower than they read

Path specifiers anchor differently, per the permission-rules documentation:

| Form | Anchored to |
|---|---|
| `path`, `./path` | the current directory |
| `~/path` | the home directory |
| `//path` | the filesystem root |

Read/Edit denials also merge into the Bash sandbox boundary, so a denied path blocks
shell commands referencing it, not only the file tools.

**Consequence:** the four relative pairs — `**/secrets.*.yml`, `**/.env.production*`,
`**/*.key`, `**/*.pem` — protect the **active project tree**, not arbitrary matching files
elsewhere on disk. The `~/...` rules (`~/.ssh/**`, `~/.aws/credentials`,
`~/.config/op/config`, `~/.kube/config`) are machine-wide.

Observed 2026-07-30 after deployment: a dummy `.pem` at an absolute path outside the
working tree was created and read successfully, while the identical operation inside the
worktree was denied. The old bare globs matched nothing at all, so this is a narrowing of a
claim, not a regression — but the protection is project-scoped and should be described that
way.

**Follow-up — inventory before widening.** Do **not** add `//**/*.pem` or broad
`~/**/*.pem` companions blindly: they would likely block legitimate CA bundles, toolchain
certificates, and runtime fixtures, producing constant false denials. Inventory the
matching files first. The likely shape is targeted `~/Code/**` companions, covering sibling
repositories without sweeping caches and language runtimes.

### Layer 2 — credential isolation

Layer 1 already denies sandboxed reads except for its four explicit Git carve-outs. The
file entries in this layer are therefore redundant for the other SSH keys, but remain the
mechanism that can remove the `michael` carve-out once signing uses an allowlistable agent.
Secret environment variables remain unique to this layer; no path rule can cover them.

**Design chosen: targeted `credentials.files` entries, not another directory deny.**
Layer 1 already supplies the directory boundary. Its `filesystem.allowRead` exception is
proven for `config`, `known_hosts`, `michael`, and `michael.pub`; layer 2's future job is
to remove the private-key exception after agent-backed signing works. Enumerating private
keys remains the directly verifiable way to prevent naming drift.

Entries: the 10 private keys listed above, both `borg-config-*.tar.gz` archives,
`~/.aws/credentials`, and `~/.config/op/config`. Left readable: `config`, `known_hosts`,
`known_hosts.old`, `allowed_signers`, all `*.pub`, and `agent/`.

**Inventory regression test — deny by default.** A static key list rots as keys are added,
and classifying by file mode does not work: `config`, `known_hosts`, `known_hosts.old`, and
`allowed_signers` are all mode 600, while `.pub` files are inconsistently 644 and 600. Mode
misclassifies in both directions.

The test therefore enumerates **every regular file directly under `~/.ssh`**, exempts only
`config`, `known_hosts`, `known_hosts.old`, `allowed_signers`, `*.pub`, and `.DS_Store`,
and requires every remaining file to have a `credentials.files` entry. This catches
archives and future keys regardless of naming or permissions. Current result: **12 files**
— the 10 private keys plus both `borg-config-*.tar.gz` archives.

**Preflight gate — resolve the SSH agent before touching `allowUnixSockets`.**
The prior assumption that agent-backed Git runs over a 1Password socket is false on this
machine, verified 2026-07-30:

- `~/.1password/` does not exist; `~/.1password/agent.sock` is absent.
- No 1Password group-container agent socket exists either.
- `SSH_AUTH_SOCK` is `/var/run/com.apple.launchd.<random>/Listeners` — a per-boot dynamic
  path with no stable component.

Consequently two of the three `allowUnixSockets` entries are already dead:
`/run/docker.sock` is a Linux path never valid on macOS, and `~/.1password/agent.sock`
points at nothing. Only `~/.docker/run/docker.sock` exists, and layer 4 removes it.

The implementation plan **must resolve the actual agent socket before changing
`allowUnixSockets`**. Do not wildcard the launchd directory — the random component is the
only thing distinguishing it, and a wildcard would admit every launchd listener. **If no
stable, narrowly allowlistable socket can be confirmed, stop deployment of layer 2 and
revisit agent-backed Git**, because denying the on-disk keys without a working agent path
will break sandboxed Git authentication to GitLab.

**Expected consequence:** direct-key Borg and SSH commands *inside Claude's sandbox* will
fail once the keys are denied. This is intended. Vorta runs outside Claude's sandbox and is
unaffected, so scheduled backups continue normally.

#### Layer 2 status: DEFERRED (2026-07-30)

The preflight gate ran and returned **exit 2**. `.scripts/preflight-ssh-agent.sh` reports:

- `~/.1password/agent.sock` — absent (`~/.1password/` does not exist)
- 1Password group-container socket — absent
- `SSH_AUTH_SOCK` — `/var/run/com.apple.launchd.<random>/Listeners`, no stable component

`ssh-add -l` returns rc 2 from inside the sandbox but rc 0 outside it. The agent exists and
holds identities; its per-boot launchd socket is not safely allowlistable in the sandbox.

Layer 2 is therefore **not deployed**. Corrected layers 1 and 4 ship without it.

**Residual exposure, stated plainly:** Claude's direct Read, Edit, and `@file` paths cannot
touch any SSH file. Sandboxed subprocesses can read only `config`, `known_hosts`,
`michael`, and `michael.pub`; the signing private key is the remaining credential
exception. Other SSH keys and archives are denied.

Unblocking requires one of:

1. Configure the 1Password SSH agent so a stable socket exists, then re-run the preflight.
2. Accept the deferral and revisit when the agent situation changes.
3. Move sandboxed GitLab access to HTTPS + token, removing the key dependency entirely.

### Layer 3 — network

`sandbox.network.allowedDomains` populated **only from observed traffic**, with
`strictAllowlist: true` enabled **in the same change** so the allowlist and the fail-closed
switch land together. Enabling `strictAllowlist` before domains are known would create a
deliberately broken network state.

Domain discovery is a gated checkpoint, and it must capture **all observed destinations —
not only denials**. Under auto mode the classifier approves most requests, so a
denial-only sweep would miss every host that currently succeeds and produce an allowlist
that fails closed on normal traffic the moment `strictAllowlist` is enabled.
`launchpad.37signals.com` is the only host currently evidenced, and Basecamp auth is
expected to need more.

### Layer 4 — escape routes

Keep `allowUnsandboxedCommands: true`, gated by `Bash(dangerouslyDisableSandbox:true)` in
`ask`. Add `sandbox.excludedCommands: ["docker *"]` and remove both Docker sockets from
`allowUnixSockets`; excluded commands return to the normal permission flow, where
`Bash(docker *)` in `ask` forces approval.

## Deployment constraint

`~/.claude/settings.json` is generated by the chezmoi `modify_` script
`dot_claude/modify_private_settings.json`, which rebuilds the whole object from a jq
literal and carries through only `enabledPlugins`, `extraKnownMarketplaces`, `model`, and
`effortLevel`. Any key added by hand to the deployed file is silently discarded on the
next `chezmoi apply`. **All changes go in the jq template.**

`~/.claude/CLAUDE.md` is likewise generated, from
`{{ onepasswordRead "op://Private/Agent instructions/notes" }}`. Instruction changes go
through the 1Password note, never the deployed file.

Deployed drift observed: the template defaults `model` to `opus[1m]`, but the deployed
file has no `model` key — `chezmoi apply` has not run since that line landed.

**The reconciler is add-only.** `.scripts/reconcile-agents.sh:6` states it "never
uninstalls, and respects deliberately-disabled plugins." Removing a declaration from
`plugins.conf` therefore does *not* uninstall the plugin; removal must be performed
explicitly.

**Applying requires an approved unsandboxed retry.** `~/.claude/settings.json` sits on the
sandbox's write-deny list, so `chezmoi apply` fails from inside the sandbox with
`rename ...: operation not permitted`. Observed 2026-07-30. The failure is safe — it aborts
before the atomic rename, leaving the live file byte-identical — and **that must be
confirmed before retrying**, so a partial write is never compounded. The retry runs
unsandboxed, which `Bash(dangerouslyDisableSandbox:true)` in `ask` now gates, so every
apply prompts. That is intended, not friction to design away.

**Use `-S <worktree>` until this branch merges.** chezmoi defaults to its configured source
directory (`~/.local/share/chezmoi`, i.e. main), so an unqualified apply deploys main's
configuration while appearing to succeed. A routine apply from main will likewise revert
this deployment until the branch merges.

## Decision log — rejected

| Rejected | Reason |
|---|---|
| Transcript-derived Bash allowlist | `autoAllowBashIfSandboxed: true` already auto-runs contained commands, so the premise (many manual approvals) was false. Allow rules would additionally grant those commands *unsandboxed*, weakening the boundary. |
| Global mutating RuboCop hook | Mutates files mid-edit, adds latency, and targets style while the actual friction was logic bugs. Any future hook: project-local, non-mutating, once per batch. |
| Broad `/mr` and `/cleanup` skills | Duplicate Superpowers (brainstorming, plans, TDD, review, verification, worktrees, branch finishing). A narrow GitLab shipping skill carrying only local glue is the better shape. |
| `code-review@claude-plugins-official` | Its `allowed-tools` declares only `gh` commands — no `git`, no `Read` — and it posts results via `gh pr comment`. No `$ARGUMENTS` and no local-diff path. Unusable on GitLab, and it shadows the more capable built-in `/code-review`. |
| Docker socket in `allowUnixSockets` | Root-equivalent host access; defeats the sandbox. |
| `allowUnsandboxedCommands: false` | Would not affect `chezmoi apply` run directly from a terminal — it disables only Claude Code's Bash escape hatch. It may, however, require unsandboxed execution for Claude-initiated `op`-backed applies. Ask-gating achieves the audit boundary without risking that path. |
| `envVars` mode `mask` | Introduces TLS-proxy requirements; `deny` is sufficient. |
| A second directory-wide `~/.ssh` deny at layer 2 | Layer 1 already supplies that boundary and its four `allowRead` exceptions are verified. Targeted credential entries are the mechanism for removing the signing-key exception after agent-backed signing works. |
| Mode-based private-key classification | `config`, `known_hosts`, `known_hosts.old`, and `allowed_signers` are all mode 600; `.pub` files are inconsistently 644 and 600. Mode misclassifies in both directions. Deny-by-default with an explicit exemption list instead. |
| Wildcarding the launchd socket directory | `SSH_AUTH_SOCK`'s random component is the only thing distinguishing it; a wildcard would admit every launchd listener. |
| Guessed `allowedDomains` entries | Fabricated hosts produce false coverage and mask the real ones. Observed traffic only. |
| Generic GitLab/Postgres MCP servers | `glab` and container-aware scripts are predictable and already available; MCP adds credential and write-risk surface without addressing a demonstrated CLI limitation. |

## Implementation

Sequenced so the security repair lands and is verified before egress policy changes.
Layer 2 is deferred — see *Layer 2 status* above — so the ordering below reflects what
actually ships.

| # | Change | Status |
|---|---|---|
| 0 | SSH-agent preflight (`.scripts/preflight-ssh-agent.sh`) | Done — returned exit 2 |
| 1 | `fix(claude): repair inert permission rules` — layer 1 + settings test suite | Committed and deployed with the signing carve-out |
| 2 | `fix(claude): harden sandbox escape routes` — layer 4. `strictAllowlist` stays **off** | Committed and deployed |
| 3 | Apply and verify 1–2 with `strictAllowlist` off | First attempt rolled back; corrected deployment verified |
| 4 | Domain-discovery checkpoint — record **every destination observed**, including classifier-approved ones, not only rejections | Pending |
| 5 | `fix(claude): enable deterministic egress` — `allowedDomains` and `strictAllowlist: true` together | Pending |
| 6 | Apply and verify allowed *and* denied egress | Pending |
| 7 | `chore(agents): remove redundant Claude plugins` | Pending |
| — | Layer 2 credential isolation + SSH inventory test | **Deferred** — blocked on an allowlistable agent socket |

Applying step 3 preserves the live `permissions.defaultMode` and adds the default `model`
key when absent.

Plugin removal, given the add-only reconciler:

- Remove `code-review@claude-plugins-official` from `plugins.conf`.
- Uninstall **both** `frontend-design@claude-code-plugins` (enabled but never declared)
  and `code-review@claude-plugins-official`.
- Confirm absence via `claude plugin list --json | jq -r '.[].id'` — the field is `.id`;
  `.name` returns `null` for every row and would falsely confirm removal.
- Confirm `/help` exposes the built-in `/code-review`.
- Run `.scripts/test-reconcile-agents.sh`.

## Verification

**Never test a deny rule against a real secret.** If the rule is broken — the failure under
test — a Read leaks key material and an Edit destroys the key. Tool-layer checks use a
disposable sentinel under `~/.ssh`, which the directory-wide rules cover identically.
Subprocess checks use a no-output read (`dd if="$HOME/..." of=/dev/null`) and assert the
exit code. Use `"$HOME"`, never `~`: the shell does not tilde-expand after `if=`, so
`if=~/.ssh/x` fails on an unresolved path and its non-zero rc is indistinguishable from a
working deny.

All chezmoi commands must pass `-S <worktree>` until this branch merges; the default source
is main, and an unqualified invocation silently verifies the wrong configuration.

### Always

- `/status`, `/permissions`, `/sandbox` reflect the intended rules, with no
  unknown-tool-name warnings at startup.
- Denied **Read** and denied **Edit** tested separately against the sentinel; both refused,
  and neither refusal leaks file contents.
- An `@file` reference to the sentinel is refused.
- A normally signed disposable commit succeeds inside the sandbox and carries a `gpgsig`
  header.
- A no-output Bash read of `~/.ssh/michael` succeeds while the same probe against another
  private key fails.
- Both new ask rules fire: a Docker command and an unsandboxed retry each prompt.
- `excludedCommands` is exactly `["docker *"]` and `allowUnixSockets` is exactly `[]` —
  pinned, so a later addition cannot widen the boundary unnoticed.
- A second targeted `chezmoi -S <worktree> apply ~/.claude/settings.json` is idempotent.
- `.scripts/test-reconcile-agents.sh` passes after the plugin change.
- Allowed egress succeeds and non-allowlisted egress fails closed (after layer 3).

### Only if layer 2 deployed

Currently **not applicable** — the preflight returned exit 2 and layer 2 is deferred. These
apply if and when it ships:

- Bash-level credential denial tested separately from Claude's file tools — a no-output read
  of a denied key must fail independently of the Read-tool deny.
- `~/.ssh/config` remains readable to sandboxed subprocesses (no-output read returns 0).
- A sandboxed Git operation against GitLab authenticates via the agent socket the preflight
  identified.
- SSH inventory regression test passes: 12 files enumerated under `~/.ssh`, each with a
  `credentials.files` entry — a subset of 14 total, the other two being
  `~/.aws/credentials` and `~/.config/op/config`.

### While layer 2 is deferred

- `.sandbox | has("credentials")` is **false** — asserted by the settings suite, so a
  partial layer 2 cannot be applied while the agent problem is unresolved.
- The inventory script does not exist; its absence is expected, not a failure.
- A no-output read of `~/.ssh/michael` by a sandboxed subprocess succeeds because signing
  requires it. The same probe against any other private key fails under the merged
  `Read(~/.ssh/**)` sandbox boundary.
