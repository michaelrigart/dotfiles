# Claude Code Security Posture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 15 inert permission rules with enforcing ones, isolate credentials
from sandboxed subprocesses, and make egress deterministic — without widening network
access before the credential repair is verified.

**Architecture:** All configuration lands in the chezmoi `modify_` script
`dot_claude/modify_private_settings.json`, which receives the current
`~/.claude/settings.json` on stdin and emits the merged result on stdout. Because it is a
pure stdin→stdout jq filter, it is directly testable: pipe a fixture in, assert the emitted
JSON with `jq`. Every configuration task is therefore test-first. A separate inventory test
guards against credential coverage rotting as SSH keys are added.

**Tech Stack:** bash 3.2 (macOS system bash), `jq`, chezmoi `modify_` scripts, Claude Code
2.1.220 settings schema.

**Spec:** `docs/superpowers/specs/2026-07-30-claude-code-security-posture-design.md`
(Status: Approved, commit `7ea624b`)

## Global Constraints

- **Bash 3.2 compatible.** No associative arrays, no `${var,,}`, no `mapfile`. Matches the
  existing `.scripts/` convention.
- **All settings changes go in the jq template**, never in deployed `~/.claude/settings.json`
  — the modify script rebuilds the whole object and discards hand edits.
- **Carry-through keys must survive:** `enabledPlugins`, `extraKnownMarketplaces`, `model`,
  `effortLevel`. Every settings test asserts these are preserved.
- **`allowUnsandboxedCommands` stays `true`.** Ask-gated, never disabled.
- **`envVars` mode is `deny`, never `mask`** — mask introduces TLS-proxy requirements.
- **Phase 1 ships no `credentials.envVars` entries.**
- **`strictAllowlist` stays `false` until Task 7.** Enabling it before domains are known
  creates a deliberately broken network state.
- **Never print key material.** Inventory and tests operate on filenames only.
- **Do not push.** Commits only; the user pushes.

## Before starting

- [ ] **Mark the spec in progress.** Do this now, before Task 2 makes the first
      configuration change — not at the end. The status line tracks current state, so
      leaving it `Approved` while the template is being edited makes it false.

```bash
# In docs/superpowers/specs/2026-07-30-claude-code-security-posture-design.md:
#   **Status:** Approved   ->   **Status:** In progress
git commit -am "docs(claude): mark security posture spec in progress"
```

No MR link — this plan ends without pushing, so none exists yet. Add the reference after
the MR is opened; set `Implemented` only after merge.

## File Structure

| File | Responsibility |
|---|---|
| `dot_claude/modify_private_settings.json` | Modify — the sole configuration target. Layers 1, 2, 3, 4 all land here. |
| `.scripts/preflight-ssh-agent.sh` | Create — resolves the actual SSH agent socket. Read-only diagnostic; Task 1 gate. |
| `.scripts/test-claude-settings.sh` | Create — feeds fixtures through the modify script and asserts the emitted JSON. Grows one section per layer. |
| `.scripts/test-ssh-credential-inventory.sh` | Create — deny-by-default inventory of `~/.ssh` cross-checked against `credentials.files`. |
| `dot_config/agents/plugins.conf` | Modify — Task 8 only. |

Test scripts follow `.scripts/test-reconcile-agents.sh` conventions: `set -u`,
`pass=0; fail=0`, `_pass`/`_fail` helpers, `RESULT: N passed, N failed`, exit
`[ "$fail" -eq 0 ]`.

---

### Task 1: SSH-agent preflight gate

The spec makes this a **stop condition**. `~/.1password/` does not exist and `SSH_AUTH_SOCK`
is a per-boot launchd path, so the socket that sandboxed Git actually uses is unresolved.
Layer 2 must not deploy until this is settled.

**Files:**
- Create: `.scripts/preflight-ssh-agent.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: exit 0 = a stable allowlistable socket path printed on stdout, to be inserted
  into `allowUnixSockets` in Task 4. Exit 2 = no stable socket; **Task 3 must not proceed**.

- [ ] **Step 1: Write the preflight script**

```bash
#!/usr/bin/env bash
# Resolve the SSH agent socket that sandboxed git actually uses, so allowUnixSockets can
# be narrowed to it. Read-only: changes nothing. Bash 3.2 compatible.
#
# CONTRACT: stdout carries ONLY the socket path, and only on success. Every diagnostic
# goes to stderr, so `sock=$(preflight-ssh-agent.sh)` yields a clean path.
#
# Exit 0 -> protocol-validated socket path on stdout (allowlist exactly it)
# Exit 2 -> no usable socket; layer 2 (credential denial) MUST NOT deploy, because
#           denying on-disk keys without a working agent path breaks sandboxed git auth.
set -u

log() { printf '%s\n' "$*" >&2; }

log "== SSH agent preflight =="
log "SSH_AUTH_SOCK: ${SSH_AUTH_SOCK:-(unset)}"

# A socket file existing proves nothing — it may be stale, or belong to an agent holding
# no identities. Once the on-disk keys are denied, ssh_config's `AddKeysToAgent yes`
# cannot recover (it would have to read the key file), so identities must be present NOW.
validate() {  # validate <path> -> 0 only if the agent answers AND holds >=1 identity
  [ -S "$1" ] || { log "  absent or not a socket: $1"; return 1; }
  SSH_AUTH_SOCK="$1" ssh-add -l >/dev/null 2>&1
  case $? in
    0) log "  agent responds, identities present: $1"; return 0 ;;
    1) log "  agent responds but holds NO identities: $1"; return 1 ;;
    *) log "  cannot connect to agent at: $1"; return 1 ;;
  esac
}

