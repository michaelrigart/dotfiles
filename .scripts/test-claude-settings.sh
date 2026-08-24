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
 "Read(**/*.pem)","Edit(**/*.pem)",
 "Bash(basecamp auth token*)"]'
EXP_ASK='["Read(~/.kube/config)","Edit(~/.kube/config)",
 "Edit(**/Dockerfile*)","Edit(**/docker-compose*.yml)",
 "Edit(**/.github/workflows/**)","Edit(**/.gitlab-ci.yml)",
 "Edit(**/.gitlab/ci/**)","Edit(**/terraform/**)","Edit(**/ansible/**)",
 "Bash(glab api *)","Bash(glab mr merge*)","Bash(sudo *)",
 "Bash(git push --force*)","Bash(git push -f *)","Bash(git reset --hard*)",
 "Bash(git clean -f*)","Bash(git branch -D*)","Bash(git filter-branch*)",
 "Bash(rm -rf ~/*)","Bash(rm -rf /Users/michael/*)",
 "Bash(rm -r ~/*)","Bash(rm -r /Users/michael/*)",
 "Bash(brew uninstall*)","Bash(brew remove*)","Bash(kubectl delete*)",
 "Bash(borg *)","Bash(vorta *)",
 "Bash(op item create*)","Bash(op item edit*)","Bash(op item delete*)",
 "Bash(docker rm*)","Bash(docker rmi*)","Bash(docker system prune*)",
 "Bash(docker volume rm*)","Bash(docker compose down*)"]'

jq_is "(.permissions.deny | sort) == ($EXP_DENY | sort)" true "deny array matches approved set exactly"
jq_is "(.permissions.ask  | sort) == ($EXP_ASK  | sort)" true "ask array matches approved set exactly"

# Belt and braces: every rule is a COMPLETE, closed form naming a tool we actually use.
jq_is '[.permissions.deny[], .permissions.ask[]
        | select(test("^(Read|Edit|Bash)\\([^)]+\\)$") | not)] | length' 0 \
      "every rule is a complete Read/Edit/Bash(spec) form"

# The allow list exists to stop prompting on read-only inspection of tools this machine
# actually drives (glab, chezmoi, basecamp). Its danger is not breadth but KIND: an
# interpreter, shell, or package-runner pattern is arbitrary code execution with the prompt
# removed, and a mutating verb silently approves writes. Both are pinned closed here rather
# than trusted to review. `mise exec` and `glab api` are deliberately absent — the first
# runs anything, the second can POST.
# The (?:[^ )]*/)? prefix matters: anchoring the interpreter at "Bash(" alone lets a
# path-qualified one through. A live rule "Bash(./.venv/bin/python -m pytest ...)" sat in
# ~/.claude/settings.local.json un-flagged until 2026-08-03 for exactly that reason.
jq_is '[.permissions.allow[]
        | select(test("^Bash\\((?:[^ )]*/)?(sudo|eval|exec|ssh|bash|sh|zsh|fish|python[0-9.]*|node|bun|deno|ruby|perl|php|lua|npx|bunx|uvx|mise|make|just|cargo|go)\\b"))]
       | length' 0 "no interpreter, shell, or package-runner is allowlisted"
jq_is '[.permissions.allow[]
        | select(test("\\b(create|delete|remove|rm|push|merge|apply|install|publish|close|edit|update|set)\\b"))]
       | length' 0 "no mutating verb is allowlisted"
# Bash(spec) or a single-host WebFetch(domain:host) — still a closed form. Widened
# 2026-08-24 when the launchpad.37signals.com rule (basecamp OAuth) moved here out of
# settings.local.json; anything looser would re-admit the unclosed-paren class of typo.
jq_is '[.permissions.allow[]
        | select(test("^Bash\\([^)]+\\)$") or test("^WebFetch\\(domain:[a-z0-9.-]+\\)$") | not)]
       | length' 0 \
      "every allow rule is a complete Bash(spec) or WebFetch(domain:host) form"
