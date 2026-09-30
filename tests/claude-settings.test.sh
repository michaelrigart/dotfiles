#!/usr/bin/env bash
# Feeds fixtures through dot_claude/modify_private_settings.json and asserts the emitted
# settings JSON. The modify script is a pure stdin->stdout filter, so this needs no chezmoi
# run and touches no deployed file. Run: ./tests/claude-settings.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$SRC/dot_claude/modify_private_settings.json"
[ -f "$MOD" ] || { echo "missing script under test: $MOD" >&2; exit 2; }
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
 "Bash(basecamp auth token*)",
 "Bash(op read*)","Bash(op item get*)","Bash(op document get*)","Bash(op inject*)","Bash(op run*)",
 "Bash(op items get*)","Bash(op documents get*)",
 "Bash(op --* read*)","Bash(op --* item get*)","Bash(op --* items get*)",
 "Bash(op --* document get*)","Bash(op --* inject*)","Bash(op --* run*)",
 "mcp__claude_ai_Microsoft_365__outlook_create_filter",
 "mcp__claude_ai_Microsoft_365__outlook_set_vacation"]'
# "Bash(glab api *)" is DELIBERATELY ABSENT — do not add it back. It gated the mechanism,
# not the danger: 156 fires in an 11-day window against 2 real rejections, every sampled
# call a read-only GET piped into jq. It could not be narrowed here either, because an ask
# rule is absolute (a PreToolUse hook returning allow loses to it — measured 2026-08-25).
# The write half is gated in git-forge-guard.sh rule 3, and git-forge-guard.test.sh pins
# both sides of that. See the header comment in the guard.
# Every Edit() rule is DELIBERATELY ABSENT — do not add one back. The infra gates
# (~/.kube/config, Dockerfile, docker-compose, GitHub/GitLab CI, terraform/, ansible/)
# prompted on every edit in every repo, this one included, and an ask rule is absolute:
# it cannot be narrowed from the hook side, because a PreToolUse hook returning allow
# loses to it. Removed 2026-09-03 in add55fa; the auto-mode classifier judges these now
# and the deny array still blocks the credential files outright. Section D pins their
# absence, for the same reason the note above pins `Bash(glab api *)`.
EXP_ASK='["Read(~/.kube/config)",
 "Bash(glab mr merge*)","Bash(sudo *)",
 "Bash(git reset --hard*)",
 "Bash(git clean -f*)","Bash(git branch -D*)","Bash(git filter-branch*)",
 "Bash(rm -rf ~/*)","Bash(rm -rf /Users/michael/*)",
 "Bash(rm -r ~/*)","Bash(rm -r /Users/michael/*)",
 "Bash(brew uninstall*)","Bash(brew remove*)","Bash(kubectl delete*)",
 "Bash(borg *)","Bash(vorta *)",
 "Bash(op item create*)","Bash(op item edit*)","Bash(op item delete*)",
 "Bash(docker rm*)","Bash(docker rmi*)","Bash(docker system prune*)",
 "Bash(docker volume rm*)","Bash(docker compose down*)",
 "mcp__claude_ai_Microsoft_365__outlook_batch_delete_messages",
 "mcp__claude_ai_Microsoft_365__outlook_trash_thread",
 "mcp__claude_ai_Microsoft_365__outlook_delete_event",
 "mcp__claude_ai_Microsoft_365__sharepoint_delete_item",
 "Bash(basecamp projects delete*)","Bash(basecamp chat delete*)",
 "Bash(basecamp todos trash*)","Bash(basecamp todolists trash*)",
 "Bash(basecamp messages trash*)","Bash(basecamp cards trash*)",
 "Bash(basecamp files trash*)","Bash(basecamp comments trash*)",
 "Bash(basecamp recordings trash*)","Bash(basecamp vaults trash*)",
 "Bash(basecamp docs trash*)","Bash(basecamp tools trash*)",
 "Bash(helm uninstall*)","Bash(helm delete*)",
 "Bash(az * delete -*)","Bash(az rest * DELETE*)","Bash(terraform destroy*)"]'

jq_is "(.permissions.deny | sort) == ($EXP_DENY | sort)" true "deny array matches approved set exactly"
jq_is "(.permissions.ask  | sort) == ($EXP_ASK  | sort)" true "ask array matches approved set exactly"

