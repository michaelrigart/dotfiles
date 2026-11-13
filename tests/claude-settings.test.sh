#!/usr/bin/env bash
# Feeds fixtures through dot_claude/modify_private_settings.json and asserts the emitted
# settings JSON. The modify script is a pure stdin->stdout filter, so this needs no chezmoi
# run and touches no deployed file. Run: ./tests/claude-settings.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$SRC/dot_claude/modify_private_settings.json"
# plugins.conf is read only by absence checks, which a missing file would pass.
for f in "$MOD" "$SRC/dot_config/agents/plugins.conf"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0; OUT=""

_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '    | got: %s\n' "$2"; fail=$((fail + 1)); }
emit()  { OUT=$(printf '%s' "$1" | HOME="$HOME" /bin/bash "$MOD"); }
jq_is() { # jq_is <filter> <expected> <label>
  got=$(printf '%s' "$OUT" | jq -r "$1" 2>&1)
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$got"; fi
}

# The modify script asks op for the agent tokens, so every apply here runs with a stub op first on
# PATH: no suite may start the real one (unsandboxed it asks for Touch ID). The stub answers
# `item list --vault Private --format json` with $OP_ITEMS (default []) or fails when OP_DOWN=1,
# and `read op://Private/<title>/token` with $OP_GH or $OP_GL, or fails when OP_READ_FAIL=1;
# any other call is logged and exits 99. The jq shim logs its argv, so a token that ever reached
# a command line would show in the log.
# The first jq that is not a mise shim: a shim exec-ed through the logging shim resolves back to it.
REAL_JQ=$(type -ap jq | grep -v '/shims/' | head -1); REAL_JQ=${REAL_JQ:-/usr/bin/jq}
OPD="$(mktemp -d "${TMPDIR:-/tmp}/claude-settings-op.XXXXXX")"; trap 'rm -rf "$OPD" "${MT:-}"' EXIT
export OP_LOG="$OPD/op.log" JQ_LOG="$OPD/jq.log"
: > "$OP_LOG"; : > "$JQ_LOG"
cat > "$OPD/op" <<'STUB'
#!/bin/sh
if [ "$*" = "item list --vault Private --format json" ]; then
  [ "${OP_DOWN:-}" = 1 ] && exit 1
  printf '%s' "${OP_ITEMS:-[]}"; exit 0
fi
if [ "$1" = read ]; then
  [ "${OP_READ_FAIL:-}" = 1 ] && exit 1
  case "$2" in
    "op://Private/GitHub Agent Token/token") printf '%s\n' "$OP_GH"; exit 0 ;;
    "op://Private/GitLab Agent Token/token") printf '%s\n' "$OP_GL"; exit 0 ;;
  esac
fi
echo "$*" >> "$OP_LOG"; exit 99
STUB
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$JQ_LOG"\nexec "%s" "$@"\n' "$REAL_JQ" > "$OPD/jq"
chmod 755 "$OPD/op" "$OPD/jq"
mkdir "$OPD/noop"; ln -s "$OPD/jq" "$OPD/noop/jq"
PATH="$OPD:$PATH"
unset OP_ITEMS OP_DOWN OP_READ_FAIL OP_GH OP_GL

echo "A. layer 1 — permission rules match the approved set exactly"
emit '{}'

# Exact-array comparison, not a shape heuristic. A prefix/regex check would accept a typo
# like "Raed(~/.ssh/**)" or an unclosed "Typo(" and report green while the rule is inert —
# the same class of silent failure being repaired.
EXP_DENY='["Read(~/.ssh/**)","Edit(~/.ssh/**)",
 "Read(~/.aws/credentials)","Edit(~/.aws/credentials)",
 "Read(~/.config/op/config)","Edit(~/.config/op/config)",
 "Read(~/.config/ha-mcp/**)","Edit(~/.config/ha-mcp/**)",
 "Read(~/.config/unifi-network/**)","Edit(~/.config/unifi-network/**)",
 "Read(~/.config/bundler/**)","Edit(~/.config/bundler/**)",
 "Read(**/secrets.*.yml)","Edit(**/secrets.*.yml)",
 "Read(**/.env.production*)","Edit(**/.env.production*)",
 "Read(**/*.key)","Edit(**/*.key)",
 "Read(**/*.pem)","Edit(**/*.pem)",
 "Bash(basecamp auth token*)",
 "Read(~/.local/share/tagteam/rescue/**)","Edit(~/.local/share/tagteam/rescue/**)",
 "Read(~/.local/share/tagteam/displaced/**)","Edit(~/.local/share/tagteam/displaced/**)",
 "Read(~/.local/share/tagteam/sessions/*/.credentials.json)","Edit(~/.local/share/tagteam/sessions/*/.credentials.json)",
 "Bash(tagteam *export*)",
 "Bash(gh gist create*)","Bash(gh gist edit*)","Bash(gh repo create*)","Bash(glab repo create*)",
 "Bash(glab snippet create*)","Bash(gh api *gists*)","Bash(glab api *snippets*)",
 "Bash(gh gist new*)","Bash(gh repo new*)","Bash(glab snippet new*)","Bash(glab project create*)",
 "Bash(glab stack*)","Bash(gh agent-task create*)","Bash(az repos pr update*)",
 "Bash(gh agent create*)","Bash(gh agents create*)","Bash(gh agent-tasks create*)",
 "Bash(security *find-generic-password*)","Bash(/usr/bin/security *find-generic-password*)",
 "Bash(security *find-internet-password*)","Bash(/usr/bin/security *find-internet-password*)",
 "Bash(security *dump-keychain*)","Bash(/usr/bin/security *dump-keychain*)",
 "Bash(security *export*)","Bash(/usr/bin/security *export*)",
 "Bash(op read*)","Bash(op item get*)","Bash(op document get*)","Bash(op inject*)","Bash(op run*)",
 "Bash(op items get*)","Bash(op documents get*)",
 "Bash(op --* read*)","Bash(op --* item get*)","Bash(op --* items get*)",
 "Bash(op --* document get*)","Bash(op --* documents get*)","Bash(op --* inject*)","Bash(op --* run*)",
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
 "Bash(az * delete -*)","Bash(az rest * DELETE*)","Bash(terraform destroy*)",
 "Bash(terraform -chdir=* destroy*)","Bash(terraform apply -destroy*)",
 "Bash(terraform -chdir=* apply -destroy*)"]'

jq_is "(.permissions.deny | sort) == ($EXP_DENY | sort)" true "deny array matches approved set exactly"
jq_is "(.permissions.ask  | sort) == ($EXP_ASK  | sort)" true "ask array matches approved set exactly"

# Belt and braces: every rule is a COMPLETE, closed form naming a tool we actually use:
# Read/Edit/Bash(spec), or one MCP tool named in full (mcp__<server>__<tool>, no wildcard).
jq_is '[.permissions.deny[], .permissions.ask[]
        | select((test("^(Read|Edit|Bash)\\([^)]+\\)$") or test("^mcp__[A-Za-z0-9_]+__[A-Za-z0-9_]+$")) | not)] | length' 0 \
      "every rule is a complete Read/Edit/Bash(spec) form or a named MCP tool"

# The allow list exists to stop prompting on read-only inspection of tools this machine
# actually drives (glab, basecamp). Its danger is not breadth but KIND: an
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
# sdd-clean is the one allowlisted command that deletes: it refuses anything but a
# git-ignored .superpowers/sdd/<plan> workspace (tests/sdd-clean.test.sh pins that).
jq_is '.permissions.allow | index("Bash(sdd-clean *)") != null' true \
      "sdd-clean is allowlisted, so a finished plan's cleanup needs no prompt"
# No chezmoi rule at all (spec 2026-10-28-reload-functions-merged-deletes, section 2): even
# the exact chezmoi diff and chezmoi status run the modify_ scripts and templates of the
# writable source, and an allow rule applies only unsandboxed, so it would run code an agent
# wrote with no classifier.
jq_is '[.permissions.allow[] | select(startswith("Bash(chezmoi"))] | length' 0 \
      "no allow rule starts with Bash(chezmoi"
# No git push or fetch rule: a merged-branch delete goes to the classifier, whose autoMode
# rule (section U) lets it allow the plain pinned delete the push guard has verified, and a
# plain git fetch already prunes (fetch.prune=true).
jq_is '[.permissions.allow[] | select(startswith("Bash(git push") or startswith("Bash(git fetch"))] | length' 0 \
      "no allow rule starts with Bash(git push or Bash(git fetch"