jq_is '.permissions.allow | index("Bash(glab api *)")' null \
      "glab api stays out — it is not read-only"

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
emit '{"enabledPlugins":{"x@y":true},"extraKnownMarketplaces":{"m":{}},"model":"opus[1m]","effortLevel":"xhigh","agentPushNotifEnabled":true,"inputNeededNotifEnabled":true}'
jq_is '.enabledPlugins["x@y"]' true       "enabledPlugins carried through"
jq_is '.extraKnownMarketplaces.m != null' true "extraKnownMarketplaces carried through"
jq_is '.model'                'opus[1m]'  "model carried through"
jq_is '.effortLevel'          'xhigh'     "effortLevel carried through"
# UI-set notification toggles. Dropped on every apply until 2026-08-24 because this script
# rebuilds the object and carries only a named whitelist; a key nobody listed just vanished.
jq_is '.agentPushNotifEnabled'  'true' "agentPushNotifEnabled carried through"
jq_is '.inputNeededNotifEnabled' 'true' "inputNeededNotifEnabled carried through"

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
# allowWrite exists so ordinary work (source trees, chezmoi source + its apply targets, the
# Obsidian vault) runs INSIDE the sandbox instead of escaping it — 24% of Bash calls were
# escaping, and every escape hit the ask-gate. Widening writes is not a credential decision:
# credentials.files and the Read/Edit denials outrank allowWrite, which section F above and
# test-live-credential-boundary.sh both pin. What must never appear here is an SSH, AWS, or
# op path — that would be a write exception over a denied credential.
jq_is '.sandbox.filesystem.allowWrite | length > 0' true "allowWrite is present so routine work stays sandboxed"
jq_is '[.sandbox.filesystem.allowWrite[]
        | select(test("(^|/)\\.ssh(/|$)") or test("(^|/)\\.aws(/|$)") or test("/op(/|$)"))]
       | length' 0 "no credential path is writable through allowWrite"
jq_is '.sandbox.filesystem.allowWrite | index("~") != null' false \
      "allowWrite is scoped, never all of \$HOME"

echo "G. layer 4 — escape routes"
emit '{}'
jq_is '.sandbox.excludedCommands | index("docker *") != null' true "docker excluded from sandbox"
jq_is '.sandbox.allowUnsandboxedCommands' true "escape hatch retained"
# The gate is on DANGER, not on mechanism. "Bash(dangerouslyDisableSandbox:true)" asked about
# how a command ran, not what it did: it fired on `git status` unsandboxed and stayed silent
# on `rm -rf` sandboxed. Measured over 30 days of transcripts on 2026-08-03 it produced 2497
# of 10834 Bash calls (23%, ~83/day) — and only 5 calls were ever actually denied. That volume
# is what trains a human to approve on reflex; the erosion it caused is section L's subject.
# The replacement set below fires 22 times over the same 30 days (~0.7/day), and every hit is
# genuinely irreversible. Rules stay content-scoped so they gate sandboxed commands too
# (docs: "content-scoped ask rules like Bash(git push *) still force a prompt even for
# sandboxed commands"). rm/rmdir against / or $HOME is separately gated by Claude Code itself.
jq_is '.permissions.ask | index("Bash(dangerouslyDisableSandbox:true)")' null \
      "the mechanism-based gate is gone — escaping the sandbox is not itself dangerous"
jq_is '.permissions.ask | index("Bash(docker *)")' null \
      "blanket docker gate is gone — read-only docker no longer prompts"
# rm -rf is pinned to LITERAL home paths on purpose. Rules match the command as written, and
# scratchpad/$TMPDIR cleanup never spells one: of ~154 rm -rf calls in 30 days, 110 targeted
# $TMPDIR/scratchpad and only 10 a real path. A blanket "Bash(rm -rf *)" would have re-created
# 107 of the prompts this change exists to remove.
for r in "Bash(git push --force*)" "Bash(git reset --hard*)" "Bash(rm -rf ~/*)" \
         "Bash(sudo *)" "Bash(borg *)" "Bash(op item edit*)"; do
  jq_is ".permissions.ask | index(\"$r\") != null" true "danger gate present: $r"