# Belt and braces: every rule is a COMPLETE, closed form naming a tool we actually use:
# Read/Edit/Bash(spec), or one MCP tool named in full (mcp__<server>__<tool>, no wildcard).
jq_is '[.permissions.deny[], .permissions.ask[]
        | select((test("^(Read|Edit|Bash)\\([^)]+\\)$") or test("^mcp__[A-Za-z0-9_]+__[A-Za-z0-9_]+$")) | not)] | length' 0 \
      "every rule is a complete Read/Edit/Bash(spec) form or a named MCP tool"

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

echo "D. layer 1 — the infra Edit() gates stay gone"
# These two used to assert the opposite. They were the loudest of the rules add55fa
# removed, so they are the ones most likely to be re-added by someone reasoning from
# "CI config is dangerous" without knowing what the prompt volume was. An ask rule is
# absolute; the danger these named is gated by the deny array and the auto-mode
# classifier, not by prompting on every edit.
for p in '~/.kube/config' '**/Dockerfile*' '**/docker-compose*.yml' \
         '**/.github/workflows/**' '**/.gitlab-ci.yml' '**/.gitlab/ci/**' \
         '**/terraform/**' '**/ansible/**'; do
  jq_is ".permissions.ask | index(\"Edit($p)\") == null" true "no Edit() ask rule for $p"
done

echo "E. carry-through keys survive"
emit '{"enabledPlugins":{"x@y":true},"extraKnownMarketplaces":{"m":{}},"model":"opus[1m]","effortLevel":"xhigh","agentPushNotifEnabled":true,"inputNeededNotifEnabled":true,"autoContinueAtUsageLimit":true}'
jq_is '.enabledPlugins["x@y"]' true       "enabledPlugins carried through"
jq_is '.extraKnownMarketplaces.m != null' true "extraKnownMarketplaces carried through"
jq_is '.model'                'opus[1m]'  "model carried through"
jq_is '.effortLevel'          'xhigh'     "effortLevel carried through"
# UI-set notification toggles. Dropped on every apply until 2026-08-24 because this script
# rebuilds the object and carries only a named whitelist; a key nobody listed just vanished.
jq_is '.agentPushNotifEnabled'  'true' "agentPushNotifEnabled carried through"
jq_is '.inputNeededNotifEnabled' 'true' "inputNeededNotifEnabled carried through"
# Same failure, found 2026-08-25 when auto-resume at the usage limit silently never fired.
# This one hides better than the notification toggles: the binary reads it as
# `?? true`, so once apply drops the key /config still SHOWS "true" while nothing is
# armed. Assert both directions — carried when present, never invented when absent.
jq_is '.autoContinueAtUsageLimit' 'true' "autoContinueAtUsageLimit carried through"
emit '{}'
jq_is '.autoContinueAtUsageLimit == null' true "autoContinueAtUsageLimit not invented when absent"

