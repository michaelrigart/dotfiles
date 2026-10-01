#!/usr/bin/env zsh
# layout.sh — build or focus a project's Herdr workspace, adding any missing tab.
# Managed by chezmoi (source: dot_config/herdr/executable_layout.sh).
#
#   layout.sh <repo-path>   build-or-focus, called by dev from a shell
#   layout.sh --worktree <primary> <checkout>
#                           open/adopt a native Herdr worktree workspace
#   layout.sh --make-tab <label>
#                           create one managed tab on demand and print its id, called
#                           by tab-goto.sh --create for the lazy editor tab
#
# The single definition of what a project workspace looks like.
emulate -L zsh
# no_bg_nice: zsh sets BG_NICE by default, so `cmd &` renices the job. That renice
# fails outright where setpriority is denied (a sandbox, some CI), taking the
# backgrounded server with it — and even where it succeeds, quietly deprioritising the
# Herdr server every agent runs inside is not what anyone wants.
setopt local_options no_unset pipe_fail no_bg_nice

# MANAGED_TABS — every label layout.sh knows how to create.
#
# EAGER_TABS — the subset built with the space and added back when missing. `editor` is
# deliberately outside it: nvim is expensive to start, most spaces are opened to run a
# command or read an agent's output, and a tab nobody asked for is one more thing to
# tab past. alt+e creates it on demand through --make-tab.
#
# MANAGED_TABS is also what --make-tab accepts; nothing validates an existing workspace's
# shape, so a manual split or a duplicate label is the user's business.
MANAGED_TABS=(agents editor runtime)
EAGER_TABS=(agents runtime)
# The Codex pane command lives in one file beside this script, read here and by xreview
# (which restarts the pane on a review thread with the same flags). The reasoning for its
# flags is in that file.
CODEX_CMD="$(grep -v '^[[:space:]]*#' "${0:A:h}/codex-pane-command" 2>/dev/null | grep . | head -1)"
[[ -n "$CODEX_CMD" ]] || { print -ru2 -- "layout.sh: missing ${0:A:h}/codex-pane-command"; exit 1 }

# HL_HERDR — every herdr call, with the session threaded in. herdr 0.9.3 reads
# HERDR_SESSION, but HERDR_SOCKET_PATH, which herdr exports into every pane, outranks it,
# and only `--session <name>` outranks the socket: inside a pane a bare `command herdr`
# talks to the pane's own session, whatever HERDR_SESSION says. That made the live gate's
# isolation a fiction — it set HERDR_SESSION=dev-test, layout.sh built into the live
# session anyway, and the gate then asserted against an empty dev-test and failed every
# case after the bootstrap. The leaked fixture workspaces are still visible in
# `herdr workspace list`. Nothing here may call `command herdr` directly.
typeset -ga HL_HERDR=(command herdr)
[[ -n "${HERDR_SESSION:-}" ]] && HL_HERDR+=(--session "$HERDR_SESSION")
# Pre-quoted for the `trap` strings below, which are eval'd as text rather than run.
HL_HERDR_Q="${(j: :)${(@q)HL_HERDR}}"

die() { print -ru2 -- "layout.sh: $*"; exit 1 }

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
  out="$("${HL_HERDR[@]}" "$@" 2>&1)"; rc=$?
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
  out="$("${HL_HERDR[@]}" workspace list 2>&1)" || return 1
  [[ "$out" == *server_not_running* ]] && return 1
  return 0
}