# No allow rule matches a git push in any form (spec 2026-10-28-reload-functions-merged-
# deletes, section 2: every push the guard leaves silent reaches the classifier). A model of
# Claude Code's matching: the whole command text; * is any text, spaces included; a trailing
# " *" that is the rule's only * also matches the bare command; the legacy trailing ":*" is a
# prefix, read as " *".
MATCHES='def esc: gsub("(?<c>[.+?()\\[\\]{}|^$\\\\])"; "\\" + .c);
  def hit($cmd): (.[5:-1] | if endswith(":*") then .[:-2] + " *" else . end) as $s
    | ($s | esc | gsub("\\*"; ".*")) as $re
    | ($cmd | test("^" + $re + "$"))
      or (($s | endswith(" *")) and (($s | split("*") | length) == 2) and ($cmd == $s[:-2]));'
n_match() { # n_match <command> -> how many allow rules match it
  printf '%s' "$OUT" | jq -r --arg c "$1" "$MATCHES"' [.permissions.allow[] | select(startswith("Bash(")) | select(hit($c))] | length'
}
d_match() { # d_match <command> -> how many deny rules match it
  printf '%s' "$OUT" | jq -r --arg c "$1" "$MATCHES"' [.permissions.deny[] | select(startswith("Bash(")) | select(hit($c))] | length'
}
d_is() { # d_is <command> <yes|no> <label>
  got=$(d_match "$1")
  if [ "$2" = yes ] && [ "$got" -ge 1 ]; then _pass "$3"; elif [ "$2" = no ] && [ "$got" = 0 ]; then _pass "$3"; else _fail "$3" "$got"; fi
}
m_is() { # m_is <command> <expected count> <label>
  got=$(n_match "$1")
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$got"; fi
}
for c in 'gh gist create notes.md' 'gh gist edit 1234' 'gh repo create x --public --source .' \
         'glab repo create x' 'glab snippet create -t t f.txt' 'gh api gists' \
         'gh api -X POST /gists -f description=x' 'glab api projects/1/snippets' 'glab api -X POST snippets' \
         'gh gist new notes.md' 'gh repo new x --public' 'glab snippet new -t t f.txt' \
         'glab project create x --public'; do
  d_is "$c" yes "a deny rule matches: $c"
done
for c in 'gh repo view' 'gh gist list' 'gh api repos/o/r/pulls' 'glab api projects/1/merge_requests'; do
  d_is "$c" no "no deny rule matches: $c"
done
# Calibrate the model on a fixture before trusting it on the real rules.
FIX_SAVE=$OUT
OUT='{"permissions":{"allow":["Bash(git *)","Bash(git push *)","Bash(git log * main)","Bash(ls:*)"]}}'
m_is 'git -C /r push origin --delete b' 1 "model: 'git *' matches a -C push"
m_is 'git push' 2 "model: 'git *' and 'git push *' both match a bare git push"
m_is 'git log --oneline main' 2 "model: 'git log * main' and 'git *' match 'git log --oneline main'"
m_is 'gitk' 0 "model: no rule matches gitk"
m_is 'ls' 1 "model: legacy 'ls:*' matches bare 'ls'"
m_is 'ls -la' 1 "model: legacy 'ls:*' matches 'ls -la'"
m_is 'lsof' 0 "model: legacy 'ls:*' does not match 'lsof'"
OUT=$FIX_SAVE
SHA=0123456789abcdef0123456789abcdef01234567
for c in 'git push' 'git push origin main' "git push --force-with-lease=b:$SHA origin --delete b" \
         "git push --force-with-lease=refs/heads/b:$SHA origin --delete b" 'git push origin :refs/heads/b' \
         'git push -d origin b' 'git push --force origin main' 'git push --dry-run origin x' \
         "git push --force-with-lease=b:$SHA origin --delete b 2>&1 | tail -n 3" \
         'git -C /r push origin --delete b' 'git --no-pager push origin x' 'git -c a=b push origin x' \
         'git -C /r -c a=b --no-pager push origin x' '/usr/bin/git push origin x' 'command git push origin x' \
         'env git push origin x' 'xargs git push origin x' 'nohup git push origin x' 'timeout 9 git push origin x'; do
  m_is "$c" 0 "no allow rule matches: $c"
done
jq_is '[.permissions.allow[] | select(test("\\*.*:\\*\\)$"))] | length' 0 \
      "no allow rule ends in :* with another * before it"
# No * before the subcommand: Claude Code warns on such a rule, since for git a -c or
# --exec-path in it runs any command (spec 2026-10-28-reload-functions-merged-deletes, Tests:
# the general checks stay). The words up to the
# subcommand are the first word, any words starting with -, then the first other word; a *
# in any of them fails, bar a lone * argument list right after the command name (sdd-clean *).
jq_is '[.permissions.allow[] | select(startswith("Bash("))
        | .[5:-1] | [splits(" +")] | map(select(. != "")) as $w
        | ([range(1; $w | length) | select($w[.] | startswith("-") | not)] | first // ($w | length)) as $k
        | select(($w[0:$k + 1] | any(contains("*")))
                 and (($k == 1 and ($w | length) == 2 and $w[1] == "*") | not))]
       | length' 0 "no allow rule has a * before its subcommand"
# Hooks and the statusline run outside the sandbox: their interpreter is named by absolute
# path, so nothing on PATH can stand in for it (spec 2026-10-16, section 2).
jq_is '[.hooks[][]?.hooks[]?.command, .statusLine.command
        | select(test("^(bash|sh|zsh|python3?) "))] | length' 0 \
      "no hook or statusline command starts with a bare interpreter"
jq_is '[.hooks[][]?.hooks[]?.command, .statusLine.command
        | select(test("\\.(sh|py)\\b")) | select(startswith("/opt/homebrew/bin/bash ") | not)] | length' 0 \
      "every hook and statusline script runs under /opt/homebrew/bin/bash"

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

# Opus 5.5 and later ignore the top-level effortLevel; /effort saves to modelSettings.<id>.
# Default-only like effortLevel: a fresh machine starts at xhigh, a runtime value persists.
emit '{}'
jq_is '.modelSettings["claude-opus-5-5"].effortLevel' 'xhigh' "opus-5-5 effort seeded to xhigh when absent"
# Default-only: render a fresh file, apply the runtime /effort change to the rendered
# output, render again; the changed value must survive the second apply.
seeded=$(printf '%s' "$OUT" | jq -r '.modelSettings["claude-opus-5-5"].effortLevel' 2>&1)
emit "$(printf '%s' "$OUT" | jq -c '.modelSettings["claude-opus-5-5"].effortLevel = "medium"')"
jq_is '"'"$seeded"'" + ">" + .modelSettings["claude-opus-5-5"].effortLevel' 'xhigh>medium' "opus-5-5 effort: seeded xhigh, then a runtime change to medium persists"
# Both halves in one comparison: the seed lands AND the sibling entry and sibling key survive.
emit '{"modelSettings":{"other-model":{"effortLevel":"low"},"claude-opus-5-5":{"autoCompactWindow":123}}}'
want='{"other-model":{"effortLevel":"low"},"claude-opus-5-5":{"autoCompactWindow":123,"effortLevel":"xhigh"}}'
got=$(printf '%s' "$OUT" | jq -S -c '.modelSettings' 2>&1)
if [ "$got" = "$(printf '%s' "$want" | jq -S -c .)" ]; then _pass "modelSettings is seeded and otherwise kept whole"
else _fail "modelSettings is seeded and otherwise kept whole" "$got"; fi
# A runtime-written map of the wrong type must not stop the apply (jq exit 5, no output):
# it is replaced by an object, like the other guarded maps.
for bad in '"x"' '[]' '5' 'false'; do
  if OUT=$(printf '%s' "{\"modelSettings\":$bad}" | HOME="$HOME" /bin/bash "$MOD"); then rc=0; else rc=$?; fi
  jq_is '.modelSettings["claude-opus-5-5"].effortLevel' 'xhigh' "modelSettings $bad renders (exit $rc) and seeds xhigh"
done
for bad in '"x"' '[1]' '7' 'false'; do
  if OUT=$(printf '%s' "{\"modelSettings\":{\"claude-opus-5-5\":$bad}}" | HOME="$HOME" /bin/bash "$MOD"); then rc=0; else rc=$?; fi
  jq_is '.modelSettings["claude-opus-5-5"].effortLevel' 'xhigh' "opus-5-5 entry $bad renders (exit $rc) and seeds xhigh"
done

echo "E2. the merge starts from the live file: owned keys win, everything else survives"
# Until 2026-09-30 the script rebuilt the object and carried a named whitelist, so every
# runtime key nobody listed vanished on apply (modelSettings was the fourth). It now
# overlays the owned keys on the live file, so an UNKNOWN key must survive too.
emit '{"modelSettings":{"opus":{"x":1}},"someFutureKey":{"nested":[1,2]},"permissions":{"additionalDirectories":["/tmp/extra"],"allow":["Bash(stale-allow *)"],"ask":["Bash(stale-ask *)"],"deny":["Bash(stale-deny *)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"stale"}]}]},"sandbox":{"stale":true},"env":{"STALE":"1"},"cleanupPeriodDays":14,"includeCoAuthoredBy":true,"voiceEnabled":true,"disableAllHooks":true,"skipDangerousModePermissionPrompt":true,"apiKeyHelper":"curl evil","enabledMcpjsonServers":["evil"],"awsAuthRefresh":"curl evil","awsCredentialExport":"curl evil","gcpAuthRefresh":"curl evil","otelHeadersHelper":"curl evil"}'
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
for k in awsAuthRefresh awsCredentialExport gcpAuthRefresh otelHeadersHelper; do
  jq_is "has(\"$k\")"                      false  "posture-weakening key $k is reset"