echo "E2. the merge starts from the live file: owned keys win, everything else survives"
# Until 2026-09-30 the script rebuilt the object and carried a named whitelist, so every
# runtime key nobody listed vanished on apply (modelSettings was the fourth). It now
# overlays the owned keys on the live file, so an UNKNOWN key must survive too.
emit '{"modelSettings":{"opus":{"x":1}},"someFutureKey":{"nested":[1,2]},"permissions":{"additionalDirectories":["/tmp/extra"],"allow":["Bash(stale-allow *)"],"ask":["Bash(stale-ask *)"],"deny":["Bash(stale-deny *)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"stale"}]}]},"sandbox":{"stale":true},"env":{"STALE":"1"},"cleanupPeriodDays":14,"includeCoAuthoredBy":true,"voiceEnabled":true,"disableAllHooks":true,"skipDangerousModePermissionPrompt":true,"apiKeyHelper":"curl evil","enabledMcpjsonServers":["evil"]}'
jq_is '.modelSettings.opus.x'              1      "modelSettings survives an apply"
jq_is '.someFutureKey.nested | length'     2      "an unknown future key survives an apply"
jq_is '.permissions.additionalDirectories[0]' /tmp/extra "a runtime permissions key survives"
jq_is '.permissions.allow | index("Bash(stale-allow *)")' null "a stale allow rule is replaced, never merged"
jq_is '.permissions.ask   | index("Bash(stale-ask *)")'   null "a stale ask rule is replaced, never merged"
jq_is '.permissions.deny  | index("Bash(stale-deny *)")'  null "a stale deny rule is replaced, never merged"
jq_is '.hooks | has("Stop")'               false  "owned hooks replace the live hooks wholesale"
jq_is '.sandbox | has("stale")'            false  "owned sandbox replaces the live sandbox wholesale"
jq_is '.env | has("STALE")'                false  "owned env replaces the live env wholesale"
jq_is '.cleanupPeriodDays'                 30     "cleanupPeriodDays is owned, and is 30"
jq_is 'has("includeCoAuthoredBy")'         false  "retired key includeCoAuthoredBy is deleted"
jq_is 'has("voiceEnabled")'                false  "retired key voiceEnabled is deleted"
jq_is '.disableAllHooks'                   false  "disableAllHooks is owned, and is false"
jq_is 'has("skipDangerousModePermissionPrompt")' false "posture-weakening key skipDangerousModePermissionPrompt is reset"
jq_is 'has("apiKeyHelper")'                false  "posture-weakening key apiKeyHelper is reset"
jq_is 'has("enabledMcpjsonServers")'       false  "posture-weakening key enabledMcpjsonServers is reset"
FIRST=$OUT
emit "$FIRST"
if [ "$(printf '%s' "$OUT" | jq -S .)" = "$(printf '%s' "$FIRST" | jq -S .)" ]; then
  _pass "a second apply changes nothing"
else
  _fail "a second apply changes nothing" "the second pass differs from the first"
fi
# Two JSON documents on stdin are refused, never merged into two objects.
out2=$(printf '%s' '{} {}' | /bin/bash "$MOD" 2>/dev/null); rc2=$?
if [ "$rc2" -ne 0 ] && [ -z "$out2" ]; then
  _pass "input holding two JSON documents is refused with no stdout"
else
  _fail "input holding two JSON documents is refused with no stdout" "rc=$rc2 stdout=$out2"
fi
# A live-sized file under the system bash. The empty-input check used to be a bash 3.2
# pattern substitution that took 8-40s on a real 13 KB settings.json.
emit '{}'; BIG=$OUT
start=$SECONDS
emit "$BIG"
if [ $((SECONDS - start)) -le 3 ]; then
  _pass "a live-sized settings file is processed in seconds by /bin/bash"
else
  _fail "a live-sized settings file is processed in seconds by /bin/bash" "$((SECONDS - start))s"
fi

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
# Go CLIs (glab, gh, tsh, terraform) cannot reach com.apple.trustd.agent from inside the
# sandbox, so chain verification never runs and every HTTPS call dies with
# `x509: OSStatus -26276`. SSL_CERT_FILE moves them onto file-based roots instead. Pinned
# because losing the key silently returns glab to "needs the sandbox off".
jq_is '.env.SSL_CERT_FILE' /etc/ssl/cert.pem \
      "Go TLS verification reads a root bundle instead of trustd"
if [ -s /etc/ssl/cert.pem ]; then
  _pass "the pinned root bundle exists on this machine"
else
  _fail "the pinned root bundle exists on this machine" "/etc/ssl/cert.pem missing or empty"
fi
# The weaker-isolation escape hatch fixes the same failure by opening trustd. Staying off
# is the point of setting SSL_CERT_FILE.
jq_is '.sandbox | has("enableWeakerNetworkIsolation")' false \
      "trustd stays closed — no enableWeakerNetworkIsolation"
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
# live-credential-boundary.test.sh both pin. What must never appear here is an SSH, AWS, or
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
for r in "Bash(terraform destroy*)" "Bash(git reset --hard*)" "Bash(rm -rf ~/*)" \
         "Bash(sudo *)" "Bash(borg *)" "Bash(op item edit*)"; do
  jq_is ".permissions.ask | index(\"$r\") != null" true "danger gate present: $r"
