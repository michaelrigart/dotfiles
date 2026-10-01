#!/usr/bin/env zsh
# layout.sh — build or focus a project's Herdr workspace, adding any missing tab.
# Managed by chezmoi (source: dot_config/herdr/executable_layout.sh).
#
#   layout.sh <repo-path>   build-or-focus, called by dev from a shell
#   layout.sh --worktree <primary> <checkout>
#                           open a native Herdr worktree workspace
#   layout.sh --make-tab <label>
#                           create one managed tab on demand and print its id, called
#                           by tab-goto.sh --create for the lazy editor tab
#
# The single definition of what a project workspace looks like.
emulate -L zsh
# no_bg_nice: zsh renices `cmd &` by default; that fails where setpriority is denied
# (a sandbox, some CI), taking the backgrounded server with it.
setopt local_options no_unset pipe_fail no_bg_nice

# MANAGED_TABS — every label layout.sh knows how to create; also what --make-tab accepts.
# EAGER_TABS — the subset built with the space and added back when missing. `editor` is
# outside it because nvim is expensive to start: alt+e creates it through --make-tab.
# Nothing validates an existing workspace's shape.
MANAGED_TABS=(agents editor runtime)
EAGER_TABS=(agents runtime)
# The Codex pane command lives in one file beside this script, read here and by xreview.
# The reasoning for its flags is in that file.
CODEX_CMD="$(grep -v '^[[:space:]]*#' "${0:A:h}/codex-pane-command" 2>/dev/null | grep . | head -1)"
[[ -n "$CODEX_CMD" ]] || { print -ru2 -- "layout.sh: missing ${0:A:h}/codex-pane-command"; exit 1 }

# HL_HERDR — every herdr call, with the session threaded in. Inside a pane,
# HERDR_SOCKET_PATH outranks HERDR_SESSION and only `--session` outranks the socket, so a
# bare `command herdr` talks to the pane's own session. Nothing here may call
# `command herdr` directly. See AGENTS.md, "Inside a Herdr pane".
typeset -ga HL_HERDR=(command herdr)
[[ -n "${HERDR_SESSION:-}" ]] && HL_HERDR+=(--session "$HERDR_SESSION")
# Pre-quoted for the `trap` strings below, which are eval'd as text rather than run.
HL_HERDR_Q="${(j: :)${(@q)HL_HERDR}}"

die() { print -ru2 -- "layout.sh: $*"; exit 1 }

# hl_git — git with its routing environment cleared, mirroring _wt_git in zsh/functions.
hl_git() {
  command env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE \
    git "$@"
}

# hl_api — run a herdr CLI call, return its JSON on stdout. Non-zero on failure, with
# the server's message. Every call goes through here so failures are uniform.
hl_api() {
  local out rc
  out="$("${HL_HERDR[@]}" "$@" 2>&1)"; rc=$?
  if (( rc != 0 )); then
    print -ru2 -- "layout.sh: herdr $* failed: $out"
    return 1
  fi
  if [[ -n "$out" ]]; then
    # Validate at the boundary, once: downstream jq consumers discard their status
    # inside command substitutions, so malformed JSON would become plausible state.
    if ! print -r -- "$out" | jq -e . >/dev/null 2>&1; then
      print -ru2 -- "layout.sh: herdr $* returned invalid JSON"
      return 1
    fi
    # Envelope check on the PARSED top level, not a substring match on '"error"',
    # which would reject valid data that merely contains the word (a tab label).
    if print -r -- "$out" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1; then
      print -ru2 -- "layout.sh: herdr $* failed: $out"
      return 1
    fi
  fi
  print -r -- "$out"
}

# hl_api_json — for calls that MUST return a payload: list, create, split. Empty output
# is legitimate for focus/run/rename/close, but `jq` exits 0 on empty input, so an empty
# response here would read as "no workspace found" and build a duplicate.
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
# while reporting "not running" and there is no `ping`, so the probe is a real call.
hl_server_ready() {
  local out
  out="$("${HL_HERDR[@]}" workspace list 2>&1)" || return 1
  [[ "$out" == *server_not_running* ]] && return 1
  return 0
}

