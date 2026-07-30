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

> **CORRECTION (2026-07-30): the layer separation below is DISPROVEN.** The design assumed
> layer 1 governs only Claude's own file tools while layer 2 governs sandboxed subprocesses.
> It does not: **Read/Edit denials merge into the Bash sandbox boundary**, so a layer-1 deny
> also blocks every sandboxed subprocess touching that path. Deploying `Read(~/.ssh/**)`
> broke `git commit` signing immediately — see *Task 5 rollback* below. Layer 1 as specified
> must not be deployed until the agent prerequisite is solved. Layers 3 and 4 are unaffected.

Four complementary control layers:

1. **Tool rules** — what Claude's own Read/Edit tools may touch. **In practice also
   constrains sandboxed subprocesses**, per the correction above.
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
an explicit unsandboxed override or manual paste. That cost is accepted in exchange for a
rule that cannot be outrun by a new key name.

#### Task 5 rollback (2026-07-30) — `~/.ssh/**` breaks commit signing

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

**Two obvious repairs are both invalid at present:**

| Repair | Why it fails |
|---|---|
| Move the public key out of `~/.ssh` | Git permits `user.signingKey` to name a *public* key only when the matching private key is reachable through `ssh-agent`; otherwise it must name the private key directly. There is no supported "strip `.pub` and load the adjacent private key" behaviour in `ssh-keygen -Y`. With no reachable agent, relocating the public key achieves nothing |
| Exempt `michael` from the deny | Restores signing by leaving the most important private key readable by sandboxed processes — the opposite of the goal. `michael.pub` was merely the *first* failure; permitting it would surface the unavailable-agent/private-key failure next |

**Prerequisite, therefore: do not deploy any `.ssh` denial that reaches sandboxed
subprocesses until the agent is reachable inside the sandbox.** That is the same blocker
that already deferred layer 2 — it now blocks layer 1 as well.

**Redesign direction:**

1. Make the 1Password agent reachable over a stable, allowlistable socket.
2. Copy the public signing key to `~/.config/git/signing.pub` and repoint `user.signingKey`.
3. Keep private key material under the `~/.ssh/**` denial.
4. **Acceptance test before any redeployment: a signed disposable commit made from inside
   the sandbox must succeed.** Applying without this test is what produced this rollback.

An interim option worth investigating: a narrowly scoped, schema-verified hook blocking only
direct Read/Edit operations, leaving subprocesses untouched — with the subprocess exposure
documented explicitly rather than assumed away.

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

**The stated distinction between this layer and layer 1 is disproven** — layer 1 already
reaches sandboxed subprocesses. What remains genuinely unique to this layer is **secret
environment variables**, which no path-based rule can cover. The file entries are largely
redundant with layer 1 rather than complementary to it.

**Design chosen: targeted `credentials.files` entries, not a directory deny.** A
directory-wide deny would require proving that `filesystem.allowRead` re-admits `config`,
`known_hosts`, the public keys, and the agent socket *without* re-admitting private keys —
an unproven claim. Enumerating the private keys is directly verifiable.

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

`ssh-add -l` against the live agent additionally returns rc 2 (cannot connect), so there
is no agent holding identities to fall back on either.

Layer 2 is therefore **not deployed**. Layers 1 and 4 ship without it.

**Residual exposure, stated plainly:** Claude's own Read and Edit tools cannot touch the
keys, but **sandboxed subprocesses still can**. This is a narrower gap than before, not a
completed fix. Credentials must not be described as protected while this note stands.

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
| Directory-wide `~/.ssh` deny at layer 2 | Would require proving `allowRead` re-admits config/known_hosts/socket but not private keys. Targeted file entries are directly verifiable. |
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
| 1 | `fix(claude): repair inert permission rules` — layer 1 + settings test suite | Committed, **not deployed** |
| 2 | `fix(claude): harden sandbox escape routes` — layer 4. `strictAllowlist` stays **off** | Committed, **not deployed** |
| 3 | Apply and verify 1–2 with `strictAllowlist` off | **ROLLED BACK** — layer 1 broke commit signing; live settings restored from backup, byte-identical |
| 4 | Domain-discovery checkpoint — record **every destination observed**, including classifier-approved ones, not only rejections | Pending |
| 5 | `fix(claude): enable deterministic egress` — `allowedDomains` and `strictAllowlist: true` together | Pending |
| 6 | Apply and verify allowed *and* denied egress | Pending |
| 7 | `chore(agents): remove redundant Claude plugins` | Pending |
| — | Layer 2 credential isolation + SSH inventory test | **Deferred** — blocked on an allowlistable agent socket |

Applying step 3 also changes `permissions.defaultMode` from the live `plan` to the
template's `default`, and adds the `model` key. Both are behavioural and must be
acknowledged before the apply, not discovered after it.

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
- A no-output read of a key by a sandboxed subprocess **succeeds**. This is the residual
  exposure the deferral accepts and must be reported as such.