for c in "$HOME/.1password/agent.sock" \
         "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"; do
  if validate "$c"; then
    log "RESULT: allowlist $c"
    printf '%s\n' "$c"          # the ONLY write to stdout
    exit 0
  fi
done

case "${SSH_AUTH_SOCK:-}" in
  /var/run/com.apple.launchd.*/Listeners)
    log "RESULT: launchd agent only — the path has a per-boot random component."
    log "Refusing to emit a wildcard: it would admit every launchd listener."
    exit 2 ;;
  "")
    log "RESULT: no SSH agent in this environment."; exit 2 ;;
  *)
    if validate "${SSH_AUTH_SOCK}"; then
      log "RESULT: socket is live, but its path stability across reboot is unproven."
      log "Confirm stability before allowlisting; failing closed for now."
    fi
    exit 2 ;;
esac
```

This validates the agent protocol rather than trusting a path. Whether GitLab specifically
authenticates remains Task 5's acceptance test — this gate only establishes that an agent
worth allowlisting exists.

- [ ] **Step 2: Run it and record the outcome**

Run: `bash .scripts/preflight-ssh-agent.sh; echo "exit=$?"`

Expected on this machine, per the spec's 2026-07-30 findings: `exit=2`, reporting the
launchd-only case.

- [ ] **Step 3: Apply the gate**

- **Exit 0** → note the printed path; Task 4 allowlists exactly it. Continue to Task 2.
- **Exit 2** → **stop and report to the user before Task 3.** Options to present:
  (a) configure the 1Password SSH agent so a stable socket exists, then re-run;
  (b) deploy layers 1 and 4 only, deferring layer 2;
  (c) accept that sandboxed Git loses key auth and use HTTPS + token for GitLab.
  Do not choose for the user. Tasks 2, 4, 5 and 8 remain safe to run either way.

- [ ] **Step 4: Commit**

```bash
git add .scripts/preflight-ssh-agent.sh
git commit -m "feat(claude): add SSH agent preflight for sandbox credential gating"
```

---

### Task 2: Settings test harness + Layer 1 permission rules

**Files:**
- Create: `.scripts/test-claude-settings.sh`
- Modify: `dot_claude/modify_private_settings.json:41-51` (the `permissions` block)

**Interfaces:**
- Consumes: nothing.
- Produces: `.scripts/test-claude-settings.sh`, extended by Tasks 3, 4 and 7. Helper
  contract: `emit <fixture-json>` sets `OUT` to the modify script's stdout;
  `jq_is <jq-filter> <expected> <label>` asserts against `OUT`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Feeds fixtures through dot_claude/modify_private_settings.json and asserts the emitted
# settings JSON. The modify script is a pure stdin->stdout filter, so this needs no chezmoi
# run and touches no deployed file. Run: bash .scripts/test-claude-settings.sh
set -u
MOD="$(cd "$(dirname "$0")/.." && pwd)/dot_claude/modify_private_settings.json"
pass=0; fail=0; OUT=""

_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '    | got: %s\n' "$2"; fail=$((fail + 1)); }
emit()  { OUT=$(printf '%s' "$1" | HOME="$HOME" /bin/bash "$MOD"); }
jq_is() { # jq_is <filter> <expected> <label>
  got=$(printf '%s' "$OUT" | jq -r "$1" 2>&1)
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$got"; fi
}

echo "A. layer 1 — permission rules match the approved set exactly"
emit '{}'

# Exact-array comparison, not a shape heuristic. A prefix/regex check would accept a typo
# like "Raed(~/.ssh/**)" or an unclosed "Typo(" and report green while the rule is inert —
# the same class of silent failure being repaired.
EXP_DENY='["Read(~/.ssh/**)","Edit(~/.ssh/**)",
 "Read(~/.aws/credentials)","Edit(~/.aws/credentials)",
 "Read(~/.config/op/config)","Edit(~/.config/op/config)",
 "Read(**/secrets.*.yml)","Edit(**/secrets.*.yml)",
 "Read(**/.env.production*)","Edit(**/.env.production*)",
 "Read(**/*.key)","Edit(**/*.key)",
 "Read(**/*.pem)","Edit(**/*.pem)"]'
EXP_ASK='["Read(~/.kube/config)","Edit(~/.kube/config)",
 "Edit(**/Dockerfile*)","Edit(**/docker-compose*.yml)",
 "Edit(**/.github/workflows/**)","Edit(**/.gitlab-ci.yml)",
 "Edit(**/.gitlab/ci/**)","Edit(**/terraform/**)","Edit(**/ansible/**)",
 "Bash(dangerouslyDisableSandbox:true)","Bash(docker *)"]'

jq_is "(.permissions.deny | sort) == ($EXP_DENY | sort)" true "deny array matches approved set exactly"
jq_is "(.permissions.ask  | sort) == ($EXP_ASK  | sort)" true "ask array matches approved set exactly"

# Belt and braces: every rule is a COMPLETE, closed form naming a tool we actually use.
jq_is '[.permissions.deny[], .permissions.ask[]
        | select(test("^(Read|Edit|Bash)\\([^)]+\\)$") | not)] | length' 0 \
      "every rule is a complete Read/Edit/Bash(spec) form"

echo "B. layer 1 — read/edit pairing on every secret pattern"
for p in '**/secrets.*.yml' '**/.env.production*' '**/*.key' '**/*.pem' \
         '~/.aws/credentials' '~/.config/op/config'; do
  jq_is ".permissions.deny | (index(\"Read($p)\") != null) and (index(\"Edit($p)\") != null)" \
        true "Read+Edit both denied for $p"
done

echo "C. layer 1 — no Write()/Glob() rules (2.1.210 warns on these)"
jq_is '[.permissions.deny[], .permissions.ask[] | select(test("^(Write|Glob|NotebookEdit)\\("))] | length' \
      0 "no Write/Glob/NotebookEdit rules"

echo "D. layer 1 — GitLab CI coverage"
jq_is '.permissions.ask | index("Edit(**/.gitlab-ci.yml)") != null' true "asks on .gitlab-ci.yml"
jq_is '.permissions.ask | index("Edit(**/.gitlab/ci/**)") != null' true "asks on .gitlab/ci/**"

echo "E. carry-through keys survive"
emit '{"enabledPlugins":{"x@y":true},"extraKnownMarketplaces":{"m":{}},"model":"opus[1m]","effortLevel":"xhigh"}'
jq_is '.enabledPlugins["x@y"]' true       "enabledPlugins carried through"
jq_is '.extraKnownMarketplaces.m != null' true "extraKnownMarketplaces carried through"
jq_is '.model'                'opus[1m]'  "model carried through"
jq_is '.effortLevel'          'xhigh'     "effortLevel carried through"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash .scripts/test-claude-settings.sh`
Expected: FAIL on section A — the current rules are bare globs, so the
`^[A-Za-z]+\(` count is 0 while `deny | length` is 9.

