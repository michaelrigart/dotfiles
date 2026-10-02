#!/usr/bin/env zsh
# tab-goto.sh [--create] <label> — focus a managed tab in the active workspace.
# Managed by chezmoi (source: dot_config/herdr/executable_tab-goto.sh).
#
# By LABEL, never by index: herdr has no `tab move` and `tab create` takes no position,
# so managed tabs can sit in any order, and the user's own tabs shift every position.
#
# --create makes the tab if the label is absent, by asking layout.sh, which owns what a
# tab contains. It is for LAZY tabs only (today: editor); a missing eager tab is
# re-added by layout.sh, and a jump that quietly built one would hide the real fault.
emulate -L zsh
setopt local_options no_unset pipe_fail

# Same session threading as layout.sh: a bare `command herdr` here would focus a tab in
# the pane's own session while the caller meant a named one.
typeset -ga HL_HERDR=(command herdr)
[[ -n "${HERDR_SESSION:-}" ]] && HL_HERDR+=(--session "$HERDR_SESSION")

# tg_fail — report and stop. Bound to a key via [[keys.command]] type = "shell", which
# herdr runs DETACHED: stderr never reaches the TUI, so the notification is the only
# feedback; stderr is kept for the test suite and manual invocation.
tg_fail() {
  print -ru2 -- "tab-goto: $1"
  "${HL_HERDR[@]}" notification show "Tab jump" --body "$1" >/dev/null 2>&1 || true
  exit 1
}

# tg_focus <tab-id> <what> — focus, and believe it only if the response agrees: the CLI
# answers some failures with an error envelope at exit status 0. Same boundary
# discipline as layout.sh's hl_api.
tg_focus() {
  local out
  out="$("${HL_HERDR[@]}" tab focus "$1" 2>&1)" || tg_fail "could not focus $2: $out"
  [[ -z "$out" ]] && return 0
  print -r -- "$out" | jq -e . >/dev/null 2>&1 \
    || tg_fail "focusing $2 returned invalid JSON"
  print -r -- "$out" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1 \
    && tg_fail "could not focus $2: $out"
  return 0
}

create=0
if [[ "${1:-}" == "--create" ]]; then create=1; shift; fi
label="${1:-}"
[[ -n "$label" ]] || tg_fail "usage: tab-goto.sh [--create] <label>"

# Resolving through the globally-focused workspace is racy: another attached client can
# change focus between the keypress and the query. Herdr injects active-context
# variables into custom commands; if none is present, say so rather than guess.
ws="${HERDR_ACTIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-}}"
[[ -n "$ws" ]] || tg_fail "no active workspace in the environment (expected HERDR_ACTIVE_WORKSPACE_ID)"

tabs="$("${HL_HERDR[@]}" tab list --workspace "$ws" 2>&1)" || tg_fail "tab list failed: $tabs"

# Same boundary discipline as layout.sh: jq exits 0 on empty input, so an empty response
# would read as "no tab labelled X" and blame the label for an API failure.
[[ -n "$tabs" ]] || tg_fail "herdr returned an empty response"
print -r -- "$tabs" | jq -e . >/dev/null 2>&1 \
  || tg_fail "herdr returned invalid JSON"
print -r -- "$tabs" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1 \
  && tg_fail "herdr returned an error envelope"

# Count the tabs carrying this label, then collect only ids that are non-empty JSON
# strings; comparing the two catches a matching tab with a missing or non-string id.
count="$(print -r -- "$tabs" | jq -r --arg l "$label" \
          '[.result.tabs[] | select(.label == $l)] | length')" \
  || tg_fail "could not read the tab list"
matched="$(print -r -- "$tabs" | jq -r --arg l "$label" \
            '.result.tabs[] | select(.label == $l) | .tab_id
             | select(type == "string" and length > 0)')" \
  || tg_fail "could not read tab ids"

ids=( ${(f)matched} )
ids=( ${ids:#} )

# The lazy path. layout.sh hands back the id of the tab it created, focused directly:
# re-listing would reopen the window between create and focus. The create is idempotent
# under layout.sh's lock, so two fast presses cannot produce two tabs.
if (( count == 0 && create )); then
  new="$("${DEV_LAYOUT:-$HOME/.config/herdr/layout.sh}" --make-tab "$label" 2>&1)" \
    || tg_fail "could not create '$label': $new"
  # layout.sh prints one id and nothing else on success; whitespace means a diagnostic.
  [[ -n "$new" && "$new" != *[[:space:]]* ]] \
    || tg_fail "creating '$label' returned no usable tab id: $new"
  tg_focus "$new" "the new '$label'"
  exit 0
fi

(( count == 0 ))          && tg_fail "no tab labelled '$label'"
(( ${#ids} != count ))    && tg_fail "tab '$label' has a malformed id"
(( ${#ids} > 1 ))         && tg_fail "${#ids} tabs labelled '$label' — refusing to guess"

tg_focus "${ids[1]}" "'$label'"
