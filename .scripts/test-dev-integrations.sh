#!/usr/bin/env zsh
# Cold-restore check for the Herdr trial.
#
# This verifies the integrations deployed by chezmoi. It never installs them.
# The named session isolates Herdr runtime state; the integration config is the real
# ~/.claude and ~/.codex state activated in Task 11.
#
# Run manually: zsh .scripts/test-dev-integrations.sh
emulate -L zsh
set -u
setopt no_bg_nice

SESSION=dev-restore
FIXTURE_BASE=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-trial
h() { command herdr --session "$SESSION" "$@" }

pass=0
fail=0
ok()  { print -r -- "  PASS: $1"; pass=$((pass + 1)) }
bad() { print -r -- "  FAIL: $1"; fail=$((fail + 1)) }

cleanup() {
  h server stop >/dev/null 2>&1 || true
  command herdr session delete "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

agent_json() {
  local out
  out=$(h agent list 2>/dev/null) || return 1
  print -r -- "$out" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 1
  print -r -- "$out"
}

agent_refs() {
  jq -cS '[.result.agents[] | {agent, session: .agent_session}] | sort_by(.agent)'
}

# Stop before delete: session deletion only acts on stopped sessions.
h server stop >/dev/null 2>&1 || true
command herdr session delete "$SESSION" >/dev/null 2>&1 || true

integration_status=$(command herdr integration status) || {
  bad "integration status failed"
  print -r -- "=== $pass passed, $fail failed ==="
  exit 1
}
print -r -- "$integration_status" | grep -q '^claude: current ' \
  && ok "the claude integration is current" || bad "claude integration is not current"
print -r -- "$integration_status" | grep -q '^codex: current ' \
  && ok "the codex integration is current" || bad "codex integration is not current"
(( fail == 0 )) || {
  print -r -- "=== $pass passed, $fail failed ==="
  exit 1
}

# Stable by design. Codex records project trust in config.toml; a new mktemp path on
# every restore attempt would accumulate one dead trusted-project entry per run. One
# XDG-state fixture keeps the ten-attempt trial repeatable without polluting config.
REPO="$FIXTURE_BASE/restore-fixture"
mkdir -p "$REPO" || exit 1
git -C "$REPO" init -q || exit 1

if ! HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO"; then
  bad "layout creation failed"
  print -r -- "=== $pass passed, $fail failed ==="
  exit 1
fi

print -r -- "  Attach with: herdr --session $SESSION"
print -r -- "  Resolve any first-run trust prompt. In Codex, submit one short prompt so"
print -r -- "  its SessionStart hook runs. Wait until both agents are idle, detach with"
print -r -- "  alt+w, then press Enter here."
read -r

before_json=$(agent_json) || {
  bad "agent list failed before restart"
  print -r -- "=== $pass passed, $fail failed ==="
  exit 1
}
before_names=$(print -r -- "$before_json" | jq -cS '[.result.agents[].agent] | sort')
before_refs=$(print -r -- "$before_json" | agent_refs)
before_n=$(print -r -- "$before_json" | jq -r '.result.agents | length')
before_noref=$(print -r -- "$before_json" | jq -r '[.result.agents[] | select(.agent_session == null)] | length')

[[ "$before_names" == '["claude","codex"]' ]] \
  && ok "exactly Claude and Codex are registered" \
  || bad "unexpected agents before restart: $before_names"
[[ "$before_noref" == 0 && "$before_n" == 2 ]] \
  && ok "both agents report native session refs" \
  || bad "$before_noref of $before_n agents have no session ref"
(( fail == 0 )) || {
  print -r -- "=== $pass passed, $fail failed ==="
  exit 1
}

if h server stop >/dev/null 2>&1; then
  ok "the named server stopped cleanly"
else
  bad "the named server did not stop cleanly"
  print -r -- "=== $pass passed, $fail failed ==="
  exit 1
fi

(command herdr --session "$SESSION" server >/dev/null 2>&1 &)
ready=0
for i in {1..40}; do
  if h workspace list >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.25
done
(( ready )) && ok "the named server restarted" || {
  bad "the named server did not become ready"
  print -r -- "=== $pass passed, $fail failed ==="
  exit 1
}

after_refs=''
after_n=0
for i in {1..120}; do
  if after_json=$(agent_json); then
    after_refs=$(print -r -- "$after_json" | agent_refs)
    after_n=$(print -r -- "$after_json" | jq -r '.result.agents | length')
    [[ "$after_refs" == "$before_refs" ]] && break
  fi
  sleep 0.5
done

[[ "$after_refs" == "$before_refs" && "$before_n" == 2 ]] \
  && ok "the same native agent sessions resumed" \
  || bad "sessions differ after restart (before=$before_n after=$after_n)"

print -r -- "=== $pass passed, $fail failed ==="
(( fail == 0 ))
