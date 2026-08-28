#!/usr/bin/env zsh
# Live gate for hdev/layout.sh against the REAL herdr binary.
#
# Mocked tests cannot detect CLI churn: the stub accepts whatever it was written to
# accept and keeps passing after herdr changes a flag or a JSON shape. Only the real
# binary can, so this runs against it — in an isolated named session, never the live
# one.
#
# A named session isolates the socket and runtime state. It does NOT isolate plugin
# registration, which is global — hence the distinct plugin id below. Reusing
# `dev.layout` would let teardown unlink the plugin the live setup depends on.
#
# Run manually, unsandboxed: zsh .scripts/test-hdev-topology.sh
set -u
SESSION=hdev-test
PLUGIN_ID=dev.layout.test
h() { command herdr --session "$SESSION" "$@" }

pass=0 fail=0
ok()   { print -r -- "  PASS: $1"; pass=$((pass+1)) }
bad()  { print -r -- "  FAIL: $1"; fail=$((fail+1)) }

cleanup() {
  h server stop >/dev/null 2>&1 || true
  command herdr plugin unlink "$PLUGIN_ID" >/dev/null 2>&1 || true
  [[ -n "${SCRATCH:-}" ]] && rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/hdev-live.XXXXXX")"
REPO="$SCRATCH/Code/Test/proj"
mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" commit -q --allow-empty -m init

print -r -- "=== live topology gate (session: $SESSION) ==="

# 1. Cold bootstrap: no server running.
h server stop >/dev/null 2>&1 || true
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO" \
  && ok "cold bootstrap builds a workspace" || bad "cold bootstrap failed"

# 2. Topology is what we think it is.
WS=$(h workspace list | jq -r '.result.workspaces[0].workspace_id')
for l in agents editor runtime git; do
  n=$(h tab list --workspace "$WS" | jq -r --arg l "$l" \
        '[.result.tabs[] | select(.label == $l)] | length')
  [[ "$n" == 1 ]] && ok "exactly one '$l' tab" || bad "'$l' tab count = $n"
done
AT=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="agents") | .tab_id')
n=$(h pane list --workspace "$WS" | jq -r --arg t "$AT" '[.result.panes[] | select(.tab_id==$t)] | length')
[[ "$n" == 2 ]] && ok "agents holds 2 panes" || bad "agents holds $n panes"

# 3. Idempotency: a second run focuses, never duplicates.
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO" >/dev/null
n=$(h workspace list | jq -r '.result.workspaces | length')
[[ "$n" == 1 ]] && ok "a second run does not duplicate" || bad "$n workspaces after a second run"

# 4. Extra tabs survive.
h tab create --workspace "$WS" --label notes >/dev/null
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO" >/dev/null
h tab list --workspace "$WS" | jq -e '.result.tabs[] | select(.label=="notes")' >/dev/null \
  && ok "an unmanaged tab survives" || bad "the unmanaged tab was removed"

# 5. Concurrency, on the schedule that actually breaks it: B scans, A builds and
#    releases, THEN B acquires. Launching two at once mostly proves nothing.
REPO2="$SCRATCH/Code/Test/proj2"
mkdir -p "$REPO2" && git -C "$REPO2" init -q && git -C "$REPO2" commit -q --allow-empty -m init
# B sleeps BEFORE taking the lock, so it arrives after A has built and released —
# the stale-observation schedule. Launching two at once would usually serialise
# harmlessly and prove nothing.
( HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 HL_LOCK_DELAY=3 ~/.config/herdr/layout.sh "$REPO2" ) &
B=$!
sleep 0.2
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO2" >/dev/null 2>&1
wait $B 2>/dev/null || true
n=$(h pane list | jq -r --arg d "$REPO2" \
      '[.result.panes[] | select(.cwd == $d) | .workspace_id] | unique | length')
[[ "$n" == 1 ]] && ok "the delayed-acquisition race yields one workspace" || bad "$n workspaces for one repo"