- [ ] **Step 3: Rewrite the permissions block**

In `dot_claude/modify_private_settings.json`, replace lines 41–51:

```jq
      "permissions": {
        "deny": [
          "Read(~/.ssh/**)",             "Edit(~/.ssh/**)",
          "Read(~/.aws/credentials)",    "Edit(~/.aws/credentials)",
          "Read(~/.config/op/config)",   "Edit(~/.config/op/config)",
          "Read(**/secrets.*.yml)",      "Edit(**/secrets.*.yml)",
          "Read(**/.env.production*)",   "Edit(**/.env.production*)",
          "Read(**/*.key)",              "Edit(**/*.key)",
          "Read(**/*.pem)",              "Edit(**/*.pem)"
        ],
        "ask": [
          "Read(~/.kube/config)",        "Edit(~/.kube/config)",
          "Edit(**/Dockerfile*)",        "Edit(**/docker-compose*.yml)",
          "Edit(**/.github/workflows/**)",
          "Edit(**/.gitlab-ci.yml)",     "Edit(**/.gitlab/ci/**)",
          "Edit(**/terraform/**)",       "Edit(**/ansible/**)",
          "Bash(dangerouslyDisableSandbox:true)",
          "Bash(docker *)"
        ],
        "defaultMode": "default"
      },
```

Note `**/.ssh/*_rsa.pub` is dropped: public keys are not secret, and `Read(~/.ssh/**)`
covers the directory anyway.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash .scripts/test-claude-settings.sh`
Expected: PASS — 14 deny rules, 11 ask rules, all Tool(spec) form.

- [ ] **Step 5: Commit**

```bash
git add .scripts/test-claude-settings.sh dot_claude/modify_private_settings.json
git commit -m "fix(claude): repair inert permission rules

Bare path globs parse as unknown tool names and match nothing, so all 15
deny/ask rules have been non-functional since b342cba. Rewrites them in
Tool(spec) form, pairs Read with Edit so denied files cannot be
overwritten, and adds GitLab CI paths alongside the GitHub ones."
```

---

### Task 3: SSH inventory test + Layer 2 credential isolation

**Gated by Task 1.** If the preflight exited 2 and the user has not resolved it, stop.

**Files:**
- Create: `.scripts/test-ssh-credential-inventory.sh`
- Modify: `dot_claude/modify_private_settings.json` (add `credentials` inside `sandbox`)

**Interfaces:**
- Consumes: Task 2's modify-script structure.
- Produces: `sandbox.credentials.files` — 14 entries, read by Task 5's verification.

- [ ] **Step 1: Write the failing inventory test**

Deny-by-default: enumerate every regular file directly under `~/.ssh`, exempt only the
known-readable set, require the rest to have entries. Mode-based classification is wrong —
`config`, `known_hosts`, `known_hosts.old` and `allowed_signers` are all 600, and `.pub`
files are inconsistently 644 and 600.

```bash
#!/usr/bin/env bash
# Deny-by-default inventory: every regular file directly under ~/.ssh must have a
# sandbox.credentials.files entry unless explicitly exempt. Catches archives and future
# keys regardless of naming or permissions. Filenames only — never reads key material.
# Run: bash .scripts/test-ssh-credential-inventory.sh
set -u
MOD="$(cd "$(dirname "$0")/.." && pwd)/dot_claude/modify_private_settings.json"
pass=0; fail=0

