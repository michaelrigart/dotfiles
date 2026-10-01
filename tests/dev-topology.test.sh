#!/usr/bin/env zsh
# Live gate for dev/layout.sh against the REAL herdr binary.
#
# Mocked tests cannot detect CLI churn: the stub accepts whatever it was written to
# accept and keeps passing after herdr changes a flag or a JSON shape. Only the real
# binary can, so this runs against it — in an isolated named session, never the live
# one.
#
# It runs the SOURCE copies of layout.sh, tab-goto.sh, the zsh functions and wt-teardown
# through scratch wrappers, and keeps layout.sh's lock files in the scratch directory.
#
# Run manually, unsandboxed: ./tests/dev-topology.test.sh
# test-requires: unsandboxed, herdr  # drives the real herdr binary, whose socket the sandbox denies
emulate -L zsh
set -u
setopt no_bg_nice   # see the same note in layout.sh
SESSION=dev-test
TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
h() { command herdr --session "$SESSION" "$@" }

ROOT="${0:A:h:h}"
SRC_LAYOUT="$ROOT/dot_config/herdr/executable_layout.sh"
SRC_TABGOTO="$ROOT/dot_config/herdr/executable_tab-goto.sh"
SRC_FUNCS="$ROOT/dot_config/zsh/functions"
SRC_TEARDOWN="$ROOT/dot_local/bin/executable_wt-teardown"
for f in "$SRC_LAYOUT" "$SRC_TABGOTO" "$SRC_FUNCS" "$SRC_TEARDOWN"; do
  [[ -r "$f" ]] || { print -ru2 -- "dev-topology: missing $f"; exit 2 }
done
STATE_BEFORE=$(ls ~/.local/state/herdr-layout 2>/dev/null | wc -l | tr -d ' ')

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
  if [[ -n "${SCRATCH:-}" && "$SCRATCH" == $TMP_BASE/dev-live.* ]]; then
    rm -rf -- "$SCRATCH"
  fi
}
trap cleanup EXIT HUP INT TERM

SCRATCH="$(mktemp -d "$TMP_BASE/dev-live.XXXXXX")" || exit 1
REPO="$SCRATCH/Code/Test/proj"
mkdir -p "$REPO" || exit 1
git -C "$REPO" init -q || exit 1
# Resolved: mktemp hands back /tmp/... or /var/folders/..., layout.sh stores
# "${repo:A}" (/private/...), so an unresolved comparison never matches a pane cwd.
REPO="${REPO:A}"

mkdir -p "$SCRATCH/bin" "$SCRATCH/state" || exit 1
print -r -- "#!/bin/sh
exec zsh '$SRC_LAYOUT' \"\$@\"" > "$SCRATCH/bin/layout.sh"
print -r -- "#!/bin/sh
exec zsh '$SRC_TEARDOWN' \"\$@\"" > "$SCRATCH/bin/wt-teardown"
chmod +x "$SCRATCH/bin/layout.sh" "$SCRATCH/bin/wt-teardown"
export PATH="$SCRATCH/bin:$PATH" DEV_LAYOUT="$SCRATCH/bin/layout.sh" XDG_STATE_HOME="$SCRATCH/state"

# Start clean as well as finish clean: a run killed mid-way leaves state behind.
# STOP before DELETE — `session delete` only acts on a stopped session, so deleting
# first silently fails against a surviving server and the persisted state is then
# restored on the next start. Same order as cleanup below.
h server stop >/dev/null 2>&1 || true
command herdr session delete "$SESSION" >/dev/null 2>&1 || true

print -r -- "=== live topology gate (session: $SESSION) ==="

# 1. Cold bootstrap: no server running.
h server stop >/dev/null 2>&1 || true
HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 "$DEV_LAYOUT" "$REPO" \
  && ok "cold bootstrap builds a workspace" || bad "cold bootstrap failed"

# 2. Topology is what we think it is.
WS=$(h workspace list | jq -r '.result.workspaces[0].workspace_id')
for l in agents runtime; do
  n=$(h tab list --workspace "$WS" | jq -r --arg l "$l" \
        '[.result.tabs[] | select(.label == $l)] | length')
  [[ "$n" == 1 ]] && ok "exactly one '$l' tab" || bad "'$l' tab count = $n"
