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
emulate -L zsh
set -u
setopt no_bg_nice   # see the same note in layout.sh
SESSION=hdev-test
PLUGIN_ID=dev.layout.test
TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
h() { command herdr --session "$SESSION" "$@" }

pass=0 fail=0
ok()   { print -r -- "  PASS: $1"; pass=$((pass+1)) }
bad()  { print -r -- "  FAIL: $1"; fail=$((fail+1)) }

cleanup() {
  # `server stop` does NOT delete session state — herdr persists workspaces to
  # ~/.config/herdr/sessions/<name> and restores them next start. Without an explicit
  # delete, every run inherited the previous run's workspaces and `workspace list`
  # answered about stale ones.
  h server stop >/dev/null 2>&1 || true
  command herdr session delete "$SESSION" >/dev/null 2>&1 || true
  command herdr plugin unlink "$PLUGIN_ID" >/dev/null 2>&1 || true
  if [[ -n "${SCRATCH:-}" && "$SCRATCH" == $TMP_BASE/hdev-live.* ]]; then
    rm -rf -- "$SCRATCH"
  fi
}
trap cleanup EXIT HUP INT TERM

SCRATCH="$(mktemp -d "$TMP_BASE/hdev-live.XXXXXX")" || exit 1
REPO="$SCRATCH/Code/Test/proj"
mkdir -p "$REPO" || exit 1
git -C "$REPO" init -q || exit 1
# Resolved: mktemp hands back /tmp/... or /var/folders/..., layout.sh stores
# "${repo:A}" (/private/...), so an unresolved comparison never matches a pane cwd.
REPO="${REPO:A}"

# Start clean as well as finish clean: a run killed mid-way leaves state behind.
# STOP before DELETE — `session delete` only acts on a stopped session, so deleting
# first silently fails against a surviving server and the persisted state is then
# restored on the next start. Same order as cleanup below.
h server stop >/dev/null 2>&1 || true
command herdr session delete "$SESSION" >/dev/null 2>&1 || true

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
second_rc=0
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO" >/dev/null \
  || second_rc=$?
n=$(h workspace list | jq -r '.result.workspaces | length')
[[ "$second_rc" == 0 && "$n" == 1 ]] \
  && ok "a second run does not duplicate" \
  || bad "second run rc=$second_rc with $n workspaces"

# 4. Extra tabs survive.
h tab create --workspace "$WS" --label notes >/dev/null
notes_rc=0
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO" >/dev/null \
  || notes_rc=$?
[[ "$notes_rc" == 0 ]] \
  && h tab list --workspace "$WS" | jq -e '.result.tabs[] | select(.label=="notes")' >/dev/null \
  && ok "an unmanaged tab survives" || bad "the unmanaged tab was removed"

# 5. Concurrency, on the schedule that actually breaks it: B scans, A builds and
#    releases, THEN B acquires. Launching two at once mostly proves nothing.
REPO2="$SCRATCH/Code/Test/proj2"
mkdir -p "$REPO2" || exit 1
git -C "$REPO2" init -q || exit 1
REPO2="${REPO2:A}"
# B sleeps BEFORE taking the lock, so it arrives after A has built and released —
# the stale-observation schedule. Launching two at once would usually serialise
# harmlessly and prove nothing.
( HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 HL_LOCK_DELAY=3 ~/.config/herdr/layout.sh "$REPO2" ) &
B=$!
sleep 0.2
a_rc=0
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO2" >/dev/null 2>&1 \
  || a_rc=$?
b_rc=0
wait $B 2>/dev/null || b_rc=$?
n=$(h pane list | jq -r --arg d "$REPO2" \
      '[.result.panes[] | select(.cwd == $d) | .workspace_id] | unique | length')
[[ "$a_rc" == 0 && "$b_rc" == 0 && "$n" == 1 ]] \
  && ok "the delayed-acquisition race yields one workspace" \
  || bad "race runs rc=$a_rc/$b_rc yielded $n workspaces"