done
FIRST=$OUT
emit '{"env":{"ANTHROPIC_BASE_URL":"https://x.example","ANTHROPIC_API_KEY":"k","OPENAI_BASE_URL":"https://y.example"}}'
jq_is '[.env | keys[] | select(startswith("ANTHROPIC_"))] | length' 0 "live ANTHROPIC_* env keys never survive an apply"
emit '{}'
jq_is '[.env | keys[] | select(startswith("ANTHROPIC_"))] | length' 0 "the owned env carries no ANTHROPIC_* key"
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
  "~/.config/op/config",
  "~/.config/ha-mcp/env",
  "~/.config/ha-mcp/env-remote",
  "~/.config/unifi-network/env",
  "~/.config/bundler/config"
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
  "~/.ssh/viumore_rsa.pub",
  "~/.ssh/github-agent.pub"
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
jq_is '.sandbox.enabled' true \
      "the sandbox ships enabled — a template with it off would pass every other check"
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
jq_is '[.sandbox.credentials.files[].path | select(endswith(".pub"))] | length' 0 \
      "no public keys denied as credentials"
jq_is ".sandbox.filesystem.allowRead | sort == ($EXP_ALLOW_READ | sort)" true \
      "only SSH metadata and public keys bypass the merged read denial"
jq_is '[.sandbox.filesystem.allowRead[]
        | select((endswith(".pub") or . == "~/.ssh/config" or . == "~/.ssh/known_hosts") | not)]
       | length' 0 "no private key path is readable through allowRead"
# allowWrite keeps ordinary work sandboxed: source trees, the chezmoi source, documents and
# the vault; a wt sibling is written only by its own session's working-directory grant.
# ~/.config and ~/.local/bin are out (spec 2026-10-16, sandbox write boundary): what is
# written there runs later outside the sandbox — shells, git, mise, herdr, the
# hooks, the excluded commands. Credential denials still outrank allowWrite.
EXP_ALLOW_WRITE='["~/Code","~/.local/share/chezmoi","~/Documents","~/Library/Mobile Documents/iCloud~md~obsidian"]'
jq_is ".sandbox.filesystem.allowWrite == $EXP_ALLOW_WRITE" true \
      "allowWrite is exactly the four work roots"
# denyWrite: in each work root, at any depth, git hooks and git configuration (also inside
# submodules and linked worktrees); the chezmoi checkout's own top-level .git/hooks; each wt
# sibling's top-level .git; the vault's
# .obsidian; and the agent configuration (.claude/settings*.json, .mcp.json, .codex) at
# depth 0, 1 and 2 under each root only: never at any depth, because node_modules packages
# ship such files (resolve@1.22.12 has a .claude/settings.local.json) and a deny there
# breaks sandboxed npm ci. Claude Code harness worktrees (<repo>/.claude/worktrees/<name>)
# get three fixed-depth forms per path, <root>/.claude/worktrees/*/<p> (a root that is itself
# a repository), <root>/*/.claude/worktrees/*/<p> and <root>/*/*/.claude/worktrees/*/<p>,
# which cannot match inside node_modules. Git configuration and commondir are denied in
# every root (spec 2026-10-30 section 1), including the git directory of a submodule of a
# linked worktree (.git/worktrees/*/modules/**, amended 2026-10-30); .git is denied at ~/Code,
# at ~/Documents, anywhere in the vault, and as a harness worktree .git file (section 2), and
# so is a HEAD that would make a root, the vault or an organisation directory a fake bare
# repository (amended 2026-10-30). Objects, refs, the index and $TMPDIR stay writable, except refs named lazygit.yml and, in a
# submodule, names starting with config or named hooks or commondir (suites and agents git init there). Michael decided hooks for
# git (spec 83f6b2b) and the agent configuration on 2026-10-18; .claude/skills, commands and
# agents stay writable (projects commit their own).
GITFILES='[".git/hooks",".git/hooks/**",".git/modules/**/hooks",".git/modules/**/hooks/**"]'
GITCONF='[".git/config*",".git/commondir",".git/worktrees/*/config*",".git/worktrees/*/commondir",".git/modules/**/config*",".git/modules/**/commondir"]'
GITWTMOD='[".git/worktrees/*/modules/**/config*",".git/worktrees/*/modules/**/commondir",".git/worktrees/*/modules/**/hooks"]'
TOOLCONF='[".lazygit.yml",".git/**/lazygit.yml",".git/glab-cli/config.yml",".git/worktrees/*/glab-cli/config.yml"]'
AGENTFILES='[".claude/settings.json",".claude/settings.local.json",".mcp.json",".codex",".codex/**"]'
ROOTS='["~/Code","~/.local/share/chezmoi","~/.local/share/chezmoi-*","~/Documents","~/Library/Mobile Documents/iCloud~md~obsidian"]'
EXP_DENY_WRITE=$(jq -cn --argjson g "$GITFILES" --argjson c "$GITCONF" --argjson w "$GITWTMOD" --argjson t "$TOOLCONF" --argjson a "$AGENTFILES" --argjson r "$ROOTS" '
  [$r[] as $root | $g[] | "\($root)/**/\(.)"]
  + [$g[] | "~/.local/share/chezmoi/\(.)"]
  + [$r[] as $root | $c[] | "\($root)/**/\(.)"]
  + [$r[] as $root | $w[] | "\($root)/**/\(.)"]
  + [$r[] as $root | $a[] | "\($root)/\(.)", "\($root)/*/\(.)", "\($root)/*/*/\(.)",
                                        "\($root)/.claude/worktrees/*/\(.)", "\($root)/*/.claude/worktrees/*/\(.)",
                                        "\($root)/*/*/.claude/worktrees/*/\(.)"]
  + [$r[] as $root | "\($root)/.claude/worktrees/*/.git", "\($root)/*/.claude/worktrees/*/.git", "\($root)/*/*/.claude/worktrees/*/.git"]
  + ["~/Code/.git", "~/Documents/.git", "~/Library/Mobile Documents/iCloud~md~obsidian/**/.git", "~/.local/share/chezmoi-*/.git"]
  + ["~/Code/HEAD", "~/Documents/HEAD", "~/Library/Mobile Documents/iCloud~md~obsidian/**/HEAD", "~/Code/*/HEAD"]
  + [$r[] as $root | $t[] | "\($root)/**/\(.)"]
  + ["~/Library/Mobile Documents/iCloud~md~obsidian/Documents/*/.obsidian",
     "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/*/.obsidian/**"]')
jq_is ".sandbox.filesystem.denyWrite == $EXP_DENY_WRITE" true \
      "denyWrite is exactly the git hooks and configuration, the misplaced .git and HEAD entries, the lazygit and glab configuration, the agent configuration in each work root, and .obsidian"
jq_is "[.sandbox.filesystem.denyWrite[] | . as \$d
        | select(any($ROOTS[]; . as \$r | \$d | startswith(\$r + \"/\")) | not)] | length" 0 \
      "every deny glob starts with a work root and a slash, so git init in TMPDIR still works"
jq_is '[.sandbox.filesystem.denyWrite[] | select(test("/refs|/objects|/index$"))] | length' 0 \
      "no deny glob reaches refs, objects or the index"
jq_is '[.sandbox.filesystem.denyWrite[] | select((test("/\\.git/") or test("/\\.obsidian(/|$)")
        or test("/\\.git$") or test("/HEAD$") or test("/\\.lazygit\\.yml$")
        or test("/\\.claude/settings(\\.local)?\\.json$") or test("/\\.mcp\\.json$") or test("/\\.codex(/\\*\\*)?$")) | not)] | length' 0 \
      "every deny glob names a git path, a fake-repository HEAD, a lazygit file, .obsidian or an agent configuration file"
jq_is '[.sandbox.filesystem.denyWrite[] | select(test("/\\.claude/(skills|commands|agents)"))] | length' 0 \
      "no deny glob reaches .claude skills, commands or agents"
jq_is ".sandbox.filesystem.denyWrite as \$d | [$ROOTS[] as \$r | $AGENTFILES[] as \$p
        | (\$r + \"/\" + \$p, \$r + \"/*/\" + \$p, \$r + \"/*/*/\" + \$p)
        | select(. as \$e | \$d | index(\$e) | not)] | length" 0 \
      "every agent configuration path is denied at depth 0, 1 and 2 in all five roots"
jq_is ".sandbox.filesystem.denyWrite as \$d | [$ROOTS[] as \$r | $AGENTFILES[] as \$p
        | (\$r + \"/.claude/worktrees/*/\" + \$p, \$r + \"/*/.claude/worktrees/*/\" + \$p, \$r + \"/*/*/.claude/worktrees/*/\" + \$p)
        | select(. as \$e | \$d | index(\$e) | not)] | length" 0 \
      "every agent configuration path has all three harness worktree forms in all five roots"
GITNINE=$(jq -cn --argjson a "$GITCONF" --argjson b "$GITWTMOD" '$a + $b')
jq_is ".sandbox.filesystem.denyWrite as \$d | [$ROOTS[] as \$r | $GITNINE[] as \$c
        | \"\(\$r)/**/\(\$c)\" | select(. as \$e | \$d | index(\$e) | not)] | length" 0 \
      "each work root denies all nine git configuration forms, three of them for a submodule of a linked worktree"
jq_is '[.sandbox.filesystem.denyWrite[] | select(test("config\\*$"))
        | select(test("/\\.git/(worktrees/\\*/(modules/\\*\\*/)?|modules/\\*\\*/)?config\\*$") | not)] | length' 0 \
      "every config* entry sits directly in a git directory, a linked worktree'"'"'s, a submodule'"'"'s or a linked worktree'"'"'s submodule'"'"'s"