done
# Measured against herdr 0.9.3 in this gate: a plain `workspace create --cwd` workspace
# carries NO worktree provenance (only `worktree open` records it, section 6b), so
# layout.sh finds it by the fallback, a pane at the repo root. Pin whichever identity the
# real binary reports, so a change in either direction is visible, and a workspace that
# layout.sh could not re-find fails here rather than as a duplicate later.
ident=$(h workspace list | jq -r --arg d "$REPO" --argjson panes "$(h pane list | jq -c .)" '
  .result.workspaces[] as $w
  | if ($w.worktree.checkout_path? // "") == $d then "provenance"
    elif $w.worktree == null and any($panes.result.panes[]; .workspace_id == $w.workspace_id and .cwd == $d)
    then "pane-cwd" else empty end' | head -1)
[[ -n "$ident" ]] \
  && ok "the bootstrapped workspace is identifiable by $ident" \
  || bad "the bootstrapped workspace has neither provenance for $REPO nor a bare pane at it"
# The editor tab is lazy: nothing builds it, alt+e does. Asserting its ABSENCE here is
# the only thing standing between "layout.sh stopped building it" and "layout.sh still
# builds it and the mocked suite is wrong about the real binary".
n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label == "editor")] | length')
[[ "$n" == 0 ]] && ok "no editor tab is built" || bad "editor tab count = $n, expected 0"

# ...and then the keybinding's script actually creates one against the real server.
et=$(HERDR_SESSION="$SESSION" HERDR_ACTIVE_WORKSPACE_ID="$WS" \
       "$DEV_LAYOUT" --make-tab editor 2>&1)
n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label == "editor")] | length')
[[ "$n" == 1 ]] && ok "--make-tab creates the editor tab" || bad "after --make-tab, editor count = $n ($et)"
# Idempotent: a second press must focus the same tab, not append another.
et2=$(HERDR_SESSION="$SESSION" HERDR_ACTIVE_WORKSPACE_ID="$WS" \
        "$DEV_LAYOUT" --make-tab editor 2>&1)
n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label == "editor")] | length')
[[ "$n" == 1 && "$et2" == "$et" ]] \
  && ok "--make-tab is idempotent and returns the same tab id" \
  || bad "second --make-tab: count=$n first=$et second=$et2"
AT=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="agents") | .tab_id')
n=$(h pane list --workspace "$WS" | jq -r --arg t "$AT" '[.result.panes[] | select(.tab_id==$t)] | length')
[[ "$n" == 2 ]] && ok "agents holds 2 panes" || bad "agents holds $n panes"

# 3. Idempotency: a second run focuses, never duplicates.
second_rc=0
HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 "$DEV_LAYOUT" "$REPO" >/dev/null \
  || second_rc=$?
n=$(h workspace list | jq -r '.result.workspaces | length')
[[ "$second_rc" == 0 && "$n" == 1 ]] \
  && ok "a second run does not duplicate" \
  || bad "second run rc=$second_rc with $n workspaces"

# 4. Extra tabs survive.
h tab create --workspace "$WS" --label notes >/dev/null
notes_rc=0
HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 "$DEV_LAYOUT" "$REPO" >/dev/null \
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
( HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 HL_LOCK_DELAY=3 "$DEV_LAYOUT" "$REPO2" ) &
B=$!
sleep 0.2
a_rc=0
HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 "$DEV_LAYOUT" "$REPO2" >/dev/null 2>&1 \
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

# 6b. Native worktree flow: the shell lifecycle creates/prepares and Git-locks the
# checkout; Herdr opens it natively so provenance/grouping are real. This is the
# path used day to day (`wt`), not an ordinary workspace pointed at a linked
# checkout.
PRIMARY="$SCRATCH/Code/Test/worktree-proj"
mkdir -p "$PRIMARY" || exit 1
git -C "$PRIMARY" init -q -b main || exit 1
git -C "$PRIMARY" -c user.name=gate -c user.email=gate@example.invalid \
  -c commit.gpgsign=false commit -q --allow-empty -m init || exit 1
PRIMARY="${PRIMARY:A}"
WT="$SCRATCH/Code/Test/worktree-proj-live-wt"
wt_rc=0
( cd "$PRIMARY" && source "$SRC_FUNCS" && \
  HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 wt live-wt ) >/dev/null 2>&1 || wt_rc=$?
WT="${WT:A}"
WWS=$(h workspace list | jq -r --arg d "$WT" \
  '.result.workspaces[] | select(.worktree.checkout_path == $d) | .workspace_id')
wn=$(h tab list --workspace "$WWS" 2>/dev/null | jq -r \
  '[.result.tabs[] | select(.label=="agents" or .label=="runtime")] | length')
lock_reason=$(git -C "$PRIMARY" worktree list --porcelain | sed -n '/worktree .*worktree-proj-live-wt$/,/^$/s/^locked //p')
[[ "$wt_rc" == 0 && -n "$WWS" && "$wn" == 2 \
   && "$lock_reason" == "wt-managed; remove with command wt-rm" ]] \
  && ok "wt creates a two-tab native workspace with the lifecycle lock" \
  || bad "wt rc=$wt_rc workspace=${WWS:-none} managed-tabs=${wn:-none} lock=${lock_reason:-none}"

