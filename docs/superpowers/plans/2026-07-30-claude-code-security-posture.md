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
# be narrowed to it. Read-only: prints findings, changes nothing. Bash 3.2 compatible.
#
# Exit 0 -> stable socket path on stdout (allowlist it)
# Exit 2 -> no stable socket found; layer 2 (credential denial) MUST NOT deploy, because
#           denying on-disk keys without a working agent path breaks sandboxed git auth.
set -u

echo "== SSH agent preflight =="
sock="${SSH_AUTH_SOCK:-}"
echo "SSH_AUTH_SOCK: ${sock:-(unset)}"

candidates="
$HOME/.1password/agent.sock
$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
"
found=""
IFS='
'
for c in $candidates; do
  [ -n "$c" ] || continue
  if [ -S "$c" ]; then echo "  stable socket present: $c"; found="$c"; break
  else echo "  absent: $c"; fi
done
unset IFS

if [ -n "$found" ]; then
  echo "RESULT: allowlist $found"
  printf '%s\n' "$found"
  exit 0
fi

case "$sock" in
  /var/run/com.apple.launchd.*/Listeners)
    echo "RESULT: launchd agent only — path contains a per-boot random component." >&2
    echo "Refusing to emit a wildcard: it would admit every launchd listener." >&2
    exit 2 ;;
  "")
    echo "RESULT: no SSH agent in this environment." >&2; exit 2 ;;
  *)
    if [ -S "$sock" ]; then
      echo "RESULT: non-standard socket $sock — confirm stability across reboot before use." >&2
      exit 2
    fi
    echo "RESULT: SSH_AUTH_SOCK set but not a socket." >&2; exit 2 ;;
esac
```

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

echo "A. layer 1 — permission rules are Tool(spec) form"
emit '{}'
jq_is '[.permissions.deny[]  | select(test("^[A-Za-z]+\\("))] | length' \
      "$(printf '%s' "$OUT" | jq '.permissions.deny | length')" \
      "every deny rule is Tool(spec) form"
jq_is '[.permissions.ask[]   | select(test("^[A-Za-z]+\\("))] | length' \
      "$(printf '%s' "$OUT" | jq '.permissions.ask | length')" \
      "every ask rule is Tool(spec) form"
jq_is '.permissions.deny | index("Read(~/.ssh/**)") != null' true "denies Read(~/.ssh/**)"
jq_is '.permissions.deny | index("Edit(~/.ssh/**)") != null' true "denies Edit(~/.ssh/**)"

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

missing=0
for path in "$HOME"/.ssh/*; do
  [ -f "$path" ] || continue          # skips agent/ and any other directory
  name=$(basename "$path")
  is_exempt "$name" && continue
  if printf '%s\n' "$entries" | grep -qxF "~/.ssh/$name"; then
    echo "  PASS: covered ~/.ssh/$name"; pass=$((pass + 1))
  else
    echo "  FAIL: UNCOVERED ~/.ssh/$name"; fail=$((fail + 1)); missing=$((missing + 1))
  fi
done

# Guard the other direction: an entry for a file that no longer exists is stale.
printf '%s\n' "$entries" | while IFS= read -r e; do
  [ -n "$e" ] || continue
  case "$e" in
    "~/.ssh/"*) [ -f "$HOME/${e#\~/}" ] || echo "  WARN: stale entry $e (file absent)" ;;
  esac
done

echo; echo "RESULT: $pass covered, $missing uncovered"
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

Keeps allowUnsandboxedCommands true — disabling it would block
Claude-initiated op-backed chezmoi applies — and ask-gates it instead."
```

---

### Task 5: Apply and verify layers 1, 2 and 4

`strictAllowlist` is still off. This is the checkpoint before egress changes.

**Files:** none modified — verification only.

- [ ] **Step 1: Preview the apply**

Run: `chezmoi diff ~/.claude/settings.json`
Expected: the new permissions, credentials and excludedCommands; `enabledPlugins` and
`extraKnownMarketplaces` unchanged; `model` appears (the deployed file lacks it — known
drift from the template default `opus[1m]`).

- [ ] **Step 2: Apply**

Run: `chezmoi apply ~/.claude/settings.json`