jq_is ".sandbox.filesystem.denyWrite as \$d | [$ROOTS[] as \$r | $TOOLCONF[] as \$c
        | \"\(\$r)/**/\(\$c)\" | select(. as \$e | \$d | index(\$e) | not)] | length" 0 \
      "each work root denies all four per-repository lazygit and glab configuration forms"
jq_is '[.sandbox.filesystem.denyWrite[] | select(test("glab-cli"))] | map(select((endswith("/.git/glab-cli/config.yml") or endswith("/.git/worktrees/*/glab-cli/config.yml")) | not)) | length' 0 \
      "the only glab entry shapes are .git/glab-cli/config.yml and .git/worktrees/*/glab-cli/config.yml, so recover files stay writable"
jq_is '[.sandbox.filesystem.denyWrite[] | select(test("\\.git/\\*\\*/config"))] | length' 0 \
      "no entry has the shape .git/**/config, so a branch named config stays writable (the modules/**/config* entries are a different shape)"
jq_is '[.sandbox.filesystem.denyWrite[] | select(test("/\\.git$")) | select(test("/\\.claude/worktrees/") | not)]
       | sort == ["~/.local/share/chezmoi-*/.git","~/Code/.git","~/Documents/.git","~/Library/Mobile Documents/iCloud~md~obsidian/**/.git"]' true \
      "the only entries ending in .git are the four top-level ones and the fifteen harness forms"
jq_is '[.sandbox.filesystem.denyWrite[] | select(test("/HEAD$"))] | sort
       == ["~/Code/*/HEAD","~/Code/HEAD","~/Documents/HEAD","~/Library/Mobile Documents/iCloud~md~obsidian/**/HEAD"]' true \
      "exactly four entries end in /HEAD: the roots top level, the vault at any depth, and the organisation level"

# Glob semantics: convert each denyWrite entry to the regex Claude Code compiles it to
# (spec 2026-10-30 section 1, how these compile) and test sample paths. A path is denied
# if and only if some entry's regex matches it.
GLOB_RX='
  def rx: sub("^~"; $home)
    | gsub("(?<c>[.+?^$(){}|\\[\\]\\\\])"; "\\\(.c)")
    | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002") | gsub("\\*"; "[^/]*")
    | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")
    | "^" + . + "(/.*)?$";
  . as $d | any($d[] | rx; . as $r | $p | test($r; $fl))'
DENY_SET=$(printf '%s' "$OUT" | jq -c '.sandbox.filesystem.denyWrite')
glob_denied() { printf '%s' "$DENY_SET" | jq --arg home "$HOME" --arg p "$1" --arg fl "${GLOB_FLAGS:-}" "$GLOB_RX" 2>&1; }
glob_case() { # glob_case <denied|allowed> <path>
  local want=true label="denied"
  [ "$1" = allowed ] && { want=false; label="allowed"; }
  got=$(glob_denied "$2")
  if [ "$got" = "$want" ]; then _pass "glob: $2 is $label${3:+ ($3)}"; else _fail "glob: $2 is $label${3:+ ($3)}" "$got"; fi
}
# Seatbelt matches regardless of letter case on this volume (spec 2026-10-30 section 1), so
# a case-insensitive sample is checked with the regex i flag.
glob_case_i() { GLOB_FLAGS=i glob_case "$1" "$2"; }
H="$HOME"
for p in "$H/Code/Org/repo/.git/config" "$H/Code/tagteam/.git/config.lock" \
         "$H/.local/share/chezmoi/.git/config" "$H/Documents/a/b/c/.git/config.worktree" \
         "$H/Code/Org/repo/.git/commondir" "$H/Code/Org/repo/.git/worktrees/w/commondir" \
         "$H/Code/Org/repo/.git/worktrees/w/config.worktree" \
         "$H/Code/Org/repo/.git/modules/plays/roles/x/config" \
         "$H/Code/Org/repo/.git/modules/x/worktrees/y/config.worktree" \
         "$H/Code/.git" "$H/Documents/.git" \
         "$H/Library/Mobile Documents/iCloud~md~obsidian/Documents/MSB/x/.git" \
         "$H/Code/Org/repo/.claude/worktrees/agent-1/.git" \
         "$H/.local/share/chezmoi/.claude/worktrees/agent-1/.git" \
         "$H/Code/HEAD" "$H/Documents/HEAD" \
         "$H/Library/Mobile Documents/iCloud~md~obsidian/Documents/MSB/x/HEAD" "$H/Code/Org/HEAD" \
         "$H/Code/Org/repo/.git/worktrees/w/modules/sub/config" \
         "$H/Code/Org/repo/.git/worktrees/w/modules/sub/config.lock" \
         "$H/Code/Org/repo/.git/worktrees/w/modules/sub/commondir" \
         "$H/Code/Org/repo/.git/worktrees/w/modules/sub/hooks" \
         "$H/Code/Org/repo/.git/worktrees/w/modules/sub/hooks/x" \
         "$H/Code/Org/repo/.git/modules/sub/refs/heads/config"; do
  glob_case denied "$p"
done
for root in "$H/Code" "$H/.local/share/chezmoi" "$H/.local/share/chezmoi-feat-x" "$H/Documents" "$H/Library/Mobile Documents/iCloud~md~obsidian/Documents"; do
  for p in "$root/.lazygit.yml" "$root/Org/.lazygit.yml" "$root/Org/repo/.lazygit.yml" \
           "$root/Org/repo/.git/lazygit.yml" "$root/Org/repo/.git/worktrees/w/lazygit.yml" \
           "$root/Org/repo/.git/glab-cli/config.yml" "$root/.git/glab-cli/config.yml" \
           "$root/Org/repo/.git/worktrees/w/glab-cli/config.yml"; do
    glob_case denied "$p"
  done
done
# A dotfiles wt sibling (~/.local/share/chezmoi-<branch>) ends with every denial a ~/Code
# repository has, plus its own top-level .git. The glob matches any chezmoi-* name, so a
# sibling created before its session starts cannot be seeded with agent configuration.
S="$H/.local/share/chezmoi-feat-x"
for p in "$S/.mcp.json" "$S/.codex/config.toml" "$S/.claude/settings.local.json" \
         "$S/.claude/worktrees/agent-1/.git" "$S/.claude/worktrees/agent-1/.mcp.json" \
         "$S/.git" "$S/Org/repo/.git/hooks/pre-commit" \
         "$H/.local/share/chezmoi-not-yet/.claude/settings.json"; do
  glob_case denied "$p"
done
# Only the sibling's own top-level .git is denied: a repository nested deeper keeps its
# .git, objects and index writable.
for p in "$S/README.md" "$S/tests/fixtures/r/.git" "$S/tests/fixtures/r/.git/objects/ab/cd" \
         "$S/tests/fixtures/r/.git/index" \
         "$H/.local/share/chezmoi/.git/objects/ab/cd" "$H/.local/share/chezmoi/.git/index"; do
  glob_case allowed "$p"
done
# Documented consequence of ** crossing into refs inside a submodule's git directory.
glob_case denied "$H/Code/Org/repo/.git/modules/sub/refs/heads/commondir" \
  "documented consequence: ** crosses into refs"
glob_case denied "$H/Code/Org/repo/.git/worktrees/w/modules/sub/refs/heads/hooks" \
  "documented consequence: ** crosses into refs"
