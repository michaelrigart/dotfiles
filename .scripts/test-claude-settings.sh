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

echo "F. layer 2 — agent-backed credential isolation"
emit '{}'
AGENT_SOCKET="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
EXP_CREDENTIALS='[
  "~/.ssh/borg",
  "~/.ssh/borg-append-only",
  "~/.ssh/borg-append-only-fenrir",
  "~/.ssh/borg-config-michelangelo.tar.gz",
  "~/.ssh/borg-config-raphael.tar.gz",
  "~/.ssh/borg-fenrir",
  "~/.ssh/borg-hercules",
  "~/.ssh/borg-synology",
  "~/.ssh/huginn",
  "~/.ssh/michael",
  "~/.ssh/michael_rsa",
  "~/.ssh/viumore_rsa",
  "~/.aws/credentials",
  "~/.config/op/config"
]'
EXP_ALLOW_READ='[
  "~/.ssh/config",
  "~/.ssh/known_hosts",
  "~/.ssh/borg-append-only-fenrir.pub",
  "~/.ssh/borg-append-only.pub",
  "~/.ssh/borg-fenrir.pub",
  "~/.ssh/borg-hercules.pub",
  "~/.ssh/borg-synology.pub",
  "~/.ssh/borg.pub",
  "~/.ssh/huginn.pub",
  "~/.ssh/michael.pub",
  "~/.ssh/michael_rsa.pub",
  "~/.ssh/viumore_rsa.pub"
]'
jq_is '.env.SSH_AUTH_SOCK' "$AGENT_SOCKET" "Claude uses the stable 1Password agent socket"
jq_is '.env.PATH | split(":")[0]' "$HOME/.local/bin" "Claude resolves XDG executables first"
jq_is ".env.PATH | split(\":\") | index(\"$HOME/.local/share/mise/shims\") != null" true \
      "Claude PATH includes mise shims"
jq_is '.env.PATH | contains("/.codex/tmp/")' false "Claude PATH contains no session-local agent path"
jq_is ".sandbox.credentials.files
       | map(.path)
       | sort == ($EXP_CREDENTIALS | sort)" true \
      "credential path set matches the approved inventory exactly"
jq_is '[.sandbox.credentials.files[] | select(.mode != "deny")] | length' 0 \
      "every credential entry is mode deny"
jq_is '.sandbox.credentials | has("envVars")' false "phase 1 ships no envVars entries"
jq_is '[.sandbox.credentials.files[].path | select(startswith("~/.ssh/"))] | length' 12 \
      "12 ~/.ssh credential entries"
jq_is '[.sandbox.credentials.files[].path | select(endswith(".pub"))] | length' 0 \
      "no public keys denied as credentials"
jq_is ".sandbox.filesystem.allowRead | sort == ($EXP_ALLOW_READ | sort)" true \
      "only SSH metadata and public keys bypass the merged read denial"
jq_is '[.sandbox.filesystem.allowRead[]
        | select((endswith(".pub") or . == "~/.ssh/config" or . == "~/.ssh/known_hosts") | not)]
       | length' 0 "no private key path is readable through allowRead"
jq_is '.sandbox.filesystem | has("allowWrite")' false "no SSH write exception"

echo "G. layer 4 — escape routes"
emit '{}'
jq_is '.sandbox.excludedCommands | index("docker *") != null' true "docker excluded from sandbox"
jq_is '.sandbox.allowUnsandboxedCommands' true "escape hatch retained (ask-gated)"
jq_is '.permissions.ask | index("Bash(dangerouslyDisableSandbox:true)") != null' true \
      "unsandboxed retry is ask-gated"
jq_is '.permissions.ask | index("Bash(docker *)") != null' true "docker commands ask-gated"
# Pin exactly, not by exclusion. Asserting "no docker socket" would still admit an
# arbitrary socket added later, and "contains docker *" would admit extra excluded
# commands — each a hole in the boundary this layer exists to draw.
jq_is '.sandbox.excludedCommands == ["docker *"]' true \
      "excludedCommands is exactly [\"docker *\"]"
jq_is ".sandbox.network.allowUnixSockets == [\"$AGENT_SOCKET\"]" true \
      "allowUnixSockets contains only the stable agent socket"

echo "H. layer 3 stays off until domains are known"
jq_is '.sandbox.network.allowedDomains == ["gitlab.com"]' true \
      "observed GitLab host is pre-allowed"
jq_is '.sandbox.network.strictAllowlist // false' false "strictAllowlist off in this phase"

echo "J. defaultMode is seeded, not enforced"
# Runtime-mutable via /permissions, like model and effortLevel. Enforcing it would revert
# a deliberate plan-mode choice on every apply.
emit '{"permissions":{"defaultMode":"plan"}}'
jq_is '.permissions.defaultMode' 'plan'    "live defaultMode survives (plan preserved)"
emit '{"permissions":{"defaultMode":"acceptEdits"}}'
jq_is '.permissions.defaultMode' 'acceptEdits' "any live defaultMode survives"
emit '{}'
jq_is '.permissions.defaultMode' 'default' "absent defaultMode seeded to default"
# The seeding must not disturb the rules themselves.
emit '{"permissions":{"defaultMode":"plan"}}'
jq_is '.permissions.deny | length' 14 "deny rules intact when defaultMode carried"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
