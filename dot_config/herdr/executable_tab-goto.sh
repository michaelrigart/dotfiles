#!/usr/bin/env zsh
# tab-goto.sh <label> — focus a managed tab in the active workspace.
# Managed by chezmoi (source: dot_config/herdr/executable_tab-goto.sh).
#
# By LABEL, never by index. herdr 0.8.2 has no `tab move`, so repair can only append
# and a repaired workspace's managed tabs can end up in any order; the user's own
# alt+t tab also shifts every position after it. An index would silently land on the
# wrong tab, which is worse than not moving at all.
emulate -L zsh
setopt local_options no_unset pipe_fail

# tg_fail — report and stop. Bound to a key via [[keys.command]] type = "shell", which
# herdr runs DETACHED: nothing written to stderr reaches the TUI, so a failure would
# look exactly like a dead keybinding. The notification is the only feedback the user
# actually sees; stderr is kept for the test suite and for manual invocation.
tg_fail() {
  print -ru2 -- "tab-goto: $1"
  command herdr notification show "Tab jump" --body "$1" >/dev/null 2>&1 || true
  exit 1
}

label="${1:-}"
[[ -n "$label" ]] || tg_fail "usage: tab-goto.sh <label>"

# Resolving through the globally-focused workspace is racy: persistence is a shared
# session view, so another attached client can change focus between the keypress and
# the query. Herdr injects active-context variables into custom commands; if none is
# present, say so rather than guessing at a workspace.
ws="${HERDR_ACTIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-}}"
[[ -n "$ws" ]] || tg_fail "no active workspace in the environment (expected HERDR_ACTIVE_WORKSPACE_ID)"

tabs="$(command herdr tab list --workspace "$ws" 2>&1)" || tg_fail "tab list failed: $tabs"

# Same boundary discipline as layout.sh: an empty or malformed response must not
# become a jump. jq exits 0 on empty input, so without this an empty response reads as
# "no tab labelled X" — blaming the label for what is really an API failure.
[[ -n "$tabs" ]] || tg_fail "herdr returned an empty response"
print -r -- "$tabs" | jq -e . >/dev/null 2>&1 \
  || tg_fail "herdr returned invalid JSON"
print -r -- "$tabs" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1 \
  && tg_fail "herdr returned an error envelope"

# Count the tabs carrying this label, then collect only ids that are non-empty JSON
# strings. Comparing the two catches a tab that matches but whose id is missing,
# numeric, or an object — `jq -r` would otherwise render those as "null", "7" or "{}"
# and hand them straight to `tab focus`.
count="$(print -r -- "$tabs" | jq -r --arg l "$label" \
          '[.result.tabs[] | select(.label == $l)] | length')" \
  || tg_fail "could not read the tab list"
matched="$(print -r -- "$tabs" | jq -r --arg l "$label" \
            '.result.tabs[] | select(.label == $l) | .tab_id
             | select(type == "string" and length > 0)')" \
  || tg_fail "could not read tab ids"

ids=( ${(f)matched} )
ids=( ${ids:#} )

(( count == 0 ))          && tg_fail "no tab labelled '$label'"
(( ${#ids} != count ))    && tg_fail "tab '$label' has a malformed id"
(( ${#ids} > 1 ))         && tg_fail "${#ids} tabs labelled '$label' — refusing to guess"

command herdr tab focus "${ids[1]}" >/dev/null || tg_fail "could not focus '$label'"