done
# Pin exactly, not by exclusion. Asserting "no docker socket" would still admit an
# arbitrary socket added later, and "contains docker *" would admit extra excluded
# commands — each a hole in the boundary this layer exists to draw.
jq_is '.sandbox.excludedCommands == ["docker *"]' true \
      "excludedCommands is exactly [\"docker *\"]"
jq_is ".sandbox.network.allowUnixSockets == [\"$AGENT_SOCKET\"]" true \
      "allowUnixSockets contains only the stable agent socket"

echo "H. layer 3 stays off until domains are known"
# Pinned exactly, not by containment: the point of an egress allowlist is that additions are
# deliberate. The package registries are here so dependency installs run sandboxed rather
# than escaping — the same reasoning as allowWrite. Note Little Snitch is a second,
# independent gate, so a domain here is necessary but not sufficient for egress.
EXP_DOMAINS='["gitlab.com","registry.gitlab.com","github.com","api.github.com","uploads.github.com","codeload.github.com","raw.githubusercontent.com","objects.githubusercontent.com","pkg-containers.githubusercontent.com","registry.npmjs.org","registry.yarnpkg.com","pypi.org","files.pythonhosted.org","rubygems.org","index.rubygems.org","index.crates.io","static.crates.io","crates.io","api.anthropic.com","formulae.brew.sh","ghcr.io","mise-versions.jdx.dev","cache.ruby-lang.org","www.ruby-lang.org","static.rust-lang.org","builds.dotnet.microsoft.com","dotnetcli.azureedge.net","login.microsoftonline.com","management.azure.com","graph.microsoft.com","teleport.viumore.com","teleport2.viumore.com","launchpad.37signals.com","3.basecampapi.com","basecamp3.basecampapi.com","3.basecamp.com","storage.3.basecamp.com","app.basecamp.com"]'
jq_is ".sandbox.network.allowedDomains == $EXP_DOMAINS" true \
      "egress allowlist is exactly the declared hosts and registries"
jq_is '[.sandbox.network.allowedDomains[] | select(test("^\\*") or . == "*")] | length' 0 \
      "no wildcard domain widens the allowlist"
# strictAllowlist is OFF, but NOT for the reason recorded here on 2026-08-03. That note said
# the preference was to be PROMPTED for an unknown host rather than blocked. There is no
# prompt: re-measured 2026-08-24 on 2.1.241, sandboxed `curl https://example.com` (not
# allowlisted) returned HTTP 200 silently, because autoAllowBashIfSandboxed suppresses the
# prompt that strictAllowlist=false would otherwise raise. So the real choice is
# silently-allow-anything vs block, and this list is decorative today. Little Snitch is the
# actual outbound gate.
#
# It was switched ON on 2026-08-24 and reverted the same hour. The revert was triggered by
# `git ls-remote` failing, which was MISATTRIBUTED to the flag — the real cause was the
# 1Password agent refusing to sign. Note for whoever retries: DNS (`dig`) and raw TCP to
# port 22 are blocked in this sandbox *either way*; git does not use them, it goes through
# the ssh-sandbox-proxy in GIT_SSH_COMMAND. So the open question is narrow — does the proxy
# still work under strictAllowlist? Test that with 1Password unlocked before flipping it.
# The widened allowlist below is kept regardless: it is harmless while the flag is off and
# it is what a future flip would need.
jq_is '.sandbox.network.strictAllowlist // false' false "strictAllowlist off — see comment; retest needs 1Password unlocked"