# Intentionally readable: ssh needs these, and they carry no private key material.
is_exempt() {
  case "$1" in
    config|known_hosts|known_hosts.old|allowed_signers|.DS_Store) return 0 ;;
    *.pub) return 0 ;;
    *) return 1 ;;
  esac
}

entries=$(printf '{}' | /bin/bash "$MOD" | jq -r '.sandbox.credentials.files[]?.path')

# find, not a glob: "$HOME"/.ssh/* does NOT enumerate dotfiles, so a hidden private key
# would pass unnoticed — which is exactly the silent-gap failure this test exists to
# prevent. -print0 also survives spaces in filenames.
while IFS= read -r -d '' path; do
  name=${path##*/}
  is_exempt "$name" && continue
  if printf '%s\n' "$entries" | grep -qxF "~/.ssh/$name"; then
    echo "  PASS: covered ~/.ssh/$name"; pass=$((pass + 1))
  else
    echo "  FAIL: UNCOVERED ~/.ssh/$name"; fail=$((fail + 1))
  fi
done < <(find "$HOME/.ssh" -maxdepth 1 -type f -print0)

# Guard the other direction. A configured path that no longer exists is a FAILURE, not a
# warning: it means the inventory has drifted, and a renamed key may now be uncovered
# while the entry count still looks correct. Heredoc (not a pipe) so $fail survives.
while IFS= read -r e; do
  [ -n "$e" ] || continue
  case "$e" in
    "~/.ssh/"*)
      if [ ! -f "$HOME/${e#\~/}" ]; then
        echo "  FAIL: stale entry $e (file absent)"; fail=$((fail + 1))
      fi ;;
  esac
done <<EOF
$entries
EOF

echo; echo "RESULT: $pass covered, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash .scripts/test-ssh-credential-inventory.sh`
Expected: FAIL — 12 uncovered files, because `sandbox.credentials` does not exist yet.

- [ ] **Step 3: Add the credentials block**

Inside the `"sandbox"` object in `dot_claude/modify_private_settings.json`, after
`"allowUnsandboxedCommands": true,`:

```jq
        "credentials": {
          "files": [
            { "path": "~/.ssh/borg",                          "mode": "deny" },
            { "path": "~/.ssh/borg-append-only",              "mode": "deny" },
            { "path": "~/.ssh/borg-append-only-fenrir",       "mode": "deny" },
            { "path": "~/.ssh/borg-config-michelangelo.tar.gz","mode": "deny" },
            { "path": "~/.ssh/borg-config-raphael.tar.gz",    "mode": "deny" },
            { "path": "~/.ssh/borg-fenrir",                   "mode": "deny" },
            { "path": "~/.ssh/borg-hercules",                 "mode": "deny" },
            { "path": "~/.ssh/borg-synology",                 "mode": "deny" },
            { "path": "~/.ssh/huginn",                        "mode": "deny" },
            { "path": "~/.ssh/michael",                       "mode": "deny" },
            { "path": "~/.ssh/michael_rsa",                   "mode": "deny" },
            { "path": "~/.ssh/viumore_rsa",                   "mode": "deny" },
            { "path": "~/.aws/credentials",                   "mode": "deny" },
            { "path": "~/.config/op/config",                  "mode": "deny" }
          ]
        },
```

No `envVars` key — phase 1 ships none, per the spec.

- [ ] **Step 4: Extend the settings test**

Append to `.scripts/test-claude-settings.sh` before the `RESULT` line:

```bash
echo "F. layer 2 — credential isolation"
emit '{}'
jq_is '.sandbox.credentials.files | length' 14 "14 credentials.files entries"
jq_is '[.sandbox.credentials.files[] | select(.mode != "deny")] | length' 0 "every entry is mode deny"
jq_is '.sandbox.credentials | has("envVars")' false "phase 1 ships no envVars entries"
jq_is '[.sandbox.credentials.files[].path | select(startswith("~/.ssh/"))] | length' 12 "12 ~/.ssh entries"
jq_is '[.sandbox.credentials.files[].path | select(endswith(".pub"))] | length' 0 "no public keys denied"
```

- [ ] **Step 5: Run both tests to verify they pass**

Run: `bash .scripts/test-ssh-credential-inventory.sh && bash .scripts/test-claude-settings.sh`
Expected: PASS — 12 covered / 0 uncovered, and 14 total entries.

- [ ] **Step 6: Commit**

```bash
git add .scripts/test-ssh-credential-inventory.sh .scripts/test-claude-settings.sh \
        dot_claude/modify_private_settings.json
git commit -m "fix(claude): isolate credentials from sandboxed subprocesses

Adds sandbox.credentials.files covering 10 private keys, both borg-config
archives, ~/.aws/credentials and ~/.config/op/config. The old id_*/*_rsa
globs matched 2 of the 10 keys.

Inventory test is deny-by-default: every regular file under ~/.ssh needs
an entry unless explicitly exempt, so a new key cannot be silently
unprotected. Mode-based classification is unusable — config, known_hosts
and allowed_signers are all 600, and .pub files are inconsistently 644
and 600."
```

---

### Task 4: Layer 4 escape routes

**Files:**
- Modify: `dot_claude/modify_private_settings.json:55-62` (the `sandbox` block)