# Documented consequence: .git/**/lazygit.yml also denies a ref or any file by that name
# inside a git directory.
glob_case denied "$H/Code/Org/repo/.git/refs/heads/lazygit.yml"
for p in "$H/Code/head" "$H/Code/Org/head" "$H/Code/Org/repo/.GIT/CONFIG" \
         "$H/Code/Org/repo/.git/worktrees/w/modules/sub/Hooks/x"; do
  glob_case_i denied "$p"
done
for p in "$H/Code/Org/repo/.git/objects/ab/cdef" "$H/Code/Org/repo/.git/index" \
         "$H/Code/Org/repo/.git/HEAD" "$H/Code/Org/repo/.git/refs/heads/config" \
         "$H/Code/Org/repo/.git/refs/heads/config-x" "$H/Code/Org/repo/.git/refs/heads/commondir" \
         "$H/Code/Org/repo/.git/worktrees/w/gitdir" "$H/Code/Org/repo/.git/worktrees/w/HEAD" \
         "$H/Code/tagteam/.git/index" "$H/Code/Netronix/ansible-roles/r/.git/index" \
         "$H/Code/Org/repo-branch/.git" "/private/tmp/claude-501/x/.git/config" \
         "$H/Code/Org/repo/node_modules/pkg/.claude/settings.local.json" \
         "$H/Code/Org/repo/.git/HEAD" "$H/Code/tagteam/.git/HEAD" "$H/Code/Org/repo/HEAD" \
         "$H/Code/Org/repo/.git/worktrees/w/modules/sub/objects/x" \
         "$H/Code/Org/repo/.git/modules/sub/objects/ab/cdef" \
         "$H/Code/Org/repo/.git/modules/sub/refs/heads/main" \
         "$H/Code/Org/repo/.git/glab-cli/recover/x" "$H/Code/Org/repo/lazygit.yml" \
         "$H/Code/Org/repo/.git/worktrees/w/glab-cli/recover/x" "$H/Code/Org/repo/.git/worktrees/w/glab-cli/other.yml" \
         "$H/Code/Org/repo/.git/refs/heads/config-ish" "$H/Code/Org/repo/src/.lazygit.yml.bak/x"; do
  glob_case allowed "$p"
done
jq_is '[.sandbox.filesystem.denyWrite[] | select(test("/\\.claude/settings|/\\.mcp\\.json|/\\.codex")) | sub("/\\.(claude/settings|mcp\\.json|codex).*$"; "") | select(contains("**"))] | length' 0 \
      "no agent configuration entry has an any-depth ** before the file, so node_modules packages stay writable (only the .codex/** tail has one)"
# allowWrite grants no sibling (it does not honour the chezmoi-* glob, measured 2026-11-11),
# and nothing that merely resembles one or the rest of ~/.local/share. The first two cases
# are positive controls: the same filter must grant the roots that are listed.
ALLOW_SET=$(printf '%s' "$OUT" | jq -c '.sandbox.filesystem.allowWrite')
glob_granted() { printf '%s' "$ALLOW_SET" | jq --arg home "$HOME" --arg p "$1" --arg fl "" "$GLOB_RX" 2>&1; }
grant_case() { # grant_case <granted|not> <path>
  local want=true label="granted"
  [ "$1" = not ] && { want=false; label="not granted"; }
  got=$(glob_granted "$2")
  if [ "$got" = "$want" ]; then _pass "allowWrite: $2 is $label"; else _fail "allowWrite: $2 is $label" "$got"; fi
}
grant_case granted "$H/Code/x/f"
grant_case granted "$H/.local/share/chezmoi/f"
grant_case not "$H/.local/share/chezmoi-feat-x/f"
for p in "$H/.local/share/chezmoifoo/x" "$H/.local/share/x-chezmoi-y/f" \
         "$H/.local/share/mise/installs/x" "$H/.local/bin/x"; do
  grant_case not "$p"
done
jq_is '[.sandbox.filesystem.allowWrite[] | select(test("(^|/)\\.ssh(/|$)") or test("(^|/)\\.aws(/|$)") or test("/op(/|$)"))] | length' 0 \
      "no credential path is writable through allowWrite"

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
# Six entries, each because the tool reaches a resource the sandbox blocks: docker its
# own socket, basecamp the macOS Keychain, herdr and xreview the herdr unix socket, review
# the 1Password integration (op) and its state and session directories, wt git configuration
# (git worktree add), the herdr socket and ~/.local/state. The middle three earn it for a
# second reason — sandboxed they return confident wrong answers rather than failing, so the
# "escalate only on sandbox evidence" rule has nothing to fire on. Adding a seventh entry
# should require the same justification, which is why this is pinned rather than open-ended.
jq_is '.sandbox.excludedCommands == ["docker *", "basecamp *", "herdr *", "xreview *", "review *", "wt *"]' true \
      "excludedCommands is exactly the six socket/keychain/state tools"
x_match() { # x_match <command> -> how many excludedCommands patterns match it
  printf '%s' "$OUT" | jq -r --arg c "$1" "$MATCHES"' [.sandbox.excludedCommands[] | ("Bash(" + . + ")") | select(hit($c))] | length'
}
x_is() { # x_is <command> <expected count> <label>
  got=$(x_match "$1")
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$got"; fi
}
x_is 'wt --no-focus feat/x main' 1 "wt with flags runs unsandboxed"
x_is 'wt feat/x' 1 "plain wt runs unsandboxed"
for c in 'wt-rm feat/x' 'wt-prepare feat/x' 'wt-teardown feat/x'; do
  x_is "$c" 0 "wt-* tool stays sandboxed: $c"
done
# A "wt*" pattern would also match the three above. The command-builtin spelling cannot be
# matched by any pattern starting with wt, so this guards only that no exclusion matches it.
x_is 'command wt-rm feat/x' 0 "no exclusion matches the command-builtin spelling: command wt-rm feat/x"
m_is 'wt --no-focus feat/x main' 0 "no allow rule lets an unsandboxed wt skip the classifier"
m_is 'wt feat/x' 0 "no allow rule matches plain wt"
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
jq_is '.sandbox.failIfUnavailable' true "the sandbox refuses to run commands unsandboxed when it cannot start"
# On, a sandboxed command skips the allow rules and auto mode sends it to the classifier, so
# every sandboxed command keeps the classifier. Off would let Bash rm and file writes in the
# working directories skip it (spec 2026-10-28-reload-functions-merged-deletes, section 2).
jq_is '.sandbox.autoAllowBashIfSandboxed' true "sandbox auto-allow is on, so every sandboxed command keeps the classifier"

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
  got=$(hook_matchers PreToolUse "/opt/homebrew/bin/bash \$HOME/.claude/$g.sh")
  if [ "$got" = "Bash" ]; then _pass "$g runs once, on the Bash tool"; else _fail "$g runs once, on the Bash tool" "$got"; fi
done
# The apply-window guard's matcher must equal the tool set its own case arm inspects.
arm=$(sed -nE 's/^case "\$tool" in ([A-Za-z|]+)\).*/\1/p' "$SRC/dot_claude/executable_xreview-apply-guard.sh")
got=$(hook_matchers PreToolUse '/opt/homebrew/bin/bash $HOME/.claude/xreview-apply-guard.sh')
if [ -n "$arm" ] && [ "$got" = "$arm" ]; then _pass "xreview-apply-guard runs once, on the tools it inspects"; else _fail "xreview-apply-guard runs once, on the tools it inspects" "matcher '$got', arm '$arm'"; fi
jq_is '.hooks.PreToolUse | length' 5 "no PreToolUse entry beyond the five guards"
# The forge guard shells out to glab, git and gitleaks (the push helper alone has a 30 s
# budget), so its hook limit is explicit rather than left to the runtime default.
jq_is '[.hooks.PreToolUse[].hooks[] | select(.command == "/opt/homebrew/bin/bash $HOME/.claude/git-forge-guard.sh") | .timeout] | join(",")' 60 \
      "the forge guard hook carries an explicit 60 s timeout"
# The pre-merge guard reads origin (git ls-remote) and the forge (glab, gh). It gives up at
# 40 s, inside this limit: a hook that reaches its timeout is a failure, which onFailure
# below turns into a block.
jq_is '[.hooks.PreToolUse[].hooks[] | select(.command == "/opt/homebrew/bin/bash $HOME/.claude/xreview-guard.sh") | .timeout] | join(",")' 60 \
      "the pre-merge guard hook carries an explicit 60 s timeout"
# The three danger guards fail closed: a guard that cannot start, crashes or times out blocks
# the tool call instead of letting it through. The other two stay fail-open (ruled).
for g in git-forge-guard worktree-guard xreview-guard; do
  jq_is "[.hooks.PreToolUse[].hooks[] | select(.command == \"/opt/homebrew/bin/bash \$HOME/.claude/$g.sh\") | .onFailure] | join(\",\")" block "$g fails closed"