echo "J. defaultMode is seeded, not enforced"
# Runtime-mutable via /permissions, like model and effortLevel. Enforcing it would revert
# a deliberate plan-mode choice on every apply.
emit '{"permissions":{"defaultMode":"plan"}}'
jq_is '.permissions.defaultMode' 'plan'    "live defaultMode survives (plan preserved)"
emit '{"permissions":{"defaultMode":"acceptEdits"}}'
jq_is '.permissions.defaultMode' 'acceptEdits' "any live defaultMode survives"
emit '{}'
jq_is '.permissions.defaultMode' 'auto' "absent defaultMode seeded to auto"
# The seeding must not disturb the rules themselves.
emit '{"permissions":{"defaultMode":"plan"}}'
jq_is '.permissions.deny | length' 15 "deny rules intact when defaultMode carried"

echo "K. git SSH proxying rides CLAUDE_ENV_FILE, not the env block"
# Claude Code injects an unauthenticated `nc` GIT_SSH_COMMAND at runtime and that injection
# OVERRIDES the env block here, so a value there is accepted but never used — git runs the
# injected command and fails proxy auth. Claude Code runs CLAUDE_ENV_FILE as a script
# preamble before EVERY Bash command, i.e. after the injection, so a SessionStart hook
# writing the export there is what actually wins.
#
# The ~/.local/bin PATH assertion below checks the DECLARED value only; runtime resolution
# is covered by test-live-agent-auth.sh, which must run inside a Claude session.
#
# It previously claimed the zsh profile (brew shellenv) moves Homebrew ahead of ~/.local/bin,
# so the PATH-dependent git shim "never engaged". That was wrong. Measured in-session on
# 2026-07-31, sandboxed and unsandboxed alike, the effective PATH matches this declared
# env.PATH entry-for-entry and ~/.local/bin leads it — `command -v git` returned the shim,
# not Homebrew git. The profile does not reorder it. The shim was reachable and WAS entered,
# which is what broke three assertions in test-wt-functions.sh.
emit '{}'
jq_is '.env | has("GIT_SSH_COMMAND")' false \
      "GIT_SSH_COMMAND absent from env — the runtime overrides it there"
jq_is '.hooks.SessionStart[0].hooks[0].command
       | contains("CLAUDE_ENV_FILE") and contains("GIT_SSH_COMMAND") and contains("ssh-sandbox-proxy")' true \
      "SessionStart hook exports GIT_SSH_COMMAND to CLAUDE_ENV_FILE via the proxy helper"
jq_is '.env.SSH_AUTH_SOCK | endswith("/t/agent.sock")' true \
      "SSH_AUTH_SOCK points at the 1Password agent socket"
jq_is '.env.PATH | split(":") | index("\($ENV.HOME)/.local/bin") == 0' true \
      "~/.local/bin is first — so any executable there shadows system tools in-session"

