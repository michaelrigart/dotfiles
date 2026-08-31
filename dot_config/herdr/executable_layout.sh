#!/usr/bin/env zsh
# layout.sh — build, focus or repair a project's Herdr workspace.
# Managed by chezmoi (source: dot_config/herdr/executable_layout.sh).
#
#   layout.sh <repo-path>   build-or-focus, called by dev from a shell
#   layout.sh --current     repair in place, called by the dev.layout.apply plugin
#   layout.sh --worktree <primary> <checkout>
#                           open/adopt a native Herdr worktree workspace
#
# The single definition of what a project workspace looks like. Both entry points go
# through it, so there is no second copy to drift.
emulate -L zsh
# no_bg_nice: zsh sets BG_NICE by default, so `cmd &` renices the job. That renice
# fails outright where setpriority is denied (a sandbox, some CI), taking the
# backgrounded server with it — and even where it succeeds, quietly deprioritising the
# Herdr server every agent runs inside is not what anyone wants.
setopt local_options no_unset pipe_fail no_bg_nice

MANAGED_TABS=(agents editor runtime git)
BUILDING_SUFFIX=" (building)"
# Codex's documented role here is reviewer, not implementer, so its panes launch
# unable to write. Without this they inherit workspace-write with $HOME writable.
# Read-only is not confinement — reads are still unrestricted — but it removes the
# write half. Launch an implementer session by hand when you actually want one.
CODEX_CMD="codex --sandbox read-only --ask-for-approval never"

die() { print -ru2 -- "layout.sh: $*"; exit 1 }

# hl_notify — the only feedback a plugin action has. Herdr runs plugin commands and
# custom keybindings detached, so stderr never reaches the TUI: an action whose result
# is buried in a log file is indistinguishable from a broken keybinding. Requires
# [ui.toast] delivery to be set — the shipped default is "off".
hl_notify() {
  command herdr notification show "$1" --body "$2" >/dev/null 2>&1 || true
}

# hl_die_notify — die, but visibly. Every failure inside --current must reach the UI:
# a lock timeout or a classification error is exactly as invisible as a wrong verdict
# when the action runs detached, and the user is left pressing a key that does nothing.
hl_die_notify() {
  hl_notify "Project layout" "$*"
  die "$*"
}

# hl_git — git with its routing environment cleared, mirroring _wt_git in
# zsh/functions. An exported GIT_DIR or GIT_WORK_TREE silently redirects git at
# another checkout, which would make the worktree guard answer about the wrong repo.
hl_git() {
  command env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE \
    git "$@"
}

# hl_api — run a herdr CLI call, return its JSON on stdout. Non-zero on failure, with
# the server's message. Every call goes through here so failures are uniform: a
# previous shape returned 0 from every step while the layout silently failed, and
# exit status was no guard.
hl_api() {
  local out rc
  out="$(command herdr "$@" 2>&1)"; rc=$?
  if (( rc != 0 )); then
    print -ru2 -- "layout.sh: herdr $* failed: $out"
    return 1
  fi
  if [[ -n "$out" ]]; then
    # Validate at the boundary, once. Without this, malformed JSON reaches every jq
    # consumer downstream, each of which discards its status inside a command
    # substitution or array assignment, so a corrupt response became plausible state.
    if ! print -r -- "$out" | jq -e . >/dev/null 2>&1; then
      print -ru2 -- "layout.sh: herdr $* returned invalid JSON"
      return 1
    fi
    # Envelope check on the PARSED top level, not a substring match on '"error"'.
    # A substring test rejects valid data that merely contains the word — a tab the
    # user labelled "error", an agent status, a repo path. It did catch a genuine
    # error envelope; this keeps that while dropping the false positives.
    if print -r -- "$out" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1; then
      print -ru2 -- "layout.sh: herdr $* failed: $out"
      return 1
    fi
  fi
  print -r -- "$out"
}

# hl_api_json — for calls that MUST return a payload: list, layout, create, split.
# Empty output is legitimate for focus/run/rename/close, but for these it is a failure
# wearing a success's clothes: `jq` exits 0 on empty input, so an empty response
# degraded into "no workspace found" (→ build a duplicate) or "provisional" (→ let
# repair mutate), both with rc=0.
hl_api_json() {
  local out
  out="$(hl_api "$@")" || return 1
  if [[ -z "$out" ]]; then
    print -ru2 -- "layout.sh: herdr $* returned an empty response"
    return 1
  fi
  print -r -- "$out"
}