done
jq_is '[.hooks[][]?.hooks[]? | select(has("onFailure"))] | length' 3 "no other hook sets onFailure"
# The SessionStart hooks must survive alongside them — adding PreToolUse replaced the
# whole hooks object once during development.
jq_is '.hooks.SessionStart | length' 3 "all three SessionStart hooks present"
jq_is '[.hooks.SessionStart[] | select(has("matcher") | not) | .hooks[]
        | select(.command == "/opt/homebrew/bin/bash $HOME/.claude/hooks/memory-health.sh" and .timeout == 10)] | length' 1 \
      "the memory health hook: no matcher, timeout 10"
jq_is "[.hooks.SessionStart[] | select(.matcher == \"*\") | .hooks[]
        | select(.command == \"/opt/homebrew/bin/bash '$HOME/.claude/hooks/herdr-agent-state.sh' session\" and .timeout == 10)] | length" 1 \
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
# terraform teardown asks in every spelling an agent writes: the no-cd rule steers it to
# -chdir, and apply -destroy is destroy under another verb. A rule's * matches any text,
# spaces included, which a shell case pattern reproduces; plan and a plain apply stay silent.
emit '{}'
asks() { # asks <command>: does any ask rule match it?
  local rule pat
  while IFS= read -r rule; do
    pat=${rule#Bash(}; pat=${pat%)}
    # shellcheck disable=SC2254 # the rule is the pattern
    case "$1" in $pat) return 0 ;; esac
  done < <(printf '%s' "$OUT" | jq -r '.permissions.ask[] | select(startswith("Bash("))')
  return 1
}
for c in "terraform destroy" "terraform -chdir=infra destroy -auto-approve" \
         "terraform apply -destroy" "terraform -chdir=infra apply -destroy -auto-approve"; do
  if asks "$c"; then _pass "teardown asks: $c"; else _fail "teardown asks: $c" "no ask rule matches"; fi
done
for c in "terraform -chdir=infra plan" "terraform -chdir=infra apply -auto-approve" "terraform apply"; do
  if asks "$c"; then _fail "no teardown ask: $c" "an ask rule matches"; else _pass "no teardown ask: $c"; fi
done
# op: plural spellings and a leading global flag must not slip past the denies.
for r in "op items get*" "op documents get*" "op --* read*" "op --* item get*" "op --* items get*" \
         "op --* document get*" "op --* documents get*" "op --* inject*" "op --* run*"; do
  jq_is ".permissions.deny | index(\"Bash($r)\") != null" true "op deny covers $r"
done

echo "S. the subagent statusline is retired"
# It never rendered. The script is deleted, and the key must go from the LIVE file too:
# the merge starts from it, so dropping the key from the owned set alone would keep it.
emit '{"subagentStatusLine":{"type":"command","command":"bash /x/subagent-statusline.sh"}}'
jq_is 'has("subagentStatusLine")' false "a live subagentStatusLine is deleted"
jq_is '.statusLine.command | endswith("/.claude/statusline.sh")' true "the main statusline stays"

echo "R. every permission prompt is audited, never decided"
emit '{}'
got=$(hook_matchers PermissionRequest '/opt/homebrew/bin/bash $HOME/.claude/hooks/prompt-audit.sh')
if [ "$got" = "*" ]; then _pass "the prompt-audit hook runs once, on every tool"; else _fail "the prompt-audit hook runs once, on every tool" "$got"; fi
jq_is '.hooks.PermissionRequest | length' 1 "no other PermissionRequest hook"

echo "U. autoMode: the classifier rule for merged-branch deletes"
# Spec 2026-10-28-reload-functions-merged-deletes, section 2: the classifier may allow the plain
# pinned delete of a merged branch, trusting the push guard rule 4 to have verified it. The
# text is pinned exactly; "$defaults" comes first, since a non-empty list keeps the built-in
# allow rules only through it. Spec 2026-10-29-push-guard-escaped-spellings, section 5, adds the
# sentence on literal git and push words; MAIN_RULE is the text without it.
MAIN_RULE='Deleting a remote branch that is already merged into the remote'"'"'s default branch, only when the command is exactly the plain form `git push --force-with-lease=refs/heads/<branch>:<sha> origin --delete <branch>` (the lease may also be written `--force-with-lease=<branch>:<sha>`, and `:refs/heads/<branch>` may stand in place of `--delete <branch>`), with every deleted branch pinned to its tip, and with no quoting, escapes, globs, variables, substitutions or other commands in it. A PreToolUse push guard verifies the merge and the pin before such a push runs and blocks it otherwise. This never covers deleting the default branch, and never a push that creates or updates a branch.'
RULE='Deleting a remote branch that is already merged into the remote'"'"'s default branch, only when the command is exactly the plain form `git push --force-with-lease=refs/heads/<branch>:<sha> origin --delete <branch>` (the lease may also be written `--force-with-lease=<branch>:<sha>`, and `:refs/heads/<branch>` may stand in place of `--delete <branch>`), with every deleted branch pinned to its tip, and with no quoting, escapes, globs, variables, substitutions or other commands in it. It never applies when git or push is spelled any way other than those literal words, is built at run time, or is run through a script or interpreter. A PreToolUse push guard verifies the merge and the pin before such a push runs and blocks it otherwise. This never covers deleting the default branch, and never a push that creates or updates a branch.'
emit '{}'
jq_is ".autoMode == {\"allow\": [\"\$defaults\", $(jq -n --arg r "$RULE" '$r')]}" true \
      'autoMode is exactly {"allow": ["$defaults", RULE]}'
jq_is '.autoMode.allow[0]' '$defaults' '"$defaults" comes first'
# The overlay drops a carried allow entry that starts with the rule's fixed opening, so an
# edited rule never lingers in its old form; that only works while the rule keeps the opening.
OPENING='Deleting a remote branch that is already merged into the remote'
jq_is ".autoMode.allow[1] | startswith(\"$OPENING\")" true "the rule starts with its fixed opening"
jq_is '.autoMode | has("soft_deny") or has("hard_deny") or has("environment")' false \
      "the overlay sets no soft_deny, hard_deny or environment"
# Owned in part, like permissions: what /auto-mode-setup wrote to the live file (the
# environment, private rules) is carried, since this public repo cannot declare it. Only
# "$defaults" and the rule are placed, each once, and a live copy of either is not repeated.
emit "$(jq -n --arg r "$RULE" '{autoMode: {allow: ["Bash(x) in y", $r, "$defaults", $r], environment: ["e1", "e2"], soft_deny: ["s"]}}')"
jq_is ".autoMode.allow == [\"\$defaults\", $(jq -n --arg r "$RULE" '$r'), \"Bash(x) in y\"]" true \
      "a live allow entry is carried after the rule, and neither is repeated"
jq_is '.autoMode.environment == ["e1", "e2"] and .autoMode.soft_deny == ["s"]' true \
      "a live environment and soft_deny are carried"
FIRST=$OUT
emit "$FIRST"
if [ "$(printf '%s' "$OUT" | jq -S .)" = "$(printf '%s' "$FIRST" | jq -S .)" ]; then
  _pass "a second apply leaves autoMode as it was"
else
  _fail "a second apply leaves autoMode as it was" "the second pass differs from the first"
fi
# An older text of the rule (round 8, before globs were named), carried from the live file,
# is dropped because it starts with the opening; a private rule beside it stays.
OLD_RULE='Deleting a remote branch that is already merged into the remote'"'"'s default branch, only when the command is exactly the plain form `git push --force-with-lease=refs/heads/<branch>:<sha> origin --delete <branch>` (the lease may also be written `--force-with-lease=<branch>:<sha>`, and `:refs/heads/<branch>` may stand in place of `--delete <branch>`), with every deleted branch pinned to its tip, and with no quoting, escapes, variables, substitutions or other commands in it. A PreToolUse push guard verifies the merge and the pin before such a push runs and blocks it otherwise. This never covers deleting the default branch, and never a push that creates or updates a branch.'
emit "$(jq -n --arg o "$OLD_RULE" '{autoMode: {allow: ["$defaults", $o, "Bash(x) in y"]}}')"
jq_is ".autoMode.allow == [\"\$defaults\", $(jq -n --arg r "$RULE" '$r'), \"Bash(x) in y\"]" true \
      "an older text of the rule in the live allow list is dropped"
# main's text of the rule (before the literal-words sentence), carried from the live file, is dropped too.
emit "$(jq -n --arg m "$MAIN_RULE" '{autoMode: {allow: ["$defaults", $m, "Bash(x) in y"]}}')"
jq_is ".autoMode.allow == [\"\$defaults\", $(jq -n --arg r "$RULE" '$r'), \"Bash(x) in y\"]" true \
      "main's text of the rule in the live allow list is dropped"
emit '{"autoMode":"junk"}'
jq_is ".autoMode == {\"allow\": [\"\$defaults\", $(jq -n --arg r "$RULE" '$r')]}" true \
      "a live autoMode that is not an object is replaced"
emit '{"autoMode":{"allow":"junk","environment":["e"]}}'
jq_is ".autoMode == {\"allow\": [\"\$defaults\", $(jq -n --arg r "$RULE" '$r')], \"environment\": [\"e\"]}" true \
      "a live allow that is not a list is replaced, the rest carried"

echo "X. every wired hook script is actually managed by chezmoi"
# A hook wired to an unmanaged path never deploys and fails open — silently inert.
# This is what a `.chezmoiignore` allowlist omission (task-3 fix-round-1) looks like:
# 41 guard tests, 83 settings tests, and three task reviews all stayed green while the
# hook pointed at a file chezmoi never deployed. Derive the hook list from the emitted
# settings rather than hardcoding it, so a future third hook is covered automatically.
if command -v chezmoi >/dev/null 2>&1; then
  MT="$(mktemp -d "${TMPDIR:-/tmp}/claude-settings.XXXXXX")"
  if ! managed=$(chezmoi --source "$SRC" managed 2>"$MT/managed.err"); then
    printf 'INCONCLUSIVE: chezmoi managed failed: %s\n  a cold external cache does this; warm it outside the sandbox: command chezmoi --source %s managed >/dev/null\n' "$(awk 'NF { print; exit }' "$MT/managed.err" | grep . || echo '(no stderr)')" "$SRC" >&2
    exit 2
  fi
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
  # The pre-merge gate's Python halves deploy beside its shell front, each through its own
  # .chezmoiignore allowlist entry. Without one the file never deploys: the gate then refuses
  # every gated command, and xreview cannot dispatch.
  for f in .claude/xreview-guard.py .claude/xreview-ledger.py; do
    case "$managed" in
      *"$f"*) _pass "helper $f is chezmoi-managed" ;;
      *)      _fail "helper $f is chezmoi-managed" "not in \`chezmoi managed\`" ;;
    esac
  done
  # An agent file chezmoi does not manage never deploys, and its type is then "not found".
  for a in "$SRC"/dot_claude/agents/*.md; do
    [ -e "$a" ] || continue
    f=".claude/agents/$(basename "$a")"
    if printf '%s\n' "$managed" | grep -qxF -- "$f"; then _pass "agent $f is chezmoi-managed"
    else _fail "agent $f is chezmoi-managed" "not in \`chezmoi managed\`"; fi
  done
  # A skill without its .chezmoiignore re-include never deploys, and its rules silently stop applying.
  for s in "$SRC"/dot_claude/skills/*/SKILL.md; do
    [ -e "$s" ] || continue
    f=".claude/skills/$(basename "$(dirname "$s")")/SKILL.md"
    if printf '%s\n' "$managed" | grep -qxF -- "$f"; then _pass "skill $f is chezmoi-managed"
    else _fail "skill $f is chezmoi-managed" "not in \`chezmoi managed\`"; fi
  done