done
# Pin exactly, not by exclusion. Asserting "no docker socket" would still admit an
# arbitrary socket added later, and "contains docker *" would admit extra excluded
# commands — each a hole in the boundary this layer exists to draw.
#
# Four entries, each because the tool reaches a resource the sandbox blocks: docker its
# own socket, basecamp the macOS Keychain, herdr and xreview the herdr unix socket. The
# last three earn it for a second reason — sandboxed they return confident wrong answers
# rather than failing, so the "escalate only on sandbox evidence" rule has nothing to
# fire on. Adding a fifth entry should require the same justification, which is why this
# is pinned rather than open-ended.
jq_is '.sandbox.excludedCommands == ["docker *", "basecamp *", "herdr *", "xreview *"]' true \
      "excludedCommands is exactly the four socket/keychain tools"
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
# strictAllowlist ON since 2026-08-24, after the question was finally settled by measurement.
# The 2026-08-03 note kept it off to "be prompted rather than blocked". There is no prompt:
# autoAllowBashIfSandboxed suppresses it, so sandboxed curl to a non-allowlisted host just
# returned 200. The real choice was silently-allow-anything vs block.
#
# It was flipped on earlier the same day and reverted because `git ls-remote` failed. That
# was a MISDIAGNOSIS — the cause was the 1Password agent refusing to sign. Retested properly
# with a baseline first: with the flag ON, `git ls-remote` succeeds against both github and
# gitlab through the ssh-sandbox-proxy, while example.com is refused. git is unaffected.
#
# Two failures seen during that test are PRE-EXISTING and unrelated — verified by reproducing
# them with the flag off. `gh` and `glab` are Go binaries that reject the sandbox HTTPS
# proxy certificate (x509 OSStatus -26276) regardless of this setting; `gh` additionally
# cannot connect even unsandboxed because Little Snitch blocks it (ad-hoc signed binary,
# "connect: bad file descriptor" — same root cause as tsh/tctl). Do not blame this flag.
#
# The cost of ON is real: a host missing from EXP_DOMAINS is a failed command, not a prompt.
# Adding one is a two-line change here and in the modify script. Little Snitch stays the
# second, independent gate.
jq_is '.sandbox.network.strictAllowlist' true "strictAllowlist is on — non-allowlisted hosts are denied"

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
jq_is "(.permissions.deny | sort) == ($EXP_DENY | sort)" true "deny rules intact when defaultMode carried"

echo "K. git SSH proxying rides CLAUDE_ENV_FILE, not the env block"
# Claude Code injects an unauthenticated `nc` GIT_SSH_COMMAND at runtime and that injection
# OVERRIDES the env block here, so a value there is accepted but never used — git runs the
# injected command and fails proxy auth. Claude Code runs CLAUDE_ENV_FILE as a script
# preamble before EVERY Bash command, i.e. after the injection, so a SessionStart hook
# writing the export there is what actually wins.
#
# The ~/.local/bin PATH assertion below checks the DECLARED value only; runtime resolution
# is covered by live-agent-auth.test.sh, which must run inside a Claude session.
#
# It previously claimed the zsh profile (brew shellenv) moves Homebrew ahead of ~/.local/bin,
# so the PATH-dependent git shim "never engaged". That was wrong. Measured in-session on
# 2026-07-31, sandboxed and unsandboxed alike, the effective PATH matches this declared
# env.PATH entry-for-entry and ~/.local/bin leads it — `command -v git` returned the shim,
# not Homebrew git. The profile does not reorder it. The shim was reachable and WAS entered,
# which is what broke three assertions in wt-functions.test.sh.
emit '{}'
jq_is '.env | has("GIT_SSH_COMMAND")' false \
      "GIT_SSH_COMMAND absent from env — the runtime overrides it there"
jq_is '[.hooks.SessionStart[].hooks[].command
        | select(contains("CLAUDE_ENV_FILE") and contains("GIT_SSH_COMMAND") and contains("ssh-sandbox-proxy"))]
       | length' 1 \
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
# The managed ask rule used to neutralise a local allow. It is gone now (see EXP_ASK), so
# what actually stops a clicked-in "Bash(glab api *)" allow is git-forge-guard.sh rule 3 —
# and that holds: measured 2026-08-25, a hook returning permissionDecision=ask BEATS an
# allow rule, just as an ask rule beats a hook returning allow. Hooks can only tighten.
# This section stays as defence in depth: it keeps the local files honest so the hook is a
# backstop, not the only thing standing between a click and an allowlisted POST.
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
# three. The deprecated key itself is retired (spec 2026-09-30 section 4 item 2).
jq_is '.attribution.sessionUrl' 'false' "session link suppressed (attribution.sessionUrl)"
jq_is '.attribution.commit'     ''      "commit attribution text empty"
jq_is '.attribution.pr'         ''      "PR attribution text empty"
jq_is 'has("includeCoAuthoredBy")' 'false' "the deprecated includeCoAuthoredBy key is gone"

