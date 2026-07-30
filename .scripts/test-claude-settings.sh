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