else
  echo "  SKIP: chezmoi absent — hook-script management unverified"
fi
# An unquoted ": " inside a description breaks the frontmatter YAML and the agent fails to load.
desc_yaml_ok() { # desc_yaml_ok <file>: true unless the description has an unquoted ": "
  awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description:[[:space:]]*/,""); d=$0; exit}
       END{ if (d ~ /^"/) exit 0; if (d ~ /: /) exit 1; exit 0 }' "$1"
}
YF="$(mktemp "${TMPDIR:-/tmp}/claude-settings-agent.XXXXXX")"
printf -- '---\nname: x\ndescription: Does a thing: badly\n---\n' > "$YF"
if desc_yaml_ok "$YF"; then _fail "the description check rejects an unquoted colon-space" "fixture passed"
else _pass "the description check rejects an unquoted colon-space"; fi
printf -- '---\nname: x\ndescription: "Does a thing: well"\n---\n' > "$YF"
if desc_yaml_ok "$YF"; then _pass "the description check accepts a double-quoted colon-space"
else _fail "the description check accepts a double-quoted colon-space" "fixture rejected"; fi
rm -f "$YF"
for a in "$SRC"/dot_claude/agents/*.md; do
  [ -e "$a" ] || continue
  if desc_yaml_ok "$a"; then _pass "$(basename "$a") description parses as YAML"
  else _fail "$(basename "$a") description parses as YAML" "unquoted colon-space in description"; fi
done

echo "Y. unused extensions are switched off, the rest of the live state is carried"
# Doctor cleanup 2026-10-29. plugins.conf is add-only, so dropping a plugin line leaves it
# installed and enabled; enabledPlugins false is what disables it. Both maps are owned entry
# by entry: Claude Code writes them at runtime (/plugin, /skills), so the rest must survive.
SYNCED="pptx docx pdf xlsx google-workspace computer-use built-in-browser morning skill-creator mcp-builder internal-comms canvas-design algorithmic-art theme-factory brand-guidelines slack-gif-creator import-memory"
emit '{}'
for p in claude-code-setup claude-md-management; do
  jq_is ".enabledPlugins[\"$p@claude-plugins-official\"]" false "plugin $p is disabled on a bare file"
  if grep -q "^claude_plugin[[:space:]]*$p@" "$SRC/dot_config/agents/plugins.conf"; then
    _fail "plugin $p is no longer declared in plugins.conf" "still declared"
  else
    _pass "plugin $p is no longer declared in plugins.conf"
  fi
done
for s in $SYNCED; do
  jq_is ".skillOverrides[\"anthropic-skills:$s\"]" off "synced skill $s is off"
done
# skillOverrides does not reach plugin skills (measured on 2.1.314), so the two cowork skills
# go off with their plugin, which is synced from claude.ai.
jq_is '.enabledPlugins["cowork-plugin-management@synced"]' false "the cowork plugin is disabled on a bare file"
# The UniFi server runs from ~/Code/home-assistant/.mcp.json; the marketplace and the plugin
# line are gone from plugins.conf (add-only, so the installed plugin is kept off here).
jq_is '.enabledPlugins["unifi-network@unifi-plugins"]' false "the unifi-network plugin is disabled on a bare file"
if grep -Eq '^claude_(plugin[[:space:]]+unifi-network@|marketplace[[:space:]]+sirkirby/unifi-mcp)' "$SRC/dot_config/agents/plugins.conf"; then
  _fail "unifi-network is no longer declared in plugins.conf" "still declared"
else
  _pass "unifi-network is no longer declared in plugins.conf"
fi
jq_is '.skillOverrides | keys | map(select(startswith("cowork-plugin-management"))) | length' 0 "no plugin skill is listed in skillOverrides"
jq_is '.skillOverrides | length' 17 "exactly 17 skills are overridden on a bare file"
jq_is '.skillOverrides | to_entries | all(.value == "off")' true "every owned override is off"
jq_is '.enabledPlugins | length' 4 "only the four disabled plugins are named on a bare file"
# Skills that stay on are never named.
for s in docs deep-research chrome-browser live-feedback clarity api-review; do
  jq_is ".skillOverrides | keys | map(select(endswith(\":$s\") or . == \"$s\")) | length" 0 "skill $s stays on"
done
for p in ruby-lsp rust-analyzer-lsp; do
  jq_is ".enabledPlugins | has(\"$p@claude-plugins-official\") | not" true "plugin $p stays on"
done
emit '{"enabledPlugins":{"x@y":true,"unifi-network@unifi-plugins":true,"claude-code-setup@claude-plugins-official":true,"rust-analyzer-lsp@claude-plugins-official":true},"skillOverrides":{"mine":"name-only","anthropic-skills:pdf":"on"}}'
jq_is '.enabledPlugins["x@y"]'                                       true  "a live plugin entry is carried"
jq_is '.enabledPlugins["rust-analyzer-lsp@claude-plugins-official"]' true  "an enabled live plugin stays enabled"
jq_is '.enabledPlugins["claude-code-setup@claude-plugins-official"]' false "a live enabled retired plugin is forced off"
jq_is '.enabledPlugins["unifi-network@unifi-plugins"]'               false "a live enabled unifi-network plugin is forced off"
jq_is '.skillOverrides.mine'                                         name-only "a live skill override is carried"
jq_is '.skillOverrides["anthropic-skills:pdf"]'                      off   "a live override of an owned skill is forced off"
emit '{"enabledPlugins":"junk","skillOverrides":["junk"]}'
jq_is '.enabledPlugins | type'   object "a malformed live enabledPlugins is replaced"
jq_is '.skillOverrides | length' 17     "a malformed live skillOverrides is replaced"
emit '{}'
SECOND=$(printf '%s' "$OUT" | /bin/bash "$MOD")
if [ "$SECOND" = "$OUT" ]; then _pass "applying twice is a no-op"; else _fail "applying twice is a no-op" "second pass differs"; fi

echo "Z. agent identity tokens (spec 2026-11-12-forge-push-protection, section 1.4)"
# 1Password is the source at apply. Listed: the variable is set. Not listed: absent (the inert
# state and the rollback). op missing or failing: the live values are carried, so a sandboxed
# preview neither drops nor diffs them. Listed but unreadable: the apply fails with no output.
# Values are compared inside jq ($ENV) and only a boolean is printed.
export OP_GH=fixture-gh-0001 OP_GL=fixture-gl-0001 LIVE_GH=live-gh-0001 LIVE_GL=live-gl-0001
ITEMS_BOTH='[{"title":"GitHub Agent SSH Key"},{"title":"GitHub Agent Token"},{"title":"GitLab Agent Token"}]'
ITEMS_GH='[{"title":"GitHub Agent SSH Key"},{"title":"GitHub Agent Token"}]'
LIVE_BOTH=$(printf '{"env":{"GH_TOKEN":"%s","GITLAB_TOKEN":"%s","STALE":"1"}}' "$LIVE_GH" "$LIVE_GL")
ERRS="$OPD/stderr.all"; : > "$ERRS"
emit_op() { # emit_op <live-json> [VAR=value ...]: one apply with a stub-op scenario; sets OUT and RC
  local live=$1; shift
  if OUT=$(printf '%s' "$live" | env "$@" HOME="$HOME" /bin/bash "$MOD" 2>>"$ERRS"); then RC=0; else RC=$?; fi
}
emit_op '{}' OP_ITEMS="$ITEMS_BOTH"
jq_is '.env.GH_TOKEN == $ENV.OP_GH' true "a listed GitHub token is rendered into env"
jq_is '.env.GITLAB_TOKEN == $ENV.OP_GL' true "a listed GitLab token is rendered into env"
jq_is '.env | has("EDITOR") and has("SSL_CERT_FILE")' true "the tokens are added to the owned env, not instead of it"
jq_is '.env | has("GITHUB_TOKEN") or has("GLAB_TOKEN")' false "no other token variable is rendered"
emit_op '{}' OP_ITEMS="$ITEMS_BOTH"; FIRST=$OUT
emit_op "$FIRST" OP_ITEMS="$ITEMS_BOTH"
if [ "$OUT" = "$FIRST" ]; then _pass "a second apply with both tokens changes nothing"
else _fail "a second apply with both tokens changes nothing" "second pass differs"; fi
emit_op "$LIVE_BOTH" OP_ITEMS="$ITEMS_BOTH"
jq_is '.env.GH_TOKEN == $ENV.OP_GH and .env.GITLAB_TOKEN == $ENV.OP_GL' true "1Password wins over a stale live token"
jq_is '.env | has("STALE")' false "an unknown live env key does not linger"
emit_op '{}' OP_ITEMS="$ITEMS_GH"
jq_is '.env.GH_TOKEN == $ENV.OP_GH' true "only the GitHub item listed: its token is rendered"
jq_is '.env | has("GITLAB_TOKEN")' false "only the GitHub item listed: no GitLab token"
emit_op "$LIVE_BOTH" OP_ITEMS='[]'
jq_is '.env | has("GH_TOKEN") or has("GITLAB_TOKEN")' false "no item listed: both tokens absent (the rollback)"
emit_op "$LIVE_BOTH" OP_ITEMS="$ITEMS_GH"
jq_is '.env | has("GITLAB_TOKEN")' false "an unlisted item drops its live token while another is listed"
# 1Password unreachable: carry, never drop and never diff.
emit_op "$LIVE_BOTH" OP_DOWN=1
jq_is '.env.GH_TOKEN == $ENV.LIVE_GH and .env.GITLAB_TOKEN == $ENV.LIVE_GL' true "op failing: the live tokens are carried unchanged"
jq_is '.env | has("STALE")' false "op failing: only the two token keys are carried"
emit_op '{}' OP_DOWN=1
jq_is '.env | has("GH_TOKEN") or has("GITLAB_TOKEN")' false "op failing with no live tokens: both absent"
emit_op "$LIVE_BOTH" PATH="$OPD/noop:/usr/bin:/bin"
if [ -z "$(env PATH="$OPD/noop:/usr/bin:/bin" /bin/sh -c 'command -v op')" ]; then _pass "the no-op scenario really has no op on PATH"
else _fail "the no-op scenario really has no op on PATH" "op resolved"; fi
jq_is '.env.GH_TOKEN == $ENV.LIVE_GH and .env.GITLAB_TOKEN == $ENV.LIVE_GL' true "no op on PATH: the live tokens are carried unchanged"
emit_op '{}' PATH="$OPD/noop:/usr/bin:/bin"
jq_is '.env | has("GH_TOKEN") or has("GITLAB_TOKEN")' false "no op on PATH and no live tokens: both absent"
emit_op '{"env":{"GH_TOKEN":7,"GITLAB_TOKEN":"live-gl-0001"}}' OP_DOWN=1
jq_is '.env | has("GH_TOKEN")' false "op failing: a live value that is not a string is not carried"
jq_is '.env.GITLAB_TOKEN == $ENV.LIVE_GL' true "op failing: the string value beside it is carried"
emit_op "$LIVE_BOTH" OP_ITEMS='not json'
jq_is '.env.GH_TOKEN == $ENV.LIVE_GH and .env.GITLAB_TOKEN == $ENV.LIVE_GL' true "an unparsable item list counts as unreachable: carried"
# Listed but unreadable: fail, so chezmoi keeps the old file.
emit_op "$LIVE_BOTH" OP_ITEMS="$ITEMS_BOTH" OP_READ_FAIL=1
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then _pass "a listed but unreadable token fails the apply with no stdout"
else _fail "a listed but unreadable token fails the apply with no stdout" "rc=$RC stdout=${#OUT} bytes"; fi
if grep -qF '1Password lists "GitHub Agent Token" but its token cannot be read' "$ERRS"; then _pass "the failure names the item"
else _fail "the failure names the item" "message missing"; fi
emit_op '{}' OP_ITEMS="$ITEMS_GH" OP_GH=
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then _pass "a listed item whose token reads empty fails the apply"
else _fail "a listed item whose token reads empty fails the apply" "rc=$RC stdout=${#OUT} bytes"; fi
# No value reaches a diagnostic or a command line, and op is only asked the two known questions.
if grep -qF -e "$OP_GH" -e "$OP_GL" -e "$LIVE_GH" -e "$LIVE_GL" "$ERRS" "$JQ_LOG"; then
  _fail "no token appears in stderr or in jq argv" "a value was found"
else _pass "no token appears in stderr or in jq argv"; fi
if [ -s "$OP_LOG" ]; then _fail "op is only asked to list items and read the two tokens" "$(cat "$OP_LOG")"
else _pass "op is only asked to list items and read the two tokens"; fi
# The agent SSH configuration must stay readable in the sandbox: no deny rule, credential entry
# or allowRead gap hides ~/.config/agent-identity/ssh_config (its Match block is what pins the key).
emit '{}'
jq_is '[.permissions.deny[]? | select(startswith("Read(")) | .[5:-1]
        | gsub("\\."; "\\.") | gsub("\\*\\*/"; "(.*/)?") | gsub("/\\*\\*"; "/.*") | gsub("\\*"; "[^/]*")
        | . as $re | select("~/.config/agent-identity/ssh_config" | test("^" + $re + "$"))] | length' 0 \
      "no Read deny rule covers the agent SSH configuration"
jq_is '[.sandbox.credentials.files[].path | . as $c | select("~/.config/agent-identity/ssh_config" | startswith($c))] | length' 0 \
      "no credential path covers the agent SSH configuration"
jq_is '.sandbox.filesystem.allowRead | index("~/.ssh/github-agent.pub") != null' true \
      "the agent public key is readable through allowRead"

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
  # The sp-* bodies restate the cd/grep rule. It was dropped on 2026-09-30 (spec 2026-09-30
  # section 3.3), and sp-* subagents then went from 0.03 to 0.67-0.84 guard denials per
  # dispatch. It lives in each body, the subagent's own system prompt; the guard stays the
  # enforcement.
  case "$stem" in sp-*)
    if grep -qF -- '- Never chain commands after a leading `cd`, and never give a recursive `grep` or `rg` a bare' "$agent" \
      && grep -qF -- '  `.`: the path guard denies both. In a subagent a lone `cd` does not carry over to the next' "$agent" \
      && grep -qF -- '  call either, so use absolute paths, `git -C <dir>`, and name the directories to search.' "$agent"; then
      _pass "$stem states the subagent cd/grep rule"
    else
      _fail "$stem states the subagent cd/grep rule" "the bullet is missing"
    fi ;;
  esac
done

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