# hl_server_ready — is a server actually answering? `herdr status server` exits 0 even
# while reporting "not running", so exit status is not a readiness signal, and there is
# no CLI `ping`. The probe is therefore a real call that fails when the server is down.
hl_server_ready() {
  local out
  out="$(command herdr workspace list 2>&1)" || return 1
  [[ "$out" == *server_not_running* ]] && return 1
  return 0
}

hl_ensure_server() {
  hl_server_ready && return 0
  # `herdr server` runs in the foreground: background and detach it explicitly. A
  # second dev racing this must neither fail nor start a second server, so the start
  # is fire-and-forget and readiness is what we actually wait on.
  (command herdr server >/dev/null 2>&1 &) || true
  local tries="${HL_READY_TRIES:-40}" i=1
  while (( i <= tries )); do
    hl_server_ready && return 0
    sleep 0.25
    (( i++ ))
  done
  die "the herdr server did not become ready after $(( tries / 4 ))s"
}

# hl_label — the display label. Deterministic from the path so it is stable, but
# purely cosmetic: identity is the canonical path, checked via pane cwd.
hl_label() {
  # BOTH sides resolved. dev hands over "${repo:A}", so on macOS a repo under /tmp
  # arrives as /private/tmp/... while $HOME is still /tmp/... — the prefix never
  # matches and the label silently degrades to the full absolute path. The same
  # applies to any ~/Code behind a symlink, which _wt_assert_worktree already warns
  # about: "git reports real paths, and ~/Code may sit behind a symlink."
  local repo="${1:A}" home="${HOME:A}"
  case "$repo" in
    "$home/Code/"*) print -r -- "${repo#$home/Code/}" ;;
    "$home/"*)      print -r -- "${repo#$home/}" ;;
    *)              print -r -- "$repo" ;;
  esac
}

# hl_lock — serialise per canonical repo path. Acquired BEFORE any scan, and the scan
# repeated underneath it: classifying first and locking second permits a delayed
# duplicate, where B scans empty, waits while A builds and releases, then acts on its
# stale observation and creates a second workspace for the same repo.
#
# `zsystem flock`, matching _wt_lock in zsh/functions — NOT a mkdir sentinel. The
# reason is stated there: an fcntl record lock is released by the kernel when the
# process dies, "the backstop for every path an explicit unlock cannot reach." A mkdir
# lock has no such backstop, so one SIGKILL would wedge that repository until someone
# removed the directory by hand.
#
# zsystem opens but does not create the lock file, so it must exist first.
hl_lock() {
  local key="${1//\//-}" dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-layout"
  mkdir -p "$dir"
  HL_LOCKFILE="$dir/${key#-}.lock"
  : >>"$HL_LOCKFILE"
  zmodload -F zsh/system b:zsystem 2>/dev/null

  [[ -n "${HL_LOCK_DELAY:-}" ]] && sleep "$HL_LOCK_DELAY"

  # Returns non-zero rather than calling die: `die` exits the process, so a caller's
  # `|| hl_die_notify` could never run and lock contention stayed stderr-only —
  # invisible under detached execution.
  local t="${HL_LOCK_TIMEOUT:-10}"
  if ! zsystem flock -t "$t" "$HL_LOCKFILE" 2>/dev/null; then
    print -ru2 -- "layout.sh: another layout.sh has held the lock for $1 for over ${t}s"
    return 1
  fi
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "LOCK-ACQUIRED"
  return 0
}