echo "N. every guard is wired exactly once, found by its command"
# Matched by COMMAND, not by list position: entries are added and removed over time, and
# a positional assertion silently retargets itself at whatever moved into the slot.
# hook_matchers <event> <command> -> the matchers of every entry running that command.
hook_matchers() {
  printf '%s' "$OUT" | jq -r --arg e "$1" --arg c "$2" \
    '[.hooks[$e][]? | select(any(.hooks[]?; .command == $c)) | .matcher] | map(tostring) | join(",")'
}
emit '{}'
for g in git-forge-guard worktree-guard xreview-guard path-resolution-guard; do
  got=$(hook_matchers PreToolUse "bash \$HOME/.claude/$g.sh")
  if [ "$got" = "Bash" ]; then _pass "$g runs once, on the Bash tool"; else _fail "$g runs once, on the Bash tool" "$got"; fi
done
# The apply-window guard inspects Edit/Write, so it must match every tool.
got=$(hook_matchers PreToolUse 'bash $HOME/.claude/xreview-apply-guard.sh')
if [ "$got" = "*" ]; then _pass "xreview-apply-guard runs once, on every tool"; else _fail "xreview-apply-guard runs once, on every tool" "$got"; fi
jq_is '.hooks.PreToolUse | length' 5 "no PreToolUse entry beyond the five guards"
# The forge guard shells out to glab, git and gitleaks (the push helper alone has a 30 s
# budget), so its hook limit is explicit rather than left to the runtime default.
jq_is '[.hooks.PreToolUse[].hooks[] | select(.command == "bash $HOME/.claude/git-forge-guard.sh") | .timeout] | join(",")' 60 \
      "the forge guard hook carries an explicit 60 s timeout"
# The SessionStart hooks must survive alongside them — adding PreToolUse replaced the
# whole hooks object once during development.
jq_is '.hooks.SessionStart | length' 2 "both SessionStart hooks present"
jq_is "[.hooks.SessionStart[] | select(.matcher == \"*\") | .hooks[]
        | select(.command == \"bash '$HOME/.claude/hooks/herdr-agent-state.sh' session\" and .timeout == 10)] | length" 1 \
      "the herdr agent-state hook: absolute path, session arg, installer matcher and timeout"

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

echo "Q. the safe-autonomy permission changes (spec section 1.3)"
emit '{}'
# The push asks are gone because an ask rule is absolute: a PreToolUse hook returning
# allow loses to it, so it could never let --force-with-lease through on a feature
# branch. git-forge-guard.sh rule 4 gates every push instead; do not add them back.
for r in "Bash(git push --force*)" "Bash(git push -f *)"; do
  jq_is ".permissions.ask | index(\"$r\")" null "no ask rule for $r - rule 4 of the forge guard owns pushes"
done
# chezmoi cat runs op unsandboxed and can render a private key; it is the classifier's call.
jq_is '.permissions.allow | index("Bash(chezmoi cat *)")' null "chezmoi cat is not allowlisted"
# Enumerated per resource, only for verbs the installed CLI has (checked with
# basecamp <res> --help): projects and chat delete, the rest trash. A comment body that
# merely says "delete" never matches.
for r in "projects delete" "chat delete" "todos trash" "todolists trash" "messages trash" \
         "cards trash" "files trash" "comments trash" "recordings trash" "vaults trash" \
         "docs trash" "tools trash"; do
  jq_is ".permissions.ask | index(\"Bash(basecamp $r*)\") != null" true "basecamp $r asks"
done
jq_is '[.permissions.ask[] | select(startswith("Bash(basecamp")
        and (test("^Bash\\(basecamp [a-z-]+ (trash|delete)\\*\\)$") | not))] | length' 0 \
      "every basecamp ask rule is exactly basecamp <resource> trash|delete*"