# 6. Split directions, not just pane counts. Two panes side by side and two stacked
#    are both "2"; only the geometry says which layout was actually built.
RT=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="runtime") | .tab_id')
h pane layout --pane "$(h pane list --workspace "$WS" | jq -r --arg t "$RT" \
    '[.result.panes[] | select(.tab_id==$t)][0].pane_id')" \
  | jq -e '[.result.layout.splits[].direction] == ["down"]' >/dev/null \
  && ok "runtime is split down" || bad "runtime is not split down"

# 7. The plugin: link under a DISTINCT id, invoke it, unlink. Registration is global,
#    so reusing dev.layout would let this teardown unlink the real one.
PDIR="$SCRATCH/plugin"
mkdir -p "$PDIR" || exit 1
# Match the plugin id EXACTLY. `s/^id = .*/` also rewrites the [[actions]] entry's
# `id = "apply"` — TOML nested tables are not indented — which renames the action
# too, leaving "$PLUGIN_ID.apply" pointing at nothing.
sed 's|^id = "dev.layout"$|id = "'"$PLUGIN_ID"'"|' \
  ~/.config/herdr/plugin/herdr-plugin.toml > "$PDIR/herdr-plugin.toml" || exit 1
grep -q '^id = "apply"' "$PDIR/herdr-plugin.toml" \
  && ok "the action id survived the id rewrite" || bad "the action id was rewritten too"
command herdr plugin link "$PDIR" >/dev/null \
  && ok "the plugin links" || bad "plugin link failed"
close_rc=0
h tab close "$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="git") | .tab_id')" >/dev/null \
  || close_rc=$?
closed_n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label=="git")] | length')
# The action's context is taken from the FOCUSED workspace, so focus it first —
# otherwise the plugin repairs whichever workspace happens to be focused.
focus_rc=0
h workspace focus "$WS" >/dev/null || focus_rc=$?
invoke_rc=0
h plugin action invoke "$PLUGIN_ID.apply" >/dev/null 2>&1 || invoke_rc=$?   # session-scoped: the
# topology lives in hdev-test, and a bare `herdr plugin action invoke` would run it
# against the default session instead.
# `plugin action invoke` returns while the action is still "running" — poll rather
# than assuming it finished.
for i in {1..20}; do
  n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label=="git")] | length')
  [[ "$n" == 1 ]] && break
  sleep 0.5
done
[[ "$close_rc" == 0 && "$closed_n" == 0 && "$focus_rc" == 0 && "$invoke_rc" == 0 && "$n" == 1 ]] \
  && ok "the plugin action repairs a closed managed tab" \
  || bad "repair preconditions/actions rc=$close_rc/$focus_rc/$invoke_rc, counts=$closed_n->$n"

# 7b. The jump must still land after repair. This is the whole reason tab-goto.sh
#     resolves by label: repair APPENDS (herdr 0.8.2 has no `tab move`), so the
#     repaired git tab is now last — after the unmanaged `notes` tab added earlier —
#     and a position-based lookup would not land reliably on git at all.
GITTAB=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="git") | .tab_id')
jump_rc=0
HERDR_ACTIVE_WORKSPACE_ID="$WS" HERDR_SESSION="$SESSION" ~/.config/herdr/tab-goto.sh git \
  || jump_rc=$?
ACTIVE=$(h workspace get "$WS" | jq -r '.result.workspace.active_tab_id')
[[ "$jump_rc" == 0 && "$ACTIVE" == "$GITTAB" ]] \
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
#    "no_foreground_client","busy"]. Observed live: a headless session returns `busy`
#    persistently, not transiently — retrying it five times still ended in `busy`, so
#    treating it as transient failed a working setup. Only `disabled` means delivery
#    is actually off, and that is the single state this gate exists to catch.
enabled=0
for i in 1 2 3 4 5; do
  r=$(h notification show "gate" --body "live gate probe" | jq -r '.result.reason')
  case "$r" in
    shown|no_foreground_client|busy) enabled=1; break ;;  # delivery is on; see below
    disabled)                   break ;;              # the real defect; fail fast
    rate_limited)               sleep 1.5 ;;          # transient; retry
    *)                          break ;;
  esac
done
(( enabled )) && ok "notification delivery is enabled (reason: $r)" \
  || bad "notification delivery is off (last reason: ${r:-none}) — failure feedback would be invisible"

print -r -- "=== $pass passed, $fail failed ==="
(( fail == 0 ))