# hl_find_workspace — the workspace whose panes live at this path, if any.
# Identity is the canonical path, not the label: WorkspaceInfo carries no cwd, but
# PaneInfo carries `cwd`, and labels are mutable and non-unique. A workspace whose
# label happens to match but whose panes are elsewhere is simply not a match.
hl_find_workspace() {
  local repo="$1" panes
  local -a ids
  # stderr, not stdout: this function's stdout IS its return value (ws="$(...)"), so a
  # trace line printed there would be captured into the workspace id and corrupt it.
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "SCAN"
  [[ -n "${HL_SCAN_DELAY:-}" ]] && sleep "$HL_SCAN_DELAY"
  panes="$(hl_api_json pane list)" || return 1
  # Captured first: inside `ids=( $(...) )` the pipeline's status is discarded, so a
  # jq failure silently became "no matches" — indistinguishable from a repo that
  # genuinely has no workspace, and the caller would build a duplicate.
  local matched
  matched="$(print -r -- "$panes" | jq -r --arg d "$repo" \
              '.result.panes[] | select(.cwd == $d) | .workspace_id' | sort -u)" \
    || { print -ru2 -- "layout.sh: could not read workspace ids from pane list"; return 1 }
  ids=( ${(f)matched} )
  ids=( ${ids:#} )
  (( ${#ids} == 0 )) && return 0
  (( ${#ids} > 1 )) && die "panes for $repo span workspaces: ${ids[*]} — refusing to guess"
  print -r -- "${ids[1]}"
}

# hl_is_native_worktree_workspace <workspace-id> <canonical-checkout>
# A linked checkout is safe to repair only when Herdr itself records matching
# worktree provenance. A workspace opened by plain `workspace create` has the same
# pane cwd but is not grouped or discoverable through the worktree lifecycle.
hl_is_native_worktree_workspace() {
  local ws="$1" repo="$2" list count checkout linked
  list="$(hl_api_json workspace list)" || return 1
  count=$(print -r -- "$list" | jq -r --arg w "$ws" \
    '[.result.workspaces[] | select(.workspace_id == $w)] | length') || return 1
  [[ "$count" == 1 ]] || return 1
  checkout=$(print -r -- "$list" | jq -er --arg w "$ws" \
    '.result.workspaces[] | select(.workspace_id == $w) | .worktree.checkout_path | select(type == "string" and length > 0)' 2>/dev/null) \
    || return 1
  linked=$(print -r -- "$list" | jq -er --arg w "$ws" \
    '.result.workspaces[] | select(.workspace_id == $w) | .worktree.is_linked_worktree | if type == "boolean" then tostring else error("not boolean") end' 2>/dev/null) \
    || return 1
  [[ "$linked" == true && "${checkout:A}" == "$repo" ]]
}

# hl_classify <workspace_id> <final-label> — complete / provisional / malformed:<why>,
# over the MANAGED baseline only.
#
# Counting all tabs is wrong in both directions: alt+t exists, so a user's fifth tab is
# ordinary use and must not demote a healthy workspace; and a dead build can carry all
# four managed names while missing a split, which a name-only check would certify.
#
# Malformed never triggers repair. Fixing a duplicated label means choosing which one
# to destroy, and nothing here knows enough to choose safely.
hl_classify() {
  local ws="$1" final="$2" tabs panes label count tab_id n want want_dir first_pane dir
  tabs="$(hl_api_json tab list --workspace "$ws")" || return 1
  panes="$(hl_api_json pane list --workspace "$ws")" || return 1

  for label in $MANAGED_TABS; do
    count=$(print -r -- "$tabs" | jq -r --arg l "$label" \
              '[.result.tabs[] | select(.label == $l)] | length') || return 1
    (( count > 1 )) && { print -r -- "malformed: $count tabs labelled '$label'"; return 0 }
  done

  local missing=0
  for label in $MANAGED_TABS; do
    tab_id=$(print -r -- "$tabs" | jq -r --arg l "$label" \
              '.result.tabs[] | select(.label == $l) | .tab_id' | head -1) || return 1
    if [[ -z "$tab_id" ]]; then missing=1; continue; fi

    n=$(print -r -- "$panes" | jq -r --arg t "$tab_id" \
          '[.result.panes[] | select(.tab_id == $t)] | length') || return 1
    want=1
    [[ "$label" == agents || "$label" == runtime ]] && want=2
    # Zero panes is malformed, not "not yet checked". An earlier draft exempted 0 to
    # keep a thin fixture green — precisely the escape hatch that makes a test unable
    # to go red.
    if [[ "$n" != "$want" ]]; then
      print -r -- "malformed: tab '$label' has $n panes, expected $want"; return 0
    fi

    # Direction, not just count: two panes side by side and two stacked both count 2.
    # PaneLayoutSnapshot exposes .splits[].direction, so this is checkable here — and
    # it has to be, because a live gate that only ever inspects a fresh build cannot
    # see a workspace whose split was changed afterwards.
    want_dir=""
    [[ "$label" == agents ]]  && want_dir=right
    [[ "$label" == runtime ]] && want_dir=down
    if [[ -n "$want_dir" ]]; then
      first_pane=$(print -r -- "$panes" | jq -r --arg t "$tab_id" \
                    '[.result.panes[] | select(.tab_id == $t)][0].pane_id') || return 1
      # .result.layout.splits — NOT .result.splits. The stub encoded the latter and
      # validated the wrong assumption; against the real binary every classification
      # of a workspace with an agents tab errored out, failing reconcile entirely.
      dir=$(hl_api_json pane layout --pane "$first_pane" \
            | jq -r '[.result.layout.splits[].direction] | unique | join(",")') || return 1
      if [[ "$dir" != "$want_dir" ]]; then
        print -r -- "malformed: tab '$label' is split '$dir', expected '$want_dir'"; return 0
      fi
    fi
  done

  local current
  current=$(hl_api_json workspace list | jq -r --arg w "$ws" \
              '.result.workspaces[] | select(.workspace_id == $w) | .label') || return 1

  # The label matters independently of the tabs. A build killed after the last
  # `tab create` but before the rename leaves correct topology under a (building)
  # label — provisional, repaired by renaming alone.
  if (( missing )) || [[ "$current" != "$final" ]]; then
    print -r -- "provisional"
  else
    print -r -- "complete"
  fi
}

hl_reconcile() {
  local ws="$1" repo="$2" verdict
  verdict="$(hl_classify "$ws" "$(hl_label "$repo")")" || return 1
  case "$verdict" in
    complete)    hl_api workspace focus "$ws" >/dev/null || return 1 ;;
    provisional) hl_repair "$ws" "$repo" || return 1 ;;
    malformed:*) die "workspace $ws is ${verdict#malformed: } — fix it by hand, or close it" ;;
  esac
}

# hl_id <json> <jq-path> <what> — pull a mandatory id out of a response.
# hl_api_json proves a payload exists and parses; it says nothing about whether the
# fields we need are present. `jq -er` fails on null or missing, so a truncated or
# reshaped response stops here instead of producing "null" and being passed to the
# next command as a pane id.
hl_id() {
  local v
  # `jq -er` alone only rejects null/false: it happily returns 7 or {} with exit 0,
  # so an API reshape could still hand nonsense to herdr — and that value reaches an
  # interpolated trap command. Require a non-empty JSON string; the id's internal
  # shape stays opaque, as it should.
  v="$(print -r -- "$1" | jq -er "($2) | select(type == \"string\" and length > 0)" 2>/dev/null)" \
    || { print -ru2 -- "layout.sh: response is missing $3"; return 1 }
  [[ -n "$v" ]] || { print -ru2 -- "layout.sh: response is missing $3"; return 1 }
  print -r -- "$v"
}

# hl_make_tab — create one managed tab and populate it. Prints its root pane id.
hl_make_tab() {
  local ws="$1" label="$2" repo="$3" out pane right
  out="$(hl_api_json tab create --workspace "$ws" --label "$label" --cwd "$repo" --no-focus)" || return 1
  pane="$(hl_id "$out" '.result.root_pane.pane_id' "a root pane for tab '$label'")" || return 1

  case "$label" in
    editor)  hl_api pane run "$pane" "nvim ." >/dev/null || return 1 ;;
    git)     hl_api pane run "$pane" "lazygit" >/dev/null || return 1 ;;
    runtime) hl_api_json pane split --pane "$pane" --direction down --cwd "$repo" --no-focus >/dev/null || return 1 ;;
    agents)
      out="$(hl_api_json pane split --pane "$pane" --direction right --cwd "$repo" --no-focus)" || return 1
      right="$(hl_id "$out" '.result.pane.pane_id' "the agents split pane")" || return 1
      # pane run, not agent start: agent start blocks until the agent is detected
      # ready (30s default), serialising every build behind two boot sequences, and it
      # changes exit semantics. A shell pane leaves a live prompt on quit, exactly as
      # dev.kdl's `claude; exec zsh` did.
      hl_api pane run "$pane" "claude" >/dev/null || return 1
      hl_api pane run "$right" "$CODEX_CMD" >/dev/null || return 1 ;;
  esac
  print -r -- "$pane"
}

hl_build() {
  local repo="$1" label out ws t1 p1 right l
  label="$(hl_label "$repo")"
  out="$(hl_api_json workspace create --cwd "$repo" --label "$label$BUILDING_SUFFIX" --no-focus)" || return 1
  # The workspace id comes first and the trap is armed IMMEDIATELY. Parsing all three
  # ids before arming leaves a window where the workspace exists but nothing will
  # clean it up: a response carrying a valid workspace_id but no tab_id exits 1 having
  # created exactly the orphan the trap exists to remove.
  #
  # A missing workspace id is deliberately handled before this — there is nothing to
  # close without one.
  ws="$(hl_id "$out" '.result.workspace.workspace_id' "a workspace id")" || return 1
  trap "command herdr workspace close ${(q)ws} >/dev/null 2>&1" EXIT INT TERM

  t1="$(hl_id "$out" '.result.tab.tab_id'        "a first tab id")" || return 1
  p1="$(hl_id "$out" '.result.root_pane.pane_id' "a root pane id")" || return 1

  hl_api tab rename "$t1" agents >/dev/null || return 1
  out="$(hl_api_json pane split --pane "$p1" --direction right --cwd "$repo" --no-focus)" || return 1
  right="$(hl_id "$out" '.result.pane.pane_id' "the agents split pane")" || return 1
  hl_api pane run "$p1" "claude" >/dev/null || return 1
  hl_api pane run "$right" "$CODEX_CMD" >/dev/null || return 1

  for l in editor runtime git; do
    hl_make_tab "$ws" "$l" "$repo" >/dev/null || return 1
  done

  hl_api workspace rename "$ws" "$label" >/dev/null || return 1
  trap - EXIT INT TERM   # complete; stop closing it on exit
  hl_api workspace focus "$ws" >/dev/null || return 1
  hl_api tab focus "$t1" >/dev/null || return 1
}

# hl_repair — create only the missing managed tabs, then rename. Preferred over
# close-and-rebuild because the workspace may hold a running agent the user cares
# about. Unmanaged tabs are not this function's business.
hl_repair() {
  local ws="$1" repo="$2" label tabs have want
  label="$(hl_label "$repo")"
  tabs="$(hl_api_json tab list --workspace "$ws")" || return 1
  for want in $MANAGED_TABS; do
    have=$(print -r -- "$tabs" | jq -r --arg l "$want" \
            '.result.tabs[] | select(.label == $l) | .tab_id' | head -1) || return 1
    [[ -n "$have" ]] && continue
    hl_make_tab "$ws" "$want" "$repo" >/dev/null || return 1
  done
  hl_api workspace rename "$ws" "$label" >/dev/null || return 1
  hl_api workspace focus "$ws" >/dev/null || return 1
}

# hl_adopt_worktree — turn the one-tab workspace returned by `herdr worktree open`
# into the managed layout without appending a redundant fifth tab. The ids are the
# ones returned by the open call; verify the live topology still matches before the
# first mutation so a stale or reshaped response cannot rename a user's tab.
hl_adopt_worktree() {
  local ws="$1" repo="$2" tab="$3" pane="$4" close_on_failure="$5"
  local tabs panes nt np actual_tab actual_pane actual_cwd out right l
  tabs="$(hl_api_json tab list --workspace "$ws")" || return 1
  panes="$(hl_api_json pane list --workspace "$ws")" || return 1
  nt=$(print -r -- "$tabs" | jq -r '.result.tabs | length') || return 1
  np=$(print -r -- "$panes" | jq -r '.result.panes | length') || return 1
  actual_tab=$(print -r -- "$tabs" | jq -r '.result.tabs[0].tab_id') || return 1
  actual_pane=$(print -r -- "$panes" | jq -r '.result.panes[0].pane_id') || return 1
  actual_cwd=$(print -r -- "$panes" | jq -r '.result.panes[0].cwd') || return 1
  if [[ "$nt" != 1 || "$np" != 1 || "$actual_tab" != "$tab" || \
        "$actual_pane" != "$pane" || "${actual_cwd:A}" != "$repo" ]]; then
    print -ru2 -- "layout.sh: native worktree workspace $ws is not blank — refusing to adopt it"
    return 1
  fi

  [[ "$close_on_failure" == true ]] \
    && trap "command herdr workspace close ${(q)ws} >/dev/null 2>&1" EXIT INT TERM
  hl_api tab rename "$tab" agents >/dev/null || return 1
  out="$(hl_api_json pane split --pane "$pane" --direction right --cwd "$repo" --no-focus)" \
    || return 1
  right="$(hl_id "$out" '.result.pane.pane_id' "the agents split pane")" || return 1
  hl_api pane run "$pane" "claude" >/dev/null || return 1
  hl_api pane run "$right" "$CODEX_CMD" >/dev/null || return 1
  for l in editor runtime git; do
    hl_make_tab "$ws" "$l" "$repo" >/dev/null || return 1
  done
  hl_api workspace rename "$ws" "$(hl_label "$repo")" >/dev/null || return 1
  trap - EXIT INT TERM
  hl_api workspace focus "$ws" >/dev/null || return 1
  hl_api tab focus "$tab" >/dev/null || return 1
}

# hl_open_worktree — use Herdr's native open operation so the checkout carries
# worktree provenance and is grouped under its primary workspace. Git creation,
# project preparation and teardown remain in the shell lifecycle around this call.
hl_open_worktree() {
  local main="$1" repo="$2" out ws tab pane reported linked already verdict managed tabs
  [[ -f "$repo/.git" ]] || die "$repo is not a linked worktree"
  local actual_main
  actual_main="$(hl_git -C "$repo" worktree list --porcelain -z 2>/dev/null \
    | tr '\0' '\n' | sed -n 's/^worktree //p' | head -1)" || return 1
  [[ -n "$actual_main" && "${actual_main:A}" == "$main" ]] \
    || die "$repo does not belong to primary checkout $main"

  hl_lock "$repo" || return 1
  out="$(hl_api_json worktree open --cwd "$main" --path "$repo" \
    --label "$(hl_label "$repo")" --no-focus)" || return 1
  ws="$(hl_id "$out" '.result.workspace.workspace_id' "a worktree workspace id")" || return 1
  tab="$(hl_id "$out" '.result.tab.tab_id' "a worktree root tab id")" || return 1
  pane="$(hl_id "$out" '.result.root_pane.pane_id' "a worktree root pane id")" || return 1
  reported="$(print -r -- "$out" | jq -er \
    '.result.workspace.worktree.checkout_path | select(type == "string" and length > 0)')" \
    || die "worktree open returned no checkout path"
  linked="$(print -r -- "$out" | jq -er \
    '.result.workspace.worktree.is_linked_worktree | if type == "boolean" then tostring else error("not boolean") end')" \
    || die "worktree open returned no linked-worktree provenance"
  already="$(print -r -- "$out" | jq -er \
    '.result.already_open | if type == "boolean" then tostring else error("not boolean") end')" \
    || die "worktree open returned no already-open state"
  [[ "${reported:A}" == "$repo" ]] \
    || die "worktree open returned a different checkout: $reported"
  [[ "$linked" == true ]] || die "worktree open says $repo is not a linked worktree"

  verdict="$(hl_classify "$ws" "$(hl_label "$repo")")" || return 1
  case "$verdict" in
    complete) hl_api workspace focus "$ws" >/dev/null || return 1 ;;
    malformed:*) die "workspace $ws is ${verdict#malformed: } — fix it by hand, or close it" ;;
    provisional)
      tabs="$(hl_api_json tab list --workspace "$ws")" || return 1
      managed=$(print -r -- "$tabs" | jq -r \
        '[.result.tabs[] | select(.label == "agents" or .label == "editor" or .label == "runtime" or .label == "git")] | length') \
        || return 1
      if (( managed == 0 )); then
        hl_adopt_worktree "$ws" "$repo" "$tab" "$pane" "$([[ "$already" == false ]] && print true || print false)" \
          || return 1
      else
        hl_repair "$ws" "$repo" || return 1
      fi ;;
  esac
}