- [ ] **Step 3: Verify idempotence**

Run: `chezmoi apply ~/.claude/settings.json && chezmoi diff ~/.claude/settings.json`
Expected: empty diff on the second run.

- [ ] **Step 4: Verify in a fresh session**

Start a new Claude Code session and check:

- `/permissions` lists the Tool(spec) rules; **no unknown-tool-name warnings at startup**.
- `/sandbox` shows `excludedCommands: ["docker *"]`, no Docker sockets, and the
  `credentials` block.
- `/status` shows the expected model and effort.

- [ ] **Step 5: Adversarial verification — each control separately**

Read and Edit are distinct rules; test both. Bash-level denial is a different layer from
the file tools; test it independently.

| Check | Expectation |
|---|---|
| Read tool on `~/.ssh/borg-fenrir` | Refused, **and the refusal shows no file contents** |
| Edit tool on `~/.ssh/borg-fenrir` | Refused (a Read-only deny would still allow overwrite) |
| Sandboxed `cat ~/.ssh/borg-fenrir` via Bash | Refused by `credentials`, independently of the tool rules |
| Sandboxed `cat ~/.ssh/config` | **Succeeds** — ssh config must stay readable |
| A `docker ps` command | Prompts (ask rule fires) |
| Any `dangerouslyDisableSandbox: true` retry | Prompts (ask rule fires) |
| Sandboxed `git fetch` against GitLab | Succeeds if Task 1 exited 0. If Task 1 exited 2, this is the **stop condition** — record the failure and report, do not work around it |

- [ ] **Step 6: Record results**

If every check passes, continue to Task 6. If the Git check fails because Task 1 exited 2,
stop and report to the user with the three options from Task 1 Step 3.

---

### Task 6: Domain discovery checkpoint

**Gate, not a code change.** Produces the evidence Task 7 consumes.

**Files:**
- Create: `docs/superpowers/runs/2026-07-30-domain-discovery.md` (untracked — generated
  execution state, per the design-records policy)

- [ ] **Step 1: Exercise each destination**

With `strictAllowlist` still off, run each and record **every host contacted**, not only
rejected ones. Under auto mode the classifier approves most requests, so a denial-only
sweep would miss hosts that currently succeed and produce an allowlist that fails closed
on normal traffic the moment Task 7 lands.

| Workflow | Command |
|---|---|
| GitLab | `glab auth status` and a `git fetch` against a work repo |
| Basecamp | `basecamp me` (the OAuth path that previously failed silently) |
| Teleport | `tsh status` |
| Kubernetes | `kubectl get nodes` |
| Ruby toolchain | `bundle install --dry-run` in a Rails repo |

- [ ] **Step 2: Record the hosts**

Write each host to the run file with the workflow that needed it and whether it was
allowed or denied. Note that `launchpad.37signals.com` is the only host previously
evidenced, and Basecamp auth is expected to need more.

- [ ] **Step 3: Report to the user**

Present the host list for approval before Task 7 writes it into settings. Guessed hosts
are explicitly rejected by the spec.

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
chezmoi apply ~/.claude/settings.json
```

In a fresh session verify **both**: an allowed request succeeds, and a non-allowlisted host
fails closed without prompting. Re-run each Task 6 workflow to confirm none regressed.

- [ ] **Step 6: Commit**

```bash
git add .scripts/test-claude-settings.sh dot_claude/modify_private_settings.json
git commit -m "fix(claude): enable deterministic egress

Adds allowedDomains from observed traffic and enables strictAllowlist in
the same change. Auto mode auto-approves sandbox network prompts and
accounts for 3083 of 3318 recorded messages, so prompting was not acting
as a control during unattended runs."
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
claude plugin list --json | jq -r '.[].name' | sort
```
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
claude plugin list --json | jq -r '.[].name' | sort
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

- [ ] All tests green: `bash .scripts/test-claude-settings.sh`,
      `bash .scripts/test-ssh-credential-inventory.sh`, `bash .scripts/test-reconcile-agents.sh`
- [ ] `chezmoi diff ~/.claude/settings.json` empty
- [ ] Spec updated to `**Status:** Implemented` with the merge reference
- [ ] Report to the user; **do not push** — pushing is the user's call