hl_ensure_server() {
  hl_server_ready && return 0
  # `herdr server` runs in the foreground: background and detach it explicitly. A
  # second dev racing this must neither fail nor start a second server, so the start
  # is fire-and-forget and readiness is what we actually wait on.
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
# Biased toward the tail. A branch carries its identity at the end — -design against
# -rollout — and Herdr truncates the far end away, so two siblings whose slugs share a
# long prefix render as one string: distinct workspaces, one visible name. Shortening
# here is the only version that stays derivable from the path; shortening against
# whatever siblings happen to exist would make a name depend on the order they were
# created in.
#
# Nothing is nudged inward, at either end. The invariant is worth more than the tidier
# break: the head and the tail are both RETAINED text, so a pair differing at either end
# must still differ in the label, and only the discarded middle may collapse. A nudge
# that trims a retained end to a word boundary silently deletes — two slugs differing at
# the character just inside that boundary come back as one string, which is the exact
# failure this function exists to prevent. So the tail may only GROW to a boundary, paid
# for out of the head, and the head is simply the first characters that remain.
#
# The cost is a head that can stop mid-word. That is the right trade: a label that is
# ugly is still a label, and a label that is wrong is a different worktree.
#
hl_shorten() {
  emulate -L zsh
  # The budget counts characters, and how many characters a string has is a question the
  # caller's locale answers: under LC_ALL=C zsh measures and slices bytes, so the same
  # slug comes back a different length and cut mid-codepoint. Pin it, so the label is a
  # function of its argument and nothing else. If the locale is missing zsh falls back to
  # C and this degrades to the byte behaviour rather than failing — cosmetic, as ever.
  #
  # Characters, not display columns: a slug of double-width glyphs still overruns a rail
  # measured in columns. Branch names are ASCII in practice, and a wcwidth table in zsh
  # is a large amount of machinery for a label.
  local LC_ALL=en_US.UTF-8
  local text="$1" budget="$2" slack=8 keep tail_want start lo cand seg t i
  (( ${#text} <= budget )) && { print -r -- "$text"; return 0 }
  # No columns, no label. Guarded ahead of the tail slice below, where zsh reads an index
  # of -0 as 0 and hands back the whole string — the opposite of a budget.
  (( budget < 1 )) && { print -r -- ""; return 0 }
  # Below three there is no room for a head, an ellipsis and a tail. Keep the tail: the
  # contract is that the identifying end survives, and the degenerate case is no place to
  # start contradicting it. Unreachable from hl_label, which always passes 34.
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
  # BOTH sides resolved. dev hands over "${repo:A}", so on macOS a repo under /tmp
  # arrives as /private/tmp/... while $HOME is still /tmp/... — the prefix never
  # matches and the label silently degrades to the full absolute path. The same
  # applies to any ~/Code behind a symlink, which _wt_assert_worktree already warns
  # about: "git reports real paths, and ~/Code may sit behind a symlink."
  local repo="${1:A}" home="${HOME:A}" common main slug
  # A linked checkout is a sibling named "<primary>-<slug>", so its own path leads with
  # everything it shares with the primary and only reaches the part that differs at the
  # end — which is where a 40-column rail has already truncated it. Both halves of the
  # name are wrong to show on their own: the whole path makes every worktree of one
  # project read identically, and so does the project alone. The slug is the half that
  # answers "which checkout is this". Nothing here answers "of what", because Herdr
  # already marks a grouped checkout as subordinate to its primary — a marker in the
  # label too would say it a second time, in a rail with no columns to spare.
  #
  # Derived from the path, not from HEAD: a label is written once, at open or repair,
  # so reading the branch would leave it stale the moment a checkout switched branches.
  # The slug is what `wt` built the directory from and what `wt-rm` matches on.
  #
  # Over-long slugs go through hl_shorten, which keeps the tail, so two siblings sharing
  # a long prefix stay distinct rather than both being truncated to it by Herdr. What
  # that does not cover is a pair differing only in the discarded middle: known, accepted,
  # and not worth a hash suffix on every label to defend. The alternative — shortening a
  # checkout relative to whatever other checkouts happen to exist — would make the name
  # depend on the order they were created in and stop it being derivable from the path.
  #
  # `.git` as a FILE is what distinguishes a linked checkout, the test `dev`
  # makes too. If git cannot name the common directory, or the directory does not
  # carry the primary's name as a prefix, the label degrades to the path-derived form
  # below rather than guessing: a cosmetic label is never worth an abort, and identity
  # is the canonical path regardless.
  if [[ -f "$repo/.git" ]]; then
    common="$(hl_git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [[ -n "$common" ]]; then
      main="${${common:A}:h}"
      slug="${${repo:t}#${main:t}-}"
      # Sibling AND prefixed. The basenames alone are not enough: a checkout of the same
      # primary parked under another directory still reads as conventional — repo-feature
      # against repo — so a name-only test would slug it, and collide with the real
      # sibling of that name if one existed. Two different checkouts must never reduce to
      # one label.
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

  # Returns non-zero rather than calling die, so each caller decides how to fail.
  local t="${HL_LOCK_TIMEOUT:-10}"
  # Emitted BEFORE the blocking call, unlike LOCK-ACQUIRED after it. A test that wants
  # to act while another process is stuck here has to observe that it is stuck; timing
  # it with a sleep is an assumption, and an assumption that holds on the machine it
  # was written on is how an ordering test quietly stops testing ordering.
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

# hl_make_tab — create one managed tab and populate it. Prints its TAB id, which is
# what --make-tab hands back to tab-goto.sh to focus. Returning the id from the create
# response rather than having the caller re-list is the point: a second list between
# the create and the focus is a window another attached client can change the tab set
# in, and the id is already in hand.
hl_make_tab() {
  local ws="$1" label="$2" repo="$3" out pane tab
  out="$(hl_api_json tab create --workspace "$ws" --label "$label" --cwd "$repo" --no-focus)" || return 1
  # The TAB id first, and on its own line: once `tab create` has answered, the tab
  # exists on the server, and from here every failure has to be able to remove it.
  # Parsing the pane id first left the response-shape failures — a create that answered
  # without a usable root pane — returning with no id to clean up with.
  tab="$(hl_id "$out" '.result.tab.tab_id' "a tab id for tab '$label'")" || return 1

  # Everything after the tab exists runs through one exit point. Without it, a `tab
  # create` that succeeds and a `pane run` that fails leaves a tab with the right label
  # and the right pane count — which classifies COMPLETE, so repair never touches it
  # and every later alt+e focuses an empty shell labelled "editor". hl_build has a
  # workspace-level trap that hides this; --make-tab has no trap and must not need one.
  if ! {
    pane="$(hl_id "$out" '.result.root_pane.pane_id' "a root pane for tab '$label'")" \
      && hl_populate_tab "$label" "$pane" "$repo"
  }; then
    hl_api tab close "$tab" >/dev/null 2>&1 || true
    return 1
  fi
  print -r -- "$tab"
}

# hl_populate_tab <label> <root-pane> <repo> — run what belongs in a freshly created
# tab. Split out of hl_make_tab purely so failure has one exit point to clean up after.
hl_populate_tab() {
  local label="$1" pane="$2" repo="$3"
  case "$label" in
    editor)  hl_api pane run "$pane" "nvim ." >/dev/null || return 1 ;;
    runtime) hl_api_json pane split --pane "$pane" --direction down --cwd "$repo" --no-focus >/dev/null || return 1 ;;
    agents)  hl_agents_split "$pane" "$repo" || return 1 ;;
  esac
}

# hl_ensure_tab <ws> <repo> <label> — print the tab id for <label>, creating the tab
# first if it is absent. The caller holds the lock, so the list here is the
# authoritative re-check: tab-goto.sh looks before it calls, and without a second look
# under the lock two fast alt+e presses both see nothing and build two editor tabs.
hl_ensure_tab() {
  local ws="$1" repo="$2" label="$3" tabs count id
  tabs="$(hl_api_json tab list --workspace "$ws")" || return 1
  count=$(print -r -- "$tabs" | jq -r --arg l "$label" \
            '[.result.tabs[] | select(.label == $l)] | length') || return 1
  # Same refusal as tab-goto.sh: choosing which duplicate to adopt means choosing
  # which one the user loses, and nothing here knows enough to choose.
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

# hl_open_worktree — use Herdr's native open operation so the checkout carries
# worktree provenance and is grouped under its primary workspace. Git creation,
# project preparation and teardown remain in the shell lifecycle around this call.
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

  # HERDR_ENV means "already inside a Herdr pane", so normally there is a server and
  # nothing to start. That inference breaks the moment an explicit HERDR_SESSION names
  # a DIFFERENT session: the pane we are in belongs to another one, and its server says
  # nothing about the target's. The live gate runs exactly that way, and before this
  # check it inherited HERDR_ENV from the surrounding pane, skipped the start, and —
  # with the old unsessioned calls — built its fixtures into the live default session.
  #
  # make-tab is exempt: it exists only to serve a keybinding, so there is by
  # construction a server and a workspace already. Probing — and, on a slow answer,
  # starting a second server — on every alt+e is latency spent to learn something we
  # were told by being invoked at all.
  if [[ "$mode" != make-tab ]] \
    && { [[ -z "${HERDR_ENV:-}" ]] || [[ -n "${HERDR_SESSION:-}" ]] }; then
    hl_ensure_server
  fi

  if [[ "$mode" == make-tab ]]; then
    # Same resolution order as tab-goto.sh, because this runs from the same detached
    # keybinding: Herdr injects the active context.
    # tab-goto.sh captures this script's stderr and raises the toast, so every failure
    # below reports through plain `die`.
    local ws="${HERDR_ACTIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-}}"
    [[ -n "$ws" ]] \
      || die "no active workspace in the environment (expected HERDR_ACTIVE_WORKSPACE_ID)"
    # Checked before anything is resolved, so a typo in config.toml cannot start
    # populating tabs this script has no shape for. Cheapest guard first, too.
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