# hl_attach — from a shell, the point of dev is to end up *inside* Herdr. Build or
# focus first, then hand the terminal over. Inside Herdr there is nothing to attach to,
# and DEV_NO_ATTACH lets tests and scripted runs stop short of a blocking TUI.
hl_attach() {
  [[ -n "${HERDR_ENV:-}" ]] && return 0
  [[ -n "${DEV_NO_ATTACH:-}" ]] && return 0
  exec command herdr
}

main() {
  local mode repo main_repo
  if [[ "${1:-}" == "--current" ]]; then
    mode=current
  elif [[ "${1:-}" == "--worktree" ]]; then
    mode=worktree
    main_repo="${2:?usage: layout.sh --worktree <primary-repo> <checkout>}"
    repo="${3:?usage: layout.sh --worktree <primary-repo> <checkout>}"
    [[ -d "$main_repo" ]] || die "no such directory: $main_repo"
    [[ -d "$repo" ]] || die "no such directory: $repo"
    main_repo="${main_repo:A}"
    repo="${repo:A}"
  else
    mode=path
    repo="${1:?usage: layout.sh <repo-path> | --current}"
    [[ -d "$repo" ]] || die "no such directory: $repo"
    repo="${repo:A}"
  fi

  if [[ -z "${HERDR_ENV:-}" ]]; then
    hl_ensure_server
  fi

  if [[ "$mode" == current ]]; then
    local ws="${HERDR_WORKSPACE_ID:-}"
    [[ -n "$ws" ]] || die "no HERDR_WORKSPACE_ID — --current only runs as a plugin action"

    # Target by context, never by a path lookup. A path lookup would find the very
    # workspace the action was invoked from, focus it, exit 0 and apply nothing — a
    # silent no-op, and the most confusing possible outcome.
    local wrepo root verdict
    wrepo="$(hl_api_json pane list --workspace "$ws" | jq -r '.result.panes[0].cwd')" \
      || hl_die_notify "could not read the workspace's panes"
    [[ -n "$wrepo" && "$wrepo" != null ]] || hl_die_notify "workspace $ws has no pane cwd to work from"
    wrepo="${wrepo:A}"

    # Resolve to the repository ROOT before anything else. A pane's cwd is wherever
    # the user last cd'd, and `.git` is a file only at the root — so checking the raw
    # cwd lets any subdirectory of a linked worktree walk straight past the guard.
    # dev never had this problem: it resolves with rev-parse before guarding.
    #
    # Fail CLOSED. Keeping the raw cwd when rev-parse fails meant a workspace sitting
    # in a non-repo directory — the plain ~ workspace being the obvious one — was
    # classified provisional and "repaired" into four tabs with two agents launched in
    # $HOME. Refusing costs nothing; the action is only meaningful in a repo.
    root="$(hl_git -C "$wrepo" rev-parse --show-toplevel 2>/dev/null)" \
      || hl_die_notify "$wrepo is not inside a git repository — refusing"
    [[ -n "$root" ]] || hl_die_notify "$wrepo is not inside a git repository — refusing"
    wrepo="${root:A}"

    # A linked checkout is allowed only when Herdr owns it as a native worktree
    # workspace. Plain workspace creation carries no provenance, so wt-rm could not
    # identify it reliably during teardown.
    if [[ -f "$wrepo/.git" ]] \
      && ! hl_is_native_worktree_workspace "$ws" "$wrepo"; then
      hl_die_notify "$wrepo is not a native Herdr worktree workspace — refusing"
    fi

    # Same lock as the path mode: two plugin invocations, or a plugin racing a dev,
    # would otherwise both see a tab missing and both create it.
    hl_lock "$wrepo" || hl_die_notify "could not take the lock for $wrepo"

    verdict="$(hl_classify "$ws" "$(hl_label "$wrepo")")" \
      || hl_die_notify "could not classify workspace $ws"
    case "$verdict" in
      complete)
        hl_notify "Project layout" "Already complete — nothing to do." ;;
      provisional)
        hl_repair "$ws" "$wrepo" || hl_die_notify "repair of $(hl_label "$wrepo") failed"
        hl_notify "Project layout" "Repaired $(hl_label "$wrepo")." ;;
      malformed:*)
        hl_die_notify "workspace $ws is ${verdict#malformed: }" ;;
    esac
    exit 0
  fi

  if [[ "$mode" == path ]]; then
    hl_lock "$repo" || exit 1
    local ws; ws="$(hl_find_workspace "$repo")" || exit 1
    # Explicit propagation, not `setopt err_return`: err_return does not fire for a
    # command whose status is already being tested, so it gives false confidence in
    # exactly the shapes used here. Without this, a failed focus or a failed create
    # fell through to hl_attach and the whole run reported success.
    if [[ -n "$ws" ]]; then
      hl_reconcile "$ws" "$repo" || exit 1
    else
      hl_build "$repo" || exit 1
    fi
  fi

  if [[ "$mode" == worktree ]]; then
    hl_open_worktree "$main_repo" "$repo" || exit 1
  fi

  hl_attach
}

# Allow the test suite to source the helpers without running anything.
if [[ "${1:-}" == "--source-only" ]]; then
  return 0 2>/dev/null || exit 0
fi
main "$@"