# Reopen must return to the same native workspace, not create an ordinary duplicate.
reopen_rc=0
( cd "$PRIMARY" && source "$SRC_FUNCS" && \
  HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 wt live-wt ) >/dev/null 2>&1 || reopen_rc=$?
wns=$(h workspace list | jq -r --arg d "$WT" \
  '[.result.workspaces[] | select(.worktree.checkout_path == $d)] | length')
[[ "$reopen_rc" == 0 && "$wns" == 1 ]] \
  && ok "wt reopens the same native workspace" \
  || bad "wt reopen rc=$reopen_rc yielded $wns native workspaces"

# Herdr exposes one --force; Git requires two to cross our ownership lock. Exercise
# the real binary, then restore/focus the workspace in case Herdr closed its UI state
# before Git reported the refusal.
native_rm_rc=0
h worktree remove --workspace "$WWS" --force >/dev/null 2>&1 || native_rm_rc=$?
[[ "$native_rm_rc" != 0 && -d "$WT" ]] \
  && ok "Herdr native removal cannot bypass wt-rm teardown" \
  || bad "native removal rc=$native_rm_rc checkout-exists=$([[ -d "$WT" ]] && print yes || print no)"
( cd "$PRIMARY" && source "$SRC_FUNCS" && \
  HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 wt live-wt ) >/dev/null 2>&1 || true

# The approved teardown path closes Herdr state, crosses only its own Git lock after
# all checks, removes the checkout and deletes the merged branch.
custom_rm_rc=0
( cd "$PRIMARY" && source "$SRC_FUNCS" && HERDR_SESSION="$SESSION" wt-rm live-wt ) >/dev/null 2>&1 || custom_rm_rc=$?
remaining_wt=$(h workspace list | jq -r --arg d "$WT" \
  '[.result.workspaces[] | select(.worktree.checkout_path == $d)] | length')
[[ "$custom_rm_rc" == 0 && ! -d "$WT" && "$remaining_wt" == 0 ]] \
  && ok "the sourced wt-rm closes Herdr and safely removes the checkout" \
  || bad "wt-rm rc=$custom_rm_rc checkout-exists=$([[ -d "$WT" ]] && print yes || print no) workspaces=$remaining_wt"

# 7. dev re-adds a closed eager tab (what the retired plugin action did), and a manual
#    split never stops dev from focusing (bug 2).
close_rc=0
h tab close "$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="runtime") | .tab_id')" >/dev/null \
  || close_rc=$?
# This CLI reports some failures as error envelopes with exit 0, so the close is proven
# by the tab count, not its exit status.
closed_n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label=="runtime")] | length')
[[ "$close_rc" == 0 && "$closed_n" == 0 ]] \
  && ok "the runtime tab is closed before the re-add" \
  || bad "close rc=$close_rc, runtime tabs after the close=$closed_n, expected 0"
readd_rc=0
HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 "$DEV_LAYOUT" "$REPO" >/dev/null 2>&1 || readd_rc=$?
n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label=="runtime")] | length')
[[ "$readd_rc" == 0 && "$n" == 1 ]] \
  && ok "dev re-adds a closed runtime tab" \
  || bad "re-add rc=$readd_rc, runtime tabs=$n"
# The agents panes, taken BEFORE the split: herdr lists a new pane right after the pane it
# split, so afterwards the second entry is the new pane, not the right-hand agent.
APANES=( ${(f)"$(h pane list --workspace "$WS" | jq -r --arg t "$AT" \
  '.result.panes[] | select(.tab_id==$t) | .pane_id')"} )
manual_split_rc=0
h pane split --pane "$(h pane list --workspace "$WS" | jq -r --arg t "$AT" \
  '[.result.panes[] | select(.tab_id==$t)][0].pane_id')" --direction down --no-focus >/dev/null \
  || manual_split_rc=$?
n=$(h pane list --workspace "$WS" | jq -r --arg t "$AT" '[.result.panes[] | select(.tab_id==$t)] | length')
[[ "$manual_split_rc" == 0 && "$n" == 3 ]] \
  && ok "the manual split gives the agents tab 3 panes" \
  || bad "manual split rc=$manual_split_rc, agents panes=$n, expected 3"
split_rc=0
HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 "$DEV_LAYOUT" "$REPO" >/dev/null 2>&1 || split_rc=$?
[[ "$split_rc" == 0 ]] && ok "dev still succeeds after a manual split" \
                       || bad "dev after a manual split rc=$split_rc"