**Interfaces:**
- Consumes: Task 1's socket decision.
- Produces: `sandbox.excludedCommands`; a narrowed `allowUnixSockets`.

- [ ] **Step 1: Write the failing test**

Append to `.scripts/test-claude-settings.sh` before the `RESULT` line:

```bash
echo "G. layer 4 — escape routes"
emit '{}'
jq_is '.sandbox.excludedCommands | index("docker *") != null' true "docker excluded from sandbox"
jq_is '.sandbox.allowUnsandboxedCommands' true "escape hatch retained (ask-gated)"
jq_is '.permissions.ask | index("Bash(dangerouslyDisableSandbox:true)") != null' true \
      "unsandboxed retry is ask-gated"
jq_is '.permissions.ask | index("Bash(docker *)") != null' true "docker commands ask-gated"
jq_is '[.sandbox.network.allowUnixSockets[] | select(test("docker"))] | length' 0 \
      "no docker sockets allowlisted"
jq_is '.sandbox.network.allowUnixSockets | index("~/.1password/agent.sock")' null \
      "dead 1Password socket entry removed"
jq_is '[.sandbox.network.allowUnixSockets[] | select(test("launchd"))] | length' 0 \
      "no launchd wildcard"
echo "H. layer 3 stays off until domains are known"
jq_is '.sandbox.network.strictAllowlist // false' false "strictAllowlist off in this phase"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash .scripts/test-claude-settings.sh`
Expected: FAIL — `excludedCommands` is absent and both Docker sockets are still allowlisted.

- [ ] **Step 3: Rewrite the sandbox network block**

Replace `"allowUnixSockets": [...]` and add `excludedCommands`:

```jq
        "excludedCommands": ["docker *"],
        "network": {
          "allowUnixSockets": [],
          "allowLocalBinding": true
        }
```

`allowUnixSockets` becomes empty: `/run/docker.sock` is a Linux path never valid on macOS,
`~/.1password/agent.sock` points at nothing, and `~/.docker/run/docker.sock` is removed
because Docker now routes through `excludedCommands`. **If Task 1 exited 0**, insert that
one printed socket path here instead of leaving the array empty.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash .scripts/test-claude-settings.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add .scripts/test-claude-settings.sh dot_claude/modify_private_settings.json
git commit -m "fix(claude): harden sandbox escape routes

Docker-socket access is root-equivalent on the host and largely defeats
the sandbox, so both sockets are removed and docker routes through
excludedCommands into the normal permission flow, ask-gated.

Two of the three allowUnixSockets entries were already dead:
/run/docker.sock is a Linux path never valid on macOS, and
~/.1password/agent.sock points at a directory that does not exist.