# 6. Split directions, not just pane counts. Two panes side by side and two stacked
#    are both "2"; only the geometry says which layout was actually built.
RT=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="runtime") | .tab_id')
h pane layout --pane "$(h pane list --workspace "$WS" | jq -r --arg t "$RT" \
    '[.result.panes[] | select(.tab_id==$t)][0].pane_id')" \
  | jq -e '.result | tostring | test("down|vertical|row")' >/dev/null \
  && ok "runtime is split down" || bad "runtime is not split down"

# 7. The plugin: link under a DISTINCT id, invoke it, unlink. Registration is global,
#    so reusing dev.layout would let this teardown unlink the real one.
PDIR="$SCRATCH/plugin"; mkdir -p "$PDIR"
# Match the plugin id EXACTLY. `s/^id = .*/` also rewrites the [[actions]] entry's
# `id = "apply"` — TOML nested tables are not indented — which renames the action
# too, leaving "$PLUGIN_ID.apply" pointing at nothing.
sed 's|^id = "dev.layout"$|id = "'"$PLUGIN_ID"'"|' \
  ~/.config/herdr/plugin/herdr-plugin.toml > "$PDIR/herdr-plugin.toml"
grep -q '^id = "apply"' "$PDIR/herdr-plugin.toml" \
  && ok "the action id survived the id rewrite" || bad "the action id was rewritten too"
command herdr plugin link "$PDIR" >/dev/null \
  && ok "the plugin links" || bad "plugin link failed"
h tab close "$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="git") | .tab_id')" >/dev/null
h plugin action invoke "$PLUGIN_ID.apply" >/dev/null 2>&1   # session-scoped: the
# topology lives in hdev-test, and a bare `herdr plugin action invoke` would run it
# against the default session instead.
n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label=="git")] | length')
[[ "$n" == 1 ]] && ok "the plugin action repairs a closed managed tab" || bad "git tab count = $n after repair"

# 7b. The jump must still land after repair. This is the whole reason tab-goto.sh
#     resolves by label: repair APPENDS (herdr 0.8.2 has no `tab move`), so the
#     repaired git tab is now last — after the unmanaged `notes` tab added earlier —
#     and a position-based lookup would not land reliably on git at all.
GITTAB=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="git") | .tab_id')
HERDR_ACTIVE_WORKSPACE_ID="$WS" HERDR_SESSION="$SESSION" ~/.config/herdr/tab-goto.sh git
ACTIVE=$(h workspace get "$WS" | jq -r '.result.workspace.active_tab_id')
[[ "$ACTIVE" == "$GITTAB" ]] \
  && ok "a label jump lands on the repaired tab ($GITTAB)" \
  || bad "label jump landed on $ACTIVE, expected the repaired $GITTAB"

# 8. Notification DELIVERY is not switched off. This deliberately does not claim to
#    prove rendering: the gate runs a headless named session with no attached client,
#    where delivery = "herdr" (in-app toasts) legitimately returns
#    no_foreground_client. Rendering was proven manually in Task 8 and cannot be
#    re-proven here without attaching a client.
#
#    What this DOES catch is `disabled` — the state pinning `onboarding = false`
#    silently produced, which removes every failure message a detached keybinding or
#    plugin action can emit. The mocked suite cannot see it: it only knows that
#    `notification show` was invoked.
#
#    NotificationShowReason is ["shown","disabled","rate_limited",
#    "no_foreground_client","busy"]. Only busy and rate_limited are transient;
#    no_foreground_client is a stable property of a headless run, not something a
#    retry can clear.
enabled=0
for i in 1 2 3 4 5; do
  r=$(h notification show "gate" --body "live gate probe" | jq -r '.result.reason')
  case "$r" in
    shown|no_foreground_client) enabled=1; break ;;   # delivery is on
    disabled)                   break ;;              # the real defect; fail fast
    busy|rate_limited)          sleep 1.5 ;;          # transient; retry
    *)                          break ;;
  esac
done
(( enabled )) && ok "notification delivery is enabled (reason: $r)" \
  || bad "notification delivery is off (last reason: ${r:-none}) — failure feedback would be invisible"

print -r -- "=== $pass passed, $fail failed ==="
(( fail == 0 ))