# 7a. smart-splits' Herdr dispatcher is live, not merely named in config. Move to the
# left agents pane, invoke right, and wait for the detached plugin action to focus its
# neighbor. Neovim uses the same plugin's native Herdr backend at split edges.
if h plugin list | grep -Fq 'smart-splits.nvim'; then
  left="${APANES[1]}"; right="${APANES[2]}"
  # Focus left deterministically by starting from right and moving left.
  h pane focus --pane "$right" --direction left >/dev/null 2>&1 || true
  smart_rc=0
  h plugin action invoke smart-splits.nvim.right >/dev/null 2>&1 || smart_rc=$?
  focused=""
  for i in {1..20}; do
    focused=$(h pane list --workspace "$WS" | jq -r \
      '.result.panes[] | select(.focused == true) | .pane_id' | head -1)
    [[ "$focused" == "$right" ]] && break
    sleep 0.25
  done
  [[ "$smart_rc" == 0 && "$focused" == "$right" ]] \
    && ok "smart-splits moves focus across Herdr panes" \
    || bad "smart-splits invoke rc=$smart_rc focused=${focused:-none}, expected $right"
else
  bad "smart-splits.nvim is not linked in Herdr"
fi

# 7b. The jump must still land after the re-add. This is the whole reason tab-goto.sh
#     resolves by label: the re-add APPENDS (herdr 0.8.2 has no `tab move`), so the
#     re-added runtime tab is now last — after the unmanaged `notes` tab added
#     earlier — and a position-based lookup would not land reliably on it at all.
RTAB=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="runtime") | .tab_id')
jump_rc=0
HERDR_ACTIVE_WORKSPACE_ID="$WS" HERDR_SESSION="$SESSION" zsh "$SRC_TABGOTO" runtime \
  || jump_rc=$?
ACTIVE=$(h workspace get "$WS" | jq -r '.result.workspace.active_tab_id')
[[ "$jump_rc" == 0 && "$ACTIVE" == "$RTAB" ]] \
  && ok "a label jump lands on the repaired tab ($RTAB)" \
  || bad "label jump landed on $ACTIVE, expected the repaired $RTAB"

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

# Persisted session schema. wt-rm inspects a STOPPED session's session.json to decide
# whether it still references a checkout, and pins `.version == 3`, refusing anything
# else rather than guessing at an unknown shape. That is the right fail-closed call,
# but it means a herdr upgrade that bumps the schema turns into "wt-rm refuses to
# remove worktrees" — a confusing failure far from its cause. Assert it here so a
# schema bump surfaces as a test failure instead.
# NO fallback to the default session. An earlier version fell back to
# ~/.config/herdr/session.json whenever the named file was missing, which meant a
# relocated or renamed state path still returned 3 from unrelated state and passed —
# the gate would stay green through exactly the change it exists to catch. A missing
# named-session file IS the failure.
# Herdr writes a named session's session.json on STOP, not while it runs — and a
# stopped session is precisely what wt-rm inspects, since it can still restore panes
# into a checkout later. So stop first, then assert, and let cleanup delete.
h server stop >/dev/null 2>&1 || true
for i in {1..20}; do
  [[ -r "$HOME/.config/herdr/sessions/$SESSION/session.json" ]] && break
  sleep 0.25
done
SSTATE="$HOME/.config/herdr/sessions/$SESSION/session.json"
if [[ ! -r "$SSTATE" ]]; then
  bad "no readable persisted state at $SSTATE — wt-rm inspects this path for stopped sessions"
else
  SVER=$(jq -r '.version' "$SSTATE" 2>/dev/null)
  [[ "$SVER" == 3 ]] \
    && ok "persisted session schema is version 3, as wt-rm requires" \
    || bad "persisted session schema is '${SVER:-unreadable}', not 3 — wt-rm will refuse worktree teardown"
fi

STATE_AFTER=$(ls ~/.local/state/herdr-layout 2>/dev/null | wc -l | tr -d ' ')
[[ "$STATE_AFTER" == "$STATE_BEFORE" ]] \
  && ok "no lock file leaked into ~/.local/state/herdr-layout" \
  || bad "lock files in ~/.local/state/herdr-layout went from $STATE_BEFORE to $STATE_AFTER"
pl_rc=0
pl=$(command herdr plugin list 2>&1) || pl_rc=$?
if (( pl_rc )); then
  bad "herdr plugin list failed (rc=$pl_rc), so test plugin registrations were not checked: $pl"
elif print -r -- "$pl" | grep -q 'dev.layout.test'; then
  bad "a dev.layout.test plugin registration exists"
else
  ok "no test plugin registration exists"
fi

print -r -- "=== $pass passed, $fail failed ==="
(( fail == 0 ))