Keeps allowUnsandboxedCommands true and ask-gates it instead. Disabling
it would not affect chezmoi apply run directly from a terminal, but may
require unsandboxed execution for Claude-initiated op-backed applies."
```

---

### Task 5: Apply and verify the deployed layers

Covers layers 1 and 4 always, and layer 2 **only if Task 3 ran**. `strictAllowlist` is
still off. This is the checkpoint before egress changes.

**Files:** none modified — verification only.

- [ ] **Step 1: Preview the apply**

> **Every chezmoi command in this plan MUST pass `-S "$PWD"` from the worktree.**
> `chezmoi` defaults to its configured source directory — `~/.local/share/chezmoi`, i.e.
> **main** — not this branch worktree. Verified: the unqualified `chezmoi diff` shows only
> the theme and `defaultMode` lines and **none of the repaired rules**, so an unqualified
> apply would deploy the old config while appearing to succeed.
>
> **After applying, an ordinary `chezmoi apply` from main will revert this deployment**
> until the branch merges. That is expected; do not re-apply from main to "fix" it.

Run: `chezmoi -S "$PWD" diff ~/.claude/settings.json`

Expected: the deny array replaced with `Read(...)`/`Edit(...)` rules (9 → 14 entries),
`excludedCommands` added, `allowUnixSockets` emptied; the `credentials` block **only if
Task 3 ran**; `enabledPlugins` and `extraKnownMarketplaces` unchanged.

**Acknowledged drift — confirm all three before applying:**

| Key | Live | Template | Nature |
|---|---|---|---|
| `theme` | `custom:tokyo-night` | `custom:tokyo-night` | No-op. Same value; only its position in the file changes, so the diff shows it as added |
| `model` | absent | `opus[1m]` | Intended. The template seeds it as a default; the deployed file predates that line |
| `permissions.defaultMode` | `plan` | `plan` | **Resolved.** Now carried through, not enforced — see below |

`defaultMode` was originally enforced as `default`, which would have silently dropped the
live `plan` setting on every apply. It is runtime-mutable via `/permissions`, exactly like
`model` and `effortLevel`, which commit `71aaae2` had already converted to "seed as
default, not enforced" for that reason. `defaultMode` now joins them: an existing value is
preserved, and `default` is seeded only when the key is absent.

**Net behavioural change on apply is therefore the `model` key alone.** Verified at value
level rather than by reading diff text — chezmoi's side-by-side output shows relocated
context lines that are easily misread as changes.

- [ ] **Step 2: Apply**

Back up the live file first — this overwrites a security config.

Run: `chezmoi -S "$PWD" apply ~/.claude/settings.json`

**Expect this to fail under the sandbox** with `rename ...: operation not permitted`.
`~/.claude/settings.json` is on the sandbox's write-deny list, so the atomic rename is
blocked. This is not a plan defect.

**Before retrying, confirm the live file is unchanged** — the failure occurs before the
rename, so it should be byte-identical and still valid JSON:

```bash
jq -e '.permissions.deny | length' ~/.claude/settings.json   # expect the pre-apply count
```

Only then retry the same command unsandboxed. `Bash(dangerouslyDisableSandbox:true)` is now
in `ask`, so this prompts on every apply — intended, not friction to remove.

- [ ] **Step 3: Verify idempotence**

Run: `chezmoi -S "$PWD" apply ~/.claude/settings.json && chezmoi -S "$PWD" diff ~/.claude/settings.json`
Expected: empty diff on the second run.

- [ ] **Step 4: Verify in a fresh session**

Start a new Claude Code session and check:

- `/permissions` lists the Tool(spec) rules; **no unknown-tool-name warnings at startup**.
- `/sandbox` shows `excludedCommands: ["docker *"]` and no Docker sockets — plus the
  `credentials` block if Task 3 ran.
- `/status` shows the expected model and effort.

- [ ] **Step 5a: Adversarial verification — always run**

**Never test a deny rule against a real secret.** If the rule is broken — precisely the
failure under test — a Read leaks real key material into the transcript and an Edit
destroys the key. Use a disposable sentinel instead. `Read(~/.ssh/**)` and `Edit(~/.ssh/**)`
are directory-wide, so a sentinel under `~/.ssh` exercises the identical rule.

**Create and remove the sentinel from a separate terminal**, or via a command you
explicitly approve as unsandboxed. Creating it from inside a sandboxed Claude session
should *fail* — `Edit(~/.ssh/**)` is denied, which is the whole point. If sandboxed
creation succeeds, stop: the deny rule is not working and that is the finding.

```bash
printf 'sentinel-not-a-key\n' > "$HOME/.ssh/zz-claude-rule-check"
```

Read and Edit are distinct rules; test both. These hold whether or not layer 2 deployed.

| Check | Expectation |
|---|---|
| Read tool on `/Users/michael/.ssh/zz-claude-rule-check` | Refused, and the refusal shows no file contents |
| Edit tool on `/Users/michael/.ssh/zz-claude-rule-check` | Refused (a Read-only deny would still allow overwrite) |
| Read tool on a scratch `secrets.test.yml` | Refused |
| Edit tool on that same scratch file | Refused |
| A `docker ps` command | Prompts (ask rule fires) |
| Any `dangerouslyDisableSandbox: true` retry | Prompts (ask rule fires) |
| `/permissions` output | No unknown-tool-name warnings |

```bash
rm -f "$HOME/.ssh/zz-claude-rule-check"
```

**Remove the sentinel before Step 5b**, again from a separate terminal. The inventory test
enumerates every regular file under `~/.ssh`, so a leftover sentinel would be reported as
an uncovered credential.

- [ ] **Step 5b: Branch on whether layer 2 deployed**

**If Task 3 ran (preflight exited 0):**

`credentials.files` is an explicit path list, so a sentinel is not covered by it — these
must run against the real entries. Use a **no-output read**: bytes go to `/dev/null`, never
the transcript, so a broken rule cannot leak key material.

```bash
# "$HOME", never ~ : the shell does NOT tilde-expand after if=, so `if=~/.ssh/x` is passed
# literally and dd fails with rc 1 on the unresolved path. On the denied probe that
# non-zero rc looks exactly like a working deny — a false pass on the control itself.
dd if="$HOME/.ssh/borg-fenrir" of=/dev/null bs=1 count=1 2>/dev/null; echo "rc=$?"  # expect non-zero
dd if="$HOME/.ssh/config"      of=/dev/null bs=1 count=1 2>/dev/null; echo "rc=$?"  # expect 0
```

Sanity-check the probe itself before trusting either result: `dd if="$HOME/.ssh/config"`
must return 0. If it does not, the probe is broken, not the rule.

| Check | Expectation |
|---|---|
| No-output read of `~/.ssh/borg-fenrir` via Bash | Non-zero rc — refused by `credentials`, independently of the tool rules |
| No-output read of `~/.ssh/config` via Bash | rc 0 — ssh config must stay readable |
| `bash .scripts/test-ssh-credential-inventory.sh` | Passes: 12 covered, 0 failed |
| Sandboxed `git fetch` against GitLab | **Succeeds.** If it fails, layer 2 is wrong — revert Task 3's commit and re-run Task 1 rather than working around it |

**If Task 3 was skipped (preflight exited 2):**

| Check | Expectation |
|---|---|
| `.scripts/test-ssh-credential-inventory.sh` | **Not run — the script does not exist.** Skip, do not treat as failure |
| `jq '.sandbox \| has("credentials")' ~/.claude/settings.json` | `false` — confirms layer 2 genuinely absent rather than half-applied |
| No-output read of `~/.ssh/borg-fenrir` via Bash (`dd if="$HOME/..." of=/dev/null`) | rc 0 — expected; the tool-layer deny does not cover subprocesses. This is the residual exposure the deferral accepts. Use `"$HOME"`, never `~`, and never `cat`: observe the rc, not the bytes |
| Sandboxed `git fetch` against GitLab | Succeeds (keys still readable) |

- [ ] **Step 5c: Fresh-session checks — cannot be done from the applying session**

Permission rules load at session start, and slash commands are user-driven. **Task 5 stays
PARTIALLY VERIFIED until a fresh session confirms all of:**

| Check | Why it needs a fresh session |
|---|---|
| `/permissions` lists the Tool(spec) rules | Slash command, user-invoked |
| `/sandbox` shows `excludedCommands` and empty sockets | Slash command, user-invoked |
| `/status` shows expected model and effort | Slash command, user-invoked |
| **No unknown-tool-name warnings at startup** | Emitted only at session start |
| `docker ps` prompts | Requires the ask rule to be exercised interactively |
| An unsandboxed retry prompts | Same |
| Sentinel Read + Edit both refused | The sentinel must be created from a separate terminal, since the deny rule correctly blocks creating it from a sandboxed session |

Do not mark Task 5 complete, and do not describe the deployment as verified, until these
pass.

- [ ] **Step 6: Record results and report the residual gap**

If layer 2 deployed and all checks pass, continue to Task 6.

If layer 2 was deferred, **state the residual exposure explicitly** when reporting: Claude's
own tools cannot read the keys, but sandboxed subprocesses still can. That is a real and
narrower gap than before, not a completed fix — do not describe the work as "credentials
protected". Continue to Task 6; the egress work is independent of layer 2.

---

### Task 6: Domain discovery checkpoint

**Gate, not a code change.** Produces the evidence Task 7 consumes.

**Files:**
- Create: `docs/superpowers/runs/2026-07-30-domain-discovery.md` (untracked — generated
  execution state, per the design-records policy)

- [ ] **Step 1: Establish the evidence sources before running anything**

Running a workflow and watching it succeed does **not** reveal which hosts it contacted.
Redirects, OAuth token endpoints, CDN backends and classifier-approved calls are all
invisible at the command's own output.

**Primary source — Little Snitch monitor.** Filter to the workflow's process. Captures
every real outbound connection including redirect targets and OAuth endpoints; blind to
which Claude tool call caused it. This is the source of record.

**A `/sandbox` network-history view is UNVERIFIED — do not plan around it.** Every
`/sandbox` reference in the local changelog concerns configuration UI (tabs, dependency
status, layout), and the official documentation describes `/sandbox` as configuration,
recommending a custom proxy where request logging is required. Before relying on any
in-session history, open `/sandbox` and confirm such a view exists. If it does not, use
the fallback rather than substituting guesswork.

**Fallback — logging proxy.** `sandbox.network.httpProxyPort` and `socksProxyPort` exist in
the shipped example settings and are the documented mechanism for request logging. Point
them at a local logging proxy for the discovery window only, then remove them.

**Trap:** all four CLIs being measured — `glab`, `kubectl`, `tsh` and `basecamp` — are Go
binaries, and Go does not use the system trust store the way most tools do. Release
2.1.69: *"Added `sandbox.enableWeakerNetworkIsolation` setting (macOS only) to allow Go
programs like `gh`, `gcloud`, and `terraform` to verify TLS certificates when using a
custom MITM proxy with `httpProxyPort`"*.

Without that setting, **every** workflow in the table fails TLS and produces an empty
capture that reads as "no hosts contacted" rather than as an error — yielding a
confidently wrong allowlist that fails closed on all real traffic once Task 7 lands. Set
it for the discovery window only and **remove it afterwards**; it weakens network
isolation.

- [ ] **Step 2: Exercise each destination**

With `strictAllowlist` still off, run each workflow and capture from **all available
sources** — both if the proxy fallback is in use, Little Snitch alone otherwise.

| Workflow | Command |
|---|---|
| GitLab | `glab auth status` and a `git fetch` against a work repo |
| Basecamp | `basecamp me` (the OAuth path that previously failed silently) |
| Teleport | `tsh status` |
| Kubernetes | `kubectl get nodes` |
| Ruby toolchain | `bundle install --dry-run` in a Rails repo |

- [ ] **Step 3: Reconcile the two sources**

For each workflow, write the union of hosts to the run file, tagging each with its source
(`snitch`, `proxy`, or `both`) and whether it was allowed or denied.

**If two sources were available, any host seen by only one is a finding, not noise** — a
snitch-only host means the proxy never saw it (likely a subprocess bypassing it), and a
proxy-only host means Little Snitch attributed it to a different process. Resolve each
before proceeding; an unexplained gap means the inventory is incomplete and Task 7 would
fail closed on real traffic.

**If only Little Snitch was available**, say so in the run file and treat the resulting
allowlist as provisional: expect Task 7 Step 5 to surface misses, and be prepared to add
hosts and re-apply rather than assuming the first list is complete.

`launchpad.37signals.com` is the only host previously evidenced, and Basecamp auth is
expected to need more — treat a single-host Basecamp result as evidence the capture is
incomplete rather than as a finished answer.

- [ ] **Step 4: Report to the user**

Present the reconciled host list for approval before Task 7 writes it into settings.
Guessed hosts are explicitly rejected by the spec.

---

### Task 7: Layer 3 — deterministic egress

**Gated by Task 6 approval.**

**Files:**
- Modify: `dot_claude/modify_private_settings.json` (the `sandbox.network` block)

- [ ] **Step 1: Write the failing test**

Append to `.scripts/test-claude-settings.sh`, replacing section H:

```bash
echo "H. layer 3 — deterministic egress"
emit '{}'
jq_is '.sandbox.network.strictAllowlist' true "strictAllowlist enabled"
jq_is '.sandbox.network.allowedDomains | length > 0' true "allowedDomains populated"
jq_is '[.sandbox.network.allowedDomains[] | select(test("^\\*$|^\\*\\.\\*"))] | length' 0 \
      "no catch-all wildcard domains"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash .scripts/test-claude-settings.sh`
Expected: FAIL — neither key exists yet.

- [ ] **Step 3: Add the observed domains**

```jq
        "network": {
          "allowUnixSockets": [],
          "allowLocalBinding": true,
          "allowedDomains": [ <hosts approved in Task 6, one per line> ],
          "strictAllowlist": true
        }
```

Use only hosts recorded in Task 6. Both keys land in the same change — enabling
`strictAllowlist` without domains creates a deliberately broken network state.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash .scripts/test-claude-settings.sh`
Expected: PASS.

- [ ] **Step 5: Apply and verify both directions**

```bash
chezmoi -S "$PWD" apply ~/.claude/settings.json      # -S: never the default main source
```

In a fresh session verify **both**: an allowed request succeeds, and a non-allowlisted host
fails closed without prompting. Re-run each Task 6 workflow to confirm none regressed.

- [ ] **Step 6: Commit**

```bash
git add .scripts/test-claude-settings.sh dot_claude/modify_private_settings.json
git commit -m "fix(claude): enable deterministic egress

Adds allowedDomains from observed traffic and enables strictAllowlist in
the same change. Auto mode auto-approves sandbox network prompts and
accounts for 3083 of 3318 recorded messages, so egress during unattended
runs was classifier-mediated rather than deterministically restricted."
```

---

### Task 8: Plugin cleanup

The reconciler is **add-only** — `.scripts/reconcile-agents.sh:6` states it "never
uninstalls". Removing a declaration does not uninstall anything.

**Files:**
- Modify: `dot_config/agents/plugins.conf:14` (remove the `code-review` line)

- [ ] **Step 1: Remove the declaration**

Delete `claude_plugin       code-review@claude-plugins-official` from
`dot_config/agents/plugins.conf`. Leave every other line unchanged.
`frontend-design@claude-code-plugins` was never declared — it needs no edit here.

- [ ] **Step 2: Uninstall both plugins explicitly**

```bash
claude plugin uninstall code-review@claude-plugins-official
claude plugin uninstall frontend-design@claude-code-plugins
```

- [ ] **Step 3: Confirm absence**

```bash
claude plugin list --json | jq -r '.[].id' | sort
```
The field is `.id`, **not `.name`** — verified against the installed 2.1.220 CLI, whose
objects expose `enabled`, `id`, `installPath`, `installedAt`, `lastUpdated`, `scope`,
`version`. `jq -r '.[].name'` returns `null` for every row, which would silently print
nothing and falsely confirm removal.

Expected: neither `code-review@claude-plugins-official` nor
`frontend-design@claude-code-plugins` appears. `frontend-design@claude-plugins-official`
**remains** — it is the declared one.

- [ ] **Step 4: Confirm the built-in review command is exposed**

Run `/help` in a fresh session and confirm `/code-review` is present. The plugin's command
was GitHub-only (its `allowed-tools` declared only `gh`) and shadowed the built-in.

- [ ] **Step 5: Run the reconciler test**

Run: `bash .scripts/test-reconcile-agents.sh`
Expected: `RESULT: N passed, 0 failed`.

- [ ] **Step 6: Verify reconcile does not reinstall**

```bash
bash .scripts/reconcile-agents.sh
claude plugin list --json | jq -r '.[].id' | sort
```
Expected: neither plugin returns.

- [ ] **Step 7: Commit**

```bash
git add dot_config/agents/plugins.conf
git commit -m "chore(agents): remove redundant Claude plugins

frontend-design@claude-code-plugins was enabled but never declared —
duplicate of the official one. code-review@claude-plugins-official
declares only gh tools and posts via gh pr comment, so it is unusable on
GitLab and shadows the more capable built-in /code-review.

The reconciler never uninstalls, so both were removed explicitly."
```

---

## Completion

- [ ] `bash .scripts/test-claude-settings.sh` green
- [ ] `bash .scripts/test-reconcile-agents.sh` green
- [ ] `bash .scripts/test-ssh-credential-inventory.sh` green — **only if Task 3 ran.** If
      layer 2 was deferred this script does not exist; skip it and record why, rather than
      reporting a missing-file error as a failure
- [ ] `chezmoi -S "$PWD" diff ~/.claude/settings.json` empty (run from the worktree; an
      unqualified invocation reads main and is meaningless here)
- [ ] Noted that `chezmoi apply` from main reverts this deployment until the branch merges
- [ ] Spec still reads `**Status:** In progress` (set in *Before starting*) with no MR
      link. Do **not** set `Implemented` here — this plan ends without pushing, so the MR
      does not exist yet. The reference is added after the MR is opened; `Implemented`
      only after merge
- [ ] If layer 2 was deferred, the report states the residual exposure explicitly
      (sandboxed subprocesses can still read the keys) rather than describing credentials
      as protected
- [ ] Report to the user; **do not push** — pushing is the user's call