echo "L. the allow guard covers UNMANAGED settings too"
# Sections A-H test the modify script's output, i.e. ~/.claude/settings.json only. But
# Claude Code merges permissions from ~/.claude/settings.local.json and every project
# .claude/settings*.json, and none of those pass through the modify script. Measured on
# 2026-08-03, that blind spot held five rules the guard above forbids — including
# "Bash(glab api *)" in two repos, the single rule section A pins closed by name. They get
# there by clicking "don't ask again", so this drifts on its own and needs a live check.
#
# Precedence (docs: "deny, then ask, then allow"; "a user-level deny blocks a project-level
# allow") means the managed ask rule already neutralises a local allow. This section is
# defence in depth: it keeps the local files honest so the managed rule is a backstop, not
# the only thing standing between a click and an allowlisted POST.
FORBID_KIND='^Bash\((?:[^ )]*/)?(sudo|eval|exec|ssh|bash|sh|zsh|fish|python[0-9.]*|node|bun|deno|ruby|perl|php|lua|npx|bunx|uvx|mise|make|just|cargo|go)\b'
FORBID_VERB='\b(create|delete|remove|rm|push|merge|apply|install|publish|close|edit|update|set)\b'
local_files=$(
  { ls "$HOME/.claude/settings.local.json" 2>/dev/null
    find "$HOME/Code" -maxdepth 4 -path '*/.claude/settings*.json' 2>/dev/null
  } | sort -u
)
offenders=""
for f in $local_files; do
  jq -e . "$f" >/dev/null 2>&1 || { offenders="$offenders$f: UNPARSEABLE"$'\n'; continue; }
  while IFS= read -r rule; do
    [ -n "$rule" ] && offenders="$offenders${f#$HOME/}: $rule"$'\n'
  done < <(jq -r --arg k "$FORBID_KIND" --arg v "$FORBID_VERB" '
      (.permissions.allow // [])[]
      | select(test($k) or test($v) or . == "Bash(glab api *)")' "$f" 2>/dev/null)
done
if [ -z "$offenders" ]; then
  _pass "no unmanaged allow rule defeats the managed guard"
else
  _fail "no unmanaged allow rule defeats the managed guard" "$(printf '%s' "$offenders" | tr '\n' '; ')"
fi

echo "M. no agent attribution reaches the published record"
emit '{}'
# `includeCoAuthoredBy: false` is NOT sufficient and was the actual 2026-08-24 bug: it is
# deprecated, and the claude.ai session link rides a SEPARATE `attribution.sessionUrl` gate,
# so MRs kept carrying a Claude-Session trailer while co-authorship was already off. Pin all
# three, and keep the deprecated key as the fallback for builds predating `attribution`.
jq_is '.attribution.sessionUrl' 'false' "session link suppressed (attribution.sessionUrl)"
jq_is '.attribution.commit'     ''      "commit attribution text empty"
jq_is '.attribution.pr'         ''      "PR attribution text empty"
jq_is '.includeCoAuthoredBy'    'false' "deprecated co-authored-by fallback still false"

echo "N. the forge guard is wired as a PreToolUse hook"
jq_is '.hooks.PreToolUse | length' 1 "exactly one PreToolUse entry"
jq_is '.hooks.PreToolUse[0].matcher' 'Bash' "matches the Bash tool"
jq_is '.hooks.PreToolUse[0].hooks[0].command' 'bash $HOME/.claude/git-forge-guard.sh' \
      'runs the forge guard, $HOME left for the shell to expand'
# The SessionStart hook must survive alongside it — adding PreToolUse replaced the whole
# hooks object once during development.
jq_is '.hooks.SessionStart | length' 1 "SessionStart hook still present"

echo "O. basecamp is allowlisted read-only"
# `basecamp auth token` prints the live OAuth token and `basecamp projects delete` trashes a
# project; both were pre-approved by the auto-learned `basecamp auth *` / `basecamp projects *`
# rules in settings.local.json until 2026-08-24.
jq_is '.permissions.deny | index("Bash(basecamp auth token*)") != null' true \
      "basecamp auth token is denied outright"
jq_is '[.permissions.allow[] | select(startswith("Bash(basecamp"))
        | select(test("(list|show|search|url|status)\\b") | not)] | length' 0 \
      "every allowlisted basecamp rule is a read-only verb"

echo "P. the network allowlist actually enforces"
emit '{}'
# Until 2026-08-24 this list was decorative: without strictAllowlist a non-listed host is
# merely prompted, and autoAllowBashIfSandboxed suppresses the prompt, so sandboxed
# `curl https://example.com` returned 200. It had reportedly been enabled once and was
# lost, because this block is declaratively owned and runtime-set keys inside it are
# erased on the next apply. This assertion is the thing that makes the loss loud.
# Spot-check the hosts whose absence breaks real work, not the whole list: forge, the
# runtime managers, Azure, the Teleport proxies that k8s access rides, and Basecamp.
for d in "gitlab.com" "github.com" "raw.githubusercontent.com" "formulae.brew.sh" \
         "mise-versions.jdx.dev" "static.rust-lang.org" "login.microsoftonline.com" \
         "teleport.viumore.com" "launchpad.37signals.com" "3.basecampapi.com"; do
  jq_is ".sandbox.network.allowedDomains | index(\"$d\") != null" true "allowlisted: $d"
done
# A denied-domains list would silently override the above, so pin that it stays unset.
jq_is '.sandbox.network.deniedDomains // "unset"' 'unset' "no deniedDomains rule shadowing the allowlist"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