hl_ensure_server() {
  hl_server_ready && return 0
  # `herdr server` runs in the foreground, so detach it. The start is fire-and-forget
  # because a racing second dev must neither fail nor start a second server.
  ("${HL_HERDR[@]}" server >/dev/null 2>&1 &) || true
  local tries="${HL_READY_TRIES:-40}" i=1
  while (( i <= tries )); do
    hl_server_ready && return 0
    sleep 0.25
    (( i++ ))
  done
  die "the herdr server did not become ready after $(( tries / 4 ))s"
}

# hl_shorten <text> <budget> — <text> if it fits, otherwise head…tail inside <budget>.
#
# Biased toward the tail: a branch carries its identity at the end (-design against
# -rollout), and Herdr truncates the far end. Derived from the text alone, never from
# whichever siblings exist.
#
# Nothing is nudged inward at either end: head and tail are both RETAINED text, so a pair
# differing at either end must still differ in the label and only the discarded middle
# may collapse. The tail may only GROW to a word boundary, paid for out of the head,
# which can therefore stop mid-word.
hl_shorten() {
  emulate -L zsh
  # Pin the locale: under LC_ALL=C zsh counts and slices bytes, cutting mid-codepoint. A
  # missing locale degrades to byte behaviour, which is cosmetic. The budget counts
  # characters, not display columns; branch names are ASCII in practice.
  local LC_ALL=en_US.UTF-8
  local text="$1" budget="$2" slack=8 keep tail_want start lo cand seg t i
  (( ${#text} <= budget )) && { print -r -- "$text"; return 0 }
  # Guarded ahead of the tail slice below, where zsh reads an index of -0 as 0 and
  # returns the whole string.
  (( budget < 1 )) && { print -r -- ""; return 0 }
  # Below three there is no room for a head, an ellipsis and a tail: keep the tail.
  # Unreachable from hl_label, which always passes 34.
  (( budget < 3 )) && { print -r -- "${text[-budget,-1]}"; return 0 }
  keep=$(( budget - 1 ))                              # one column for the ellipsis
  tail_want=$(( keep / 2 + keep % 2 ))                # the tail carries the identity
  (( tail_want > keep - 1 )) && tail_want=$(( keep - 1 ))   # always leave a head
  start=$(( ${#text} - tail_want + 1 ))
  lo=$(( start - slack > 1 ? start - slack : 1 ))
  seg="${text[lo,start-1]}"
  i=${seg[(I)-]}                                      # last '-' before the tail
  if (( i > 0 )); then
    cand=$(( lo + i ))
    # Grow to it only if the longer tail still leaves a head inside the budget.
    (( ${#text} - cand + 1 <= keep - 1 )) && start=$cand
  fi
  t="${text[start,-1]}"
  print -r -- "${text[1,keep-${#t}]}…$t"
}

# hl_label — the display label. Deterministic from the path so it is stable, but
# purely cosmetic: identity is the canonical path, checked via pane cwd.
hl_label() {
  # BOTH sides resolved: on macOS a repo under /tmp arrives as /private/tmp/... while
  # $HOME is still /tmp/..., so the prefix would never match.
  local repo="${1:A}" home="${HOME:A}" common main slug
  # A linked checkout is labelled by its slug alone, the part that answers "which
  # checkout is this" (Herdr already marks it as subordinate to its primary). Derived
  # from the path, not HEAD, so it cannot go stale when a checkout switches branches;
  # long slugs go through hl_shorten. A pair differing only in the discarded middle is
  # known and accepted.
  #
  # `.git` as a FILE is what distinguishes a linked checkout, as in `dev`. If git cannot
  # name the common directory, or the name is not primary-prefixed, the label degrades
  # to the path-derived form below: a cosmetic label is never worth an abort.
  if [[ -f "$repo/.git" ]]; then
    common="$(hl_git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [[ -n "$common" ]]; then
      main="${${common:A}:h}"
      slug="${${repo:t}#${main:t}-}"
      # Sibling AND prefixed: a checkout of the same primary parked under another
      # directory would otherwise slug to the same label as the real sibling.
      [[ "${repo:h}" == "${main:h}" && -n "$slug" && "$slug" != "${repo:t}" ]] \
        && { print -r -- "$(hl_shorten "$slug" 34)"; return 0 }
    fi
  fi
  case "$repo" in
    "$home/Code/"*) print -r -- "${repo#$home/Code/}" ;;
    "$home/"*)      print -r -- "${repo#$home/}" ;;
    *)              print -r -- "$repo" ;;
  esac
}

# hl_lock — serialise per canonical repo path. Taken BEFORE any scan, which is repeated
# underneath it: scanning first lets a waiter act on a stale empty observation and
# create a duplicate workspace.
#
# `zsystem flock`, as in _wt_lock, not a mkdir sentinel: the kernel releases an fcntl lock
# when the process dies, so one SIGKILL cannot wedge the repository. zsystem opens but
# does not create the lock file, so it must exist first.
hl_lock() {
  local key="${1//\//-}" dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-layout"
  mkdir -p "$dir"
  HL_LOCKFILE="$dir/${key#-}.lock"
  : >>"$HL_LOCKFILE"
  zmodload -F zsh/system b:zsystem 2>/dev/null

  [[ -n "${HL_LOCK_DELAY:-}" ]] && sleep "$HL_LOCK_DELAY"

  # Returns non-zero rather than calling die, so each caller decides how to fail.
  local t="${HL_LOCK_TIMEOUT:-10}"
  # Emitted BEFORE the blocking call so a test can observe that a process is stuck here
  # rather than time it with a sleep.
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "LOCK-WAIT"
  if ! zsystem flock -t "$t" "$HL_LOCKFILE" 2>/dev/null; then
    print -ru2 -- "layout.sh: another layout.sh has held the lock for $1 for over ${t}s"
    return 1
  fi
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "LOCK-ACQUIRED"
  return 0
}

# hl_find_workspace <repo> — the workspace for this checkout, or nothing. Identity is
# Herdr's provenance (worktree.checkout_path), which does not follow `cd`. A workspace
# that predates provenance is matched by a pane at the repo root, and only one carrying
# no provenance at all can be matched that way. Several candidates: the first, with a warning.
hl_find_workspace() {
  local repo="$1" list panes matched i
  local -a recs ids
  # stderr: this function's stdout is its return value.
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "SCAN"
  [[ -n "${HL_SCAN_DELAY:-}" ]] && sleep "$HL_SCAN_DELAY"
  list="$(hl_api_json workspace list)" || return 1
  recs=( ${(0)"$(print -r -- "$list" | jq -j '
    .result.workspaces[]
    | select((.worktree.checkout_path? | type) == "string" and (.worktree.checkout_path | length) > 0)
    | .workspace_id, "\u0000", .worktree.checkout_path, "\u0000"')"} ) \
    || { print -ru2 -- "layout.sh: could not read workspace provenance"; return 1 }
  for (( i = 1; i < ${#recs}; i += 2 )); do
    [[ "${recs[i+1]:A}" == "$repo" ]] && ids+=( "${recs[i]}" )
  done
  if (( ${#ids} == 0 )); then
    panes="$(hl_api_json pane list)" || return 1
    matched="$(print -r -- "$panes" | jq -r --arg d "$repo" --argjson ws "$list" '
      ([$ws.result.workspaces[] | select(.worktree == null) | .workspace_id]) as $bare
      | .result.panes[] | select(.cwd == $d) | .workspace_id
      | select(. as $w | $bare | index($w))' | awk '!seen[$0]++')" \
      || { print -ru2 -- "layout.sh: could not read workspace ids from pane list"; return 1 }
    ids=( ${(f)matched} )
    ids=( ${ids:#} )
  fi
  (( ${#ids} == 0 )) && return 0
  (( ${#ids} > 1 )) && print -ru2 -- "layout.sh: ${#ids} workspaces for $repo (${ids[*]}) — using ${ids[1]}"
  print -r -- "${ids[1]}"
}

# hl_id <json> <jq-path> <what> — pull a mandatory id out of a response, so a truncated
# or reshaped response stops here instead of passing "null" on as a pane id.
hl_id() {
  local v
  # `jq -er` alone rejects only null/false and returns 7 or {} with exit 0, and the value
  # reaches an interpolated trap command. Require a non-empty JSON string.
  v="$(print -r -- "$1" | jq -er "($2) | select(type == \"string\" and length > 0)" 2>/dev/null)" \
    || { print -ru2 -- "layout.sh: response is missing $3"; return 1 }
  [[ -n "$v" ]] || { print -ru2 -- "layout.sh: response is missing $3"; return 1 }
  print -r -- "$v"
}

# hl_make_tab — create one managed tab and populate it. Prints its TAB id for tab-goto.sh
# to focus; taken from the create response, so no second list opens a window for another
# client to change the tab set.
hl_make_tab() {
  local ws="$1" label="$2" repo="$3" out pane tab
  out="$(hl_api_json tab create --workspace "$ws" --label "$label" --cwd "$repo" --no-focus)" || return 1
  # The TAB id first: once `tab create` has answered the tab exists, and every later
  # failure must be able to remove it.
  tab="$(hl_id "$out" '.result.tab.tab_id' "a tab id for tab '$label'")" || return 1

  # Everything after the tab exists runs through one exit point: a failed `pane run`
  # would otherwise leave an empty tab with the right label, and every later alt+e would
  # focus it. --make-tab has no trap and must not need one.
  if ! {
    pane="$(hl_id "$out" '.result.root_pane.pane_id' "a root pane for tab '$label'")" \
      && hl_populate_tab "$label" "$pane" "$repo"
  }; then
    hl_api tab close "$tab" >/dev/null 2>&1 || true
    return 1
  fi
  print -r -- "$tab"
}

# hl_populate_tab <label> <root-pane> <repo> — run what belongs in a freshly created tab.
hl_populate_tab() {
  local label="$1" pane="$2" repo="$3"
  case "$label" in
    editor)  hl_api pane run "$pane" "nvim ." >/dev/null || return 1 ;;
    runtime) hl_api_json pane split --pane "$pane" --direction down --cwd "$repo" --no-focus >/dev/null || return 1 ;;
    agents)  hl_agents_split "$pane" "$repo" || return 1 ;;
  esac
}

# hl_ensure_tab <ws> <repo> <label> — print the tab id for <label>, creating it if absent.
# The list under the lock is the authoritative re-check: tab-goto.sh's own look would
# let two fast alt+e presses build two editor tabs.
hl_ensure_tab() {
  local ws="$1" repo="$2" label="$3" tabs count id
  tabs="$(hl_api_json tab list --workspace "$ws")" || return 1
  count=$(print -r -- "$tabs" | jq -r --arg l "$label" \
            '[.result.tabs[] | select(.label == $l)] | length') || return 1
  # Same refusal as tab-goto.sh: nothing here knows which duplicate the user wants.
  (( count > 1 )) && { print -ru2 -- "layout.sh: $count tabs labelled '$label' — refusing to guess"; return 1 }
  if (( count == 1 )); then
    id="$(print -r -- "$tabs" | jq -r --arg l "$label" \
           '.result.tabs[] | select(.label == $l) | .tab_id
            | select(type == "string" and length > 0)')" || return 1
    [[ -n "$id" ]] || { print -ru2 -- "layout.sh: tab '$label' has a malformed id"; return 1 }
    print -r -- "$id"
    return 0
  fi
  hl_make_tab "$ws" "$label" "$repo"
}

# hl_ensure_eager_tabs <ws> <repo> — create each EAGER tab no tab carries the label of.
# Shapes, pane counts, duplicates and the workspace label are the user's business.
hl_ensure_eager_tabs() {
  local ws="$1" repo="$2" tabs label n
  tabs="$(hl_api_json tab list --workspace "$ws")" || return 1
  for label in $EAGER_TABS; do
    n=$(print -r -- "$tabs" | jq -r --arg l "$label" '[.result.tabs[] | select(.label == $l)] | length') \
      || return 1
    (( n > 0 )) && continue
    hl_make_tab "$ws" "$label" "$repo" >/dev/null || return 1
  done
}

# hl_agents_split <pane> <repo> — claude in <pane>, the Codex pane command in a split to
# its right. `pane run`, not `agent start`, which blocks until the agent reports ready.
hl_agents_split() {
  local pane="$1" repo="$2" out right
  out="$(hl_api_json pane split --pane "$pane" --direction right --cwd "$repo" --no-focus)" || return 1
  right="$(hl_id "$out" '.result.pane.pane_id' "the agents split pane")" || return 1
  hl_api pane run "$pane" "claude" >/dev/null || return 1
  hl_api pane run "$right" "$CODEX_CMD" >/dev/null || return 1
}

# hl_fill_new <ws> <root-tab> <root-pane> <repo> — the eager baseline in a workspace
# created a moment ago: its root tab becomes agents, the other eager tabs are appended.
hl_fill_new() {
  local ws="$1" tab="$2" pane="$3" repo="$4" l
  hl_api tab rename "$tab" agents >/dev/null || return 1
  hl_agents_split "$pane" "$repo" || return 1
  for l in $EAGER_TABS; do
    [[ "$l" == agents ]] && continue
    hl_make_tab "$ws" "$l" "$repo" >/dev/null || return 1
  done
}

hl_build() {
  local repo="$1" out ws tab pane
  out="$(hl_api_json workspace create --cwd "$repo" --label "$(hl_label "$repo")" --no-focus)" || return 1
  # Arm the close trap the moment a workspace id exists, before parsing anything else.
  ws="$(hl_id "$out" '.result.workspace.workspace_id' "a workspace id")" || return 1
  trap "$HL_HERDR_Q workspace close ${(q)ws} >/dev/null 2>&1" EXIT INT TERM
  tab="$(hl_id "$out" '.result.tab.tab_id' "a first tab id")" || return 1
  pane="$(hl_id "$out" '.result.root_pane.pane_id' "a root pane id")" || return 1
  hl_fill_new "$ws" "$tab" "$pane" "$repo" || return 1
  trap - EXIT INT TERM
  hl_api workspace focus "$ws" >/dev/null || return 1
  hl_api tab focus "$tab" >/dev/null || return 1
}

# hl_open_worktree — Herdr's native open, so the checkout carries worktree provenance and
# is grouped under its primary workspace.
hl_open_worktree() {
  local main="$1" repo="$2" out ws tab pane reported linked already
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

  if [[ "$already" == false ]]; then
    trap "$HL_HERDR_Q workspace close ${(q)ws} >/dev/null 2>&1" EXIT INT TERM
    hl_fill_new "$ws" "$tab" "$pane" "$repo" || return 1
    trap - EXIT INT TERM
    hl_api workspace focus "$ws" >/dev/null || return 1
    hl_api tab focus "$tab" >/dev/null || return 1
  else
    hl_ensure_eager_tabs "$ws" "$repo" || return 1
    hl_api workspace focus "$ws" >/dev/null || return 1
  fi
}

# hl_context_repo <ws> — the checkout a workspace belongs to, into HL_CONTEXT_REPO: its
# Herdr provenance, else its first pane's git toplevel. A global, not stdout, because
# `die` inside a command substitution would kill only the subshell.
hl_context_repo() {
  local ws="$1" list cpath cwd root
  list="$(hl_api_json workspace list)" || die "could not read the workspace list"
  cpath="$(print -r -- "$list" | jq -r --arg w "$ws" '
    [.result.workspaces[] | select(.workspace_id == $w) | .worktree.checkout_path
     | select(type == "string" and length > 0)][0] // ""')" || die "could not read workspace $ws"
  if [[ -n "$cpath" ]]; then
    typeset -g HL_CONTEXT_REPO="${cpath:A}"
    return 0
  fi
  cwd="$(hl_api_json pane list --workspace "$ws" | jq -r '.result.panes[0].cwd')" \
    || die "could not read the workspace's panes"
  [[ -n "$cwd" && "$cwd" != null ]] || die "workspace $ws has no pane cwd to work from"
  root="$(hl_git -C "${cwd:A}" rev-parse --show-toplevel 2>/dev/null)" \
    || die "${cwd:A} is not inside a git repository — refusing"
  [[ -n "$root" ]] || die "${cwd:A} is not inside a git repository — refusing"
  typeset -g HL_CONTEXT_REPO="${root:A}"
}

# hl_attach — from a shell, the point of dev is to end up *inside* Herdr. Build or
# focus first, then hand the terminal over. Inside Herdr there is nothing to attach to,
# and DEV_NO_ATTACH lets tests and scripted runs stop short of a blocking TUI.
hl_attach() {
  [[ -n "${HERDR_ENV:-}" ]] && return 0
  [[ -n "${DEV_NO_ATTACH:-}" ]] && return 0
  exec "${HL_HERDR[@]}"
}

main() {
  local mode repo main_repo make_label
  if [[ "${1:-}" == "--make-tab" ]]; then
    mode=make-tab
    make_label="${2:-}"
    [[ -n "$make_label" ]] || die "usage: layout.sh --make-tab <label>"
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
    repo="${1:?usage: layout.sh <repo-path>}"
    [[ -d "$repo" ]] || die "no such directory: $repo"
    repo="${repo:A}"
  fi

  # HERDR_ENV means "already inside a Herdr pane", so there is normally a server. An
  # explicit HERDR_SESSION breaks that inference: the pane we are in then belongs to a
  # different session than the one named. make-tab is exempt: it serves a keybinding, so
  # a server and workspace exist by construction.
  if [[ "$mode" != make-tab ]] \
    && { [[ -z "${HERDR_ENV:-}" ]] || [[ -n "${HERDR_SESSION:-}" ]] }; then
    hl_ensure_server
  fi

  if [[ "$mode" == make-tab ]]; then
    # Same resolution order as tab-goto.sh, which runs from the same detached keybinding.
    # tab-goto.sh captures this script's stderr and raises the toast, so every failure
    # below reports through plain `die`.
    local ws="${HERDR_ACTIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-}}"
    [[ -n "$ws" ]] \
      || die "no active workspace in the environment (expected HERDR_ACTIVE_WORKSPACE_ID)"
    # Checked first, so a typo in config.toml cannot populate a tab this script has no
    # shape for.
    (( ${MANAGED_TABS[(Ie)$make_label]} )) \
      || die "'$make_label' is not a managed tab"

    hl_context_repo "$ws"
    hl_lock "$HL_CONTEXT_REPO" || die "could not take the lock for $HL_CONTEXT_REPO"
    hl_ensure_tab "$ws" "$HL_CONTEXT_REPO" "$make_label" \
      || die "could not create the '$make_label' tab"
    exit 0
  fi

  if [[ "$mode" == path ]]; then
    hl_lock "$repo" || exit 1
    local ws; ws="$(hl_find_workspace "$repo")" || exit 1
    if [[ -n "$ws" ]]; then
      hl_ensure_eager_tabs "$ws" "$repo" || exit 1
      hl_api workspace focus "$ws" >/dev/null || exit 1
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
