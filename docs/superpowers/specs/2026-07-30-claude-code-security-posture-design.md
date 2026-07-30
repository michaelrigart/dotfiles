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

Four complementary control layers:

1. **Tool rules** — what Claude's own Read/Edit tools may touch.
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

### Layer 2 — credential isolation

Layer 1 governs Claude's tools; this layer governs **sandboxed subprocesses**, which is
why the two differ. Env vars are also the reason this layer is not redundant: no
path-based rule can cover them.

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

1. `fix(claude): repair permission and credential boundaries` — layers 1 and 2, plus the
   SSH inventory regression test.
2. `fix(claude): harden sandbox escape and network policy` — layer 4 only.
   `strictAllowlist` stays **off**.
3. Apply and verify 1–2 with `strictAllowlist` off.
4. Domain-discovery checkpoint — reproduce GitLab, Basecamp, Teleport (`tsh`) and
   Kubernetes (`kubectl`) traffic; record **every destination observed**, including
   classifier-approved ones, not only rejections.
5. `fix(claude): enable deterministic egress` — `allowedDomains` and
   `strictAllowlist: true` together.
6. Apply and verify allowed *and* denied egress.
7. `chore(agents): remove redundant Claude plugins` — see below.

Plugin removal, given the add-only reconciler:

- Remove `code-review@claude-plugins-official` from `plugins.conf`.
- Uninstall **both** `frontend-design@claude-code-plugins` (enabled but never declared)
  and `code-review@claude-plugins-official`.
- Confirm absence via `claude plugin list --json`.
- Confirm `/help` exposes the built-in `/code-review`.
- Run `.scripts/test-reconcile-agents.sh`.

## Verification

- `/status`, `/permissions`, `/sandbox` reflect the intended rules, with no
  unknown-tool-name warnings at startup.
- Denied **Read** and denied **Edit** tested separately against a credential path; both
  refused, and neither refusal leaks file contents.
- Bash-level credential denial tested separately from Claude's file tools — a sandboxed
  `cat` of a denied key must fail independently of the Read-tool deny.
- `~/.ssh/config` remains readable to sandboxed subprocesses.
- A sandboxed Git operation against GitLab authenticates successfully via whatever agent
  socket the preflight gate identified. If the gate found no allowlistable socket, layer 2
  is not deployed and this test is a stop condition rather than a pass/fail.
- SSH inventory regression test passes: 12 files enumerated under `~/.ssh`, each with a
  `credentials.files` entry. Those 12 are a subset of **14** total `credentials.files`
  entries — the other two being `~/.aws/credentials` and `~/.config/op/config`, which are
  outside `~/.ssh` and therefore outside the inventory test's scope.
- Both new ask rules fire: a Docker command and an unsandboxed retry each prompt.
- Allowed egress succeeds and non-allowlisted egress fails closed (after step 5).
- A second targeted `chezmoi apply ~/.claude/settings.json` is idempotent — no diff.
- `.scripts/test-reconcile-agents.sh` passes after the plugin change.