# az delete: a flag must follow, so free text never matches; az rest DELETE is covered.
jq_is '.permissions.ask | (index("Bash(az * delete -*)") != null) and (index("Bash(az rest * DELETE*)") != null) and (index("Bash(az * delete*)") == null)' true \
      "az delete needs a trailing flag, az rest DELETE asks"
# op: plural spellings and a leading global flag must not slip past the denies.
for r in "op items get*" "op documents get*" "op --* read*" "op --* item get*" "op --* items get*" \
         "op --* document get*" "op --* inject*" "op --* run*"; do
  jq_is ".permissions.deny | index(\"Bash($r)\") != null" true "op deny covers $r"
done

echo "X. every wired hook script is actually managed by chezmoi"
# A hook wired to an unmanaged path never deploys and fails open — silently inert.
# This is what a `.chezmoiignore` allowlist omission (task-3 fix-round-1) looks like:
# 41 guard tests, 83 settings tests, and three task reviews all stayed green while the
# hook pointed at a file chezmoi never deployed. Derive the hook list from the emitted
# settings rather than hardcoding it, so a future third hook is covered automatically.
if command -v chezmoi >/dev/null 2>&1; then
  managed=$(chezmoi --source "$SRC" managed 2>/dev/null)
  hooks=$(printf '%s' "$OUT" | jq -r '[.hooks[]?[]?.hooks[]?.command] | .[]' \
             | grep -o '\.claude/[A-Za-z0-9._/-]*\.sh' | sort -u)
  # An empty $hooks would make the loop below assert nothing at all — a silent
  # pass in the exact section that exists to catch a silently-inert hook wiring.
  # Fail loudly instead of skipping.
  if [ -z "$hooks" ]; then
    _fail "at least one PreToolUse hook script is wired" "no .claude/*.sh command found in emitted settings"
  else
    for f in $hooks; do
      case "$managed" in
        *"$f"*) _pass "hook script $f is chezmoi-managed" ;;
        *)      _fail "hook script $f is chezmoi-managed" "not in \`chezmoi managed\`" ;;
      esac
    done
  fi
else
  echo "  SKIP: chezmoi absent — hook-script management unverified"
fi

# --- agent definitions must declare a frontmatter name ----------------------
#
# An agent .md without a `name:` key does not register. Claude Code treats it as a
# co-located reference document and skips it silently — no warning, no parse error,
# the type simply is not in the Agent tool's list, and a dispatch fails with
# "Agent type 'x' not found". All three sp-* agents shipped that way and every
# dispatch to them fell back to general-purpose, losing the tier-matched effort
# these definitions exist to set. Verified 2026-09-01 with a named/unnamed probe
# pair: only the named probe appeared in a fresh session's agent list.
#
# The name must also equal the filename stem. The tool resolves a dispatch by the
# declared name, so a mismatch registers the agent under a name nothing calls.
for agent in "$SRC"/dot_claude/agents/*.md; do
  [ -e "$agent" ] || continue
  stem=$(basename "$agent" .md)
  declared=$(awk '/^---$/{n++; next} n==1 && /^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$agent")
  if [ -n "$declared" ]; then
    _pass "$stem declares a frontmatter name"
  else
    _fail "$stem declares a frontmatter name" "no name: key — this agent will not register"
  fi
  if [ "$declared" = "$stem" ]; then
    _pass "$stem's declared name matches its filename"
  else
    _fail "$stem's declared name matches its filename" "declared '$declared'"
  fi
  # The prompt-side half of the path-resolution guard. GLOBAL.md carries this rule, but
  # a subagent reaching for `cd` in a repo other than the session's showed it does not
  # reliably arrive — and its own definition is the one prompt it certainly reads.
  # Without this, path-resolution-guard.sh still stops the interruption, but every
  # subagent pays a denied call to learn the rule it should have started with.
  if grep -q 'Never open a Bash command with `cd`' "$agent"; then
    _pass "$stem carries the no-leading-cd rule"
  else
    _fail "$stem carries the no-leading-cd rule" "rule missing — every dispatch relearns it via a denied call"
  fi
done

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
